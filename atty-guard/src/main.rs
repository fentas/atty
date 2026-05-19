//! atty-guard — sidecar daemon for atty's security_guard module.
//!
//! V2 entry point per `docs/security-guard-design.md`. Listens on a
//! Unix domain socket, accepts JSON-line RPCs from atty (and any
//! other authorised client), runs Tier-1 regex classification, falls
//! through to a Tier-2 backend (stub / heuristic / future onnx).
//!
//! What ships today:
//! - The daemon process + UDS server + JSON-line protocol.
//! - Tier-1 regex classifier mirroring atty's three patterns
//!   (curl|sh, npm install <flagged>, bash -c <long b64>).
//! - In-memory PID → threat-level map (proxy for the eBPF map that
//!   V2-B will introduce).
//! - Pluggable Tier-2 backend (--tier2 stub|heuristic).
//! - eBPF userspace-loader skeleton (--enable-ebpf flag, body
//!   lands with V2-B impl).
//!
//! What V2-B will fill in:
//! - libbpf-rs loader pinned to `lsm/bprm_check_security` +
//!   `tracepoint:syscalls:sys_enter_execve`.
//! - Real ringbuf consumer feeding the classifier asynchronously.
//! - Ownership of the BPF hash map (this in-memory map becomes a
//!   passthrough to the kernel side).
//!
//! What V2-C will add:
//! - ONNX-runtime SLM (SecureBERT-class) integration in the
//!   `classifier::tier2` slot.

mod classifier;
mod config;
mod ebpf;
mod onnx_backend;
mod osv;
mod protocol;
mod sanitize;
mod server;
mod threat_map;

use clap::Parser;
use std::path::PathBuf;

/// Sidecar daemon for atty security_guard.
#[derive(Parser, Debug)]
#[command(name = "atty-guard", version)]
struct Cli {
    /// Path to bind the UDS server on. Defaults to
    /// `$XDG_RUNTIME_DIR/atty-guard.sock`, falling back to
    /// `/tmp/atty-guard-<uid>.sock` if XDG_RUNTIME_DIR is unset.
    #[arg(long)]
    socket: Option<PathBuf>,

    /// Log verbosity: 0=quiet, 1=info, 2=debug.
    #[arg(short = 'v', long, default_value_t = 1)]
    verbosity: u8,

    /// Tier-2 backend.
    ///   stub      (default) returns Safe; Tier-1 hits are the
    ///              only signal that reaches atty.
    ///   heuristic regex rules beyond Tier-1 (proc-substitution
    ///              fetcher→shell, `--insecure` TLS, bare IP
    ///              fetcher targets, chmod+x followed by execute).
    ///   onnx      encoder-SLM via the `tier2-onnx` Cargo feature.
    ///              Supports SecureBERT 2.0 (default) AND
    ///              Qwen2.5-Coder; the model is picked via the
    ///              `[tier2.onnx] model` config key. Requires
    ///              `--config <path>` pointing at a TOML file
    ///              with `model_path` + `tokenizer_path` set, and
    ///              `libonnxruntime.so` on the loader path.
    #[arg(long, default_value = "stub", value_parser = ["stub", "heuristic", "onnx"])]
    tier2: String,

    /// Optional TOML config — currently populates the Tier-2 ONNX
    /// backend's model/tokenizer paths + thresholds. All fields
    /// are optional; missing ones fall through to compiled-in
    /// defaults. CLI flags override file values.
    #[arg(long)]
    config: Option<PathBuf>,

    /// Load the V2-B eBPF programs (lsm/bprm_check_security hook
    /// + sys_enter_execve tracepoint) at startup. Requires the
    /// daemon to have been built with `--features ebpf` AND to be
    /// running with CAP_BPF. Without the feature this flag errors
    /// out at startup; without the capability the loader errors
    /// with a pointer to the systemd-user unit's
    /// `AmbientCapabilities` config. See `ebpf/README.md`.
    #[arg(long, default_value_t = false)]
    enable_ebpf: bool,

    /// Enable V2-F live OSV.dev lookups for `npm install <pkg>`
    /// Tier-1 misses. Off by default (network use is opt-in).
    /// Requires `--features osv-live`. See `docs/security-guard-osv.md`.
    #[arg(long, default_value_t = false)]
    enable_osv: bool,

    /// OSV API endpoint. Useful for pointing at a mirror or an
    /// on-prem proxy when atty-guard runs in an air-gapped env.
    #[arg(long, default_value = "https://api.osv.dev")]
    osv_endpoint: String,
}

fn default_socket_path() -> PathBuf {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        let mut p = PathBuf::from(dir);
        p.push("atty-guard.sock");
        return p;
    }
    let uid = libc_uid();
    PathBuf::from(format!("/tmp/atty-guard-{}.sock", uid))
}

extern "C" {
    fn getuid() -> u32;
}
fn libc_uid() -> u32 {
    // Wrapping the FFI call here to keep `main` warning-free without
    // disabling `unused_unsafe` globally.
    unsafe { getuid() }
}

fn main() -> std::io::Result<()> {
    let cli = Cli::parse();
    let socket = cli.socket.unwrap_or_else(default_socket_path);
    let backend = classifier::BackendKind::parse(&cli.tier2).unwrap_or(classifier::BackendKind::Stub);

    // Optional TOML config — only used by the ONNX backend today,
    // but the loader is generic so future Tier-2 backends + V2-F
    // OSV-lookup tunables can hang here without reshuffling.
    let file_cfg = match cli.config.as_ref() {
        Some(p) => match config::load(p) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("atty-guard: --config {} ({e}) — using defaults", p.display());
                config::Config::default()
            }
        },
        None => config::Config::default(),
    };

    // SO_REUSEADDR equivalent for UDS: unlink stale socket file first.
    // On restart after a crash the previous socket file may linger and
    // bind would otherwise fail with EADDRINUSE. We're not protecting
    // against a concurrent live daemon — that would clobber, which
    // is the wrong outcome, so guard with a flock TODO.
    let _ = std::fs::remove_file(&socket);

    if cli.verbosity >= 1 {
        eprintln!(
            "atty-guard: listening on {} (tier2={})",
            socket.display(),
            cli.tier2
        );
    }

    // eBPF attach is opt-in. Either the feature isn't built (clean
    // error, daemon continues without kernel-side enforcement),
    // OR the feature IS built but the kernel/caps aren't there
    // (also clean — log + continue). V2-A behaviour stays as a
    // graceful fallback for all failure modes.
    let ebpf_state: Option<std::sync::Arc<ebpf::EbpfState>> = if cli.enable_ebpf {
        match ebpf::EbpfState::attach() {
            Ok(state) => {
                if cli.verbosity >= 1 {
                    eprintln!("atty-guard: eBPF attached (LSM + execve tracepoint)");
                }
                Some(std::sync::Arc::new(state))
            }
            Err(e) => {
                eprintln!("atty-guard: eBPF unavailable — {e}");
                eprintln!("atty-guard: continuing in V2-A mode (in-memory threat map, no kernel enforcement)");
                None
            }
        }
    } else {
        None
    };

    // V2-F live OSV.dev lookup. Opt-in via --enable-osv, separately
    // feature-gated via `osv-live`. Same graceful-fallback story as
    // eBPF: if the daemon's lookup_npm errors at runtime (network
    // down, parse failure) atty-guard logs + carries on with
    // Tier-1's local list as the only npm signal.
    let osv_client: Option<std::sync::Arc<osv::OsvClient>> = if cli.enable_osv {
        let cfg = osv::OsvConfig {
            endpoint: cli.osv_endpoint.clone(),
            ..osv::OsvConfig::default()
        };
        if cli.verbosity >= 1 {
            eprintln!(
                "atty-guard: OSV lookup enabled (endpoint={})",
                cli.osv_endpoint
            );
        }
        Some(std::sync::Arc::new(osv::OsvClient::new(cfg)))
    } else {
        None
    };

    server::serve(
        &socket,
        cli.verbosity,
        backend,
        &file_cfg.tier2.onnx,
        ebpf_state,
        osv_client,
    )
}
