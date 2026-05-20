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

mod atom_fetcher;
mod atom_matcher;
mod classifier;
mod cli_client;
mod config;
mod ebpf;
mod onnx_backend;
mod osv;
mod protocol;
mod sanitize;
mod server;
mod threat_map;
mod trust_store;

use clap::Parser;
use std::path::PathBuf;

/// Sidecar daemon for atty security_guard.
#[derive(Parser, Debug)]
#[command(name = "atty-guard", version)]
struct Cli {
    /// Path to bind the UDS server on. Defaults to
    /// `/run/atty-guard/atty-guard.sock` for the system-daemon
    /// install (the systemd unit creates `RuntimeDirectory=atty-guard`
    /// owned `atty:atty` mode 0750 — atty proxies in the `atty`
    /// group can connect). For dev runs as a regular user, override
    /// with `--socket /tmp/atty-guard-dev.sock` or similar.
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

    /// V2-I one-shot atom refresh. Fetches the configured IOC
    /// corpora (default: GTFOBins; future: Sigma, LOLBAS), parses
    /// them into atoms, writes `$XDG_DATA_HOME/atty-guard/
    /// flagged_atoms.txt` atomically, and exits without starting
    /// the UDS server. Requires `--features atoms-fetch`.
    #[arg(long, default_value_t = false)]
    update_atoms_now: bool,

    /// V2-I cron mode. When set, the daemon serves AND spawns a
    /// background thread that re-runs the atom fetch every
    /// `<interval>`. Accepts "30m" / "6h" / "1d" suffixes; "0"
    /// disables (default). Requires `--features atoms-fetch`.
    #[arg(long, default_value = "0")]
    atoms_update_interval: String,

    /// Comma-separated source list for the V2-I fetcher.
    /// Valid: `gtfobins`, `sigma`. Empty = all enabled.
    #[arg(long, default_value = "")]
    atoms_sources: String,

    /// Print one line per compiled-in Cargo feature, then exit.
    /// Drives `atty doctor`'s feature detection (replaces the
    /// fragile `--help | grep --enable-ebpf` heuristic which
    /// matched both feature-on and feature-off builds because the
    /// CLI flag exists regardless of the cargo feature). Output
    /// is one feature name per line, suitable for piping through
    /// `grep` / shell arithmetic.
    #[arg(long, default_value_t = false)]
    print_features: bool,

    /// Optional subcommand for the mediated trust-state interface
    /// (PR #141). When absent, atty-guard runs as the daemon. When
    /// present, atty-guard runs as a CLI client: it connects to the
    /// running daemon via `--socket`, sends one request, prints the
    /// reply, exits. Mutating subcommands require sudo so the
    /// daemon's SO_PEERCRED check passes; read-only ones don't.
    #[command(subcommand)]
    command: Option<Subcommand>,
}

#[derive(clap::Subcommand, Debug)]
enum Subcommand {
    /// Manage per-user atom additions.
    Atoms {
        #[command(subcommand)]
        op: AtomsOp,
    },
    /// Manage per-user URL allow/block decisions.
    Urls {
        #[command(subcommand)]
        op: UrlsOp,
    },
    /// Inspect or persist the in-memory session trust state.
    Session {
        #[command(subcommand)]
        op: SessionOp,
    },
    /// Inspect per-user persistent trust hashes (the daemon-side
    /// `commands.trusted.txt`). Populated by `[t]rust permanently`
    /// keystrokes mirrored from atty.
    Trust {
        #[command(subcommand)]
        op: TrustOp,
    },
}

#[derive(clap::Subcommand, Debug)]
enum AtomsOp {
    /// Add `<pattern>` to the per-user atom list. Requires sudo.
    Add {
        pattern: String,
    },
    /// Remove `<pattern>` from the per-user atom list. Requires sudo.
    Remove {
        pattern: String,
    },
    /// List atoms. Defaults to `--user`; pass `--system` for the
    /// bundled corpus or `--session` for the in-memory overlay.
    List {
        #[arg(long, conflicts_with_all = &["user", "session"])]
        system: bool,
        #[arg(long, conflicts_with_all = &["system", "session"])]
        user: bool,
        #[arg(long, conflicts_with_all = &["system", "user"])]
        session: bool,
    },
}

#[derive(clap::Subcommand, Debug)]
enum UrlsOp {
    /// Allow `<host>`. Requires sudo.
    Allow { host: String },
    /// Block `<host>`. Requires sudo.
    Block { host: String },
    /// List recorded URL decisions (persistent + session overlay).
    List,
}

#[derive(clap::Subcommand, Debug)]
enum TrustOp {
    /// List the caller's persistent trust hashes.
    List,
    /// Add a hash directly (mostly for testing / scripting; the
    /// typical path is the banner's `[t]rust permanently`).
    Add { hash: String },
}

#[derive(clap::Subcommand, Debug)]
enum SessionOp {
    /// Show pending in-memory session decisions (no sudo).
    List,
    /// Discard the in-memory session (no sudo). Does NOT touch
    /// persistent files.
    Clear,
    /// Persist the in-memory session into the per-UID atom + URL
    /// files. Requires sudo because the target files live under
    /// /var/lib/atty-guard/ owned `atty:atty`.
    Write,
}

/// Parse the `--atoms-update-interval` value into a Duration.
/// `0` (default) means no cron. Suffixes: `s` / `m` / `h` / `d`.
/// Returns None for the disabled sentinel, errors for malformed
/// values.
fn parse_interval(s: &str) -> Result<Option<std::time::Duration>, String> {
    let s = s.trim();
    if s == "0" || s.is_empty() {
        return Ok(None);
    }
    let (digits, suffix): (&str, char) = {
        let last = s.chars().last().unwrap();
        if last.is_ascii_alphabetic() {
            (&s[..s.len() - 1], last)
        } else {
            (s, 's')
        }
    };
    let n: u64 = digits
        .parse()
        .map_err(|e| format!("atoms-update-interval `{s}`: {e}"))?;
    // `checked_mul` guards against silent overflow on huge inputs
    // — a wrapped duration would lock the cron thread into a near-
    // zero sleep and DoS upstream. Cap at u32::MAX seconds anyway
    // because Duration::from_secs takes u64 and we have nothing
    // useful to do with a 100-year refresh interval.
    let mult: u64 = match suffix {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        other => {
            return Err(format!(
                "atoms-update-interval suffix `{other}` — expected s/m/h/d"
            ))
        }
    };
    let secs = n
        .checked_mul(mult)
        .ok_or_else(|| format!("atoms-update-interval `{s}` overflows — pick a smaller value"))?;
    if secs < 60 {
        return Err(format!(
            "atoms-update-interval `{s}` below 60s — be polite to upstream"
        ));
    }
    Ok(Some(std::time::Duration::from_secs(secs)))
}

/// Parse `--atoms-sources foo,bar`. Empty = default-enabled set.
/// Unknown tokens are LOGGED to stderr (not silently dropped) so a
/// typo doesn't quietly leave the cron thread fetching nothing.
fn parse_atom_sources(s: &str) -> Vec<atom_fetcher::SourceId> {
    let s = s.trim();
    if s.is_empty() {
        return atom_fetcher::SourceId::default_enabled().to_vec();
    }
    let mut out = Vec::new();
    for raw in s.split(',') {
        let name = raw.trim();
        if name.is_empty() {
            continue;
        }
        match atom_fetcher::SourceId::parse(name) {
            Some(sid) => out.push(sid),
            None => eprintln!("atty-guard: unknown atom source `{name}` — ignoring (valid: gtfobins, sigma)"),
        }
    }
    out
}

fn default_socket_path() -> PathBuf {
    // System-daemon default — the systemd unit's
    // `RuntimeDirectory=atty-guard` creates /run/atty-guard/ owned
    // atty:atty mode 0750 before the daemon starts. Dev runs as a
    // regular user must `--socket /tmp/atty-guard-dev.sock` or
    // similar (the default path isn't writable from non-root).
    //
    // WHY not /tmp/atty-guard-<uid>.sock (the prior systemd-user
    // default): the post-PR-#140 architecture runs atty-guard under
    // a dedicated `atty` user, not under each end-user's session.
    // /run/atty-guard/ is the FHS-blessed location for system-
    // daemon runtime sockets and matches systemd's RuntimeDirectory
    // contract.
    PathBuf::from("/run/atty-guard/atty-guard.sock")
}

/// Emit one feature name per stdout line for each Cargo feature
/// compiled into this binary. Static — relies on `#[cfg(feature)]`
/// at compile time so the output is exactly the set baked in (no
/// runtime detection / kernel probing).
fn print_compiled_features() {
    let mut features: Vec<&'static str> = Vec::new();
    #[cfg(feature = "tier2-onnx")]
    features.push("tier2-onnx");
    #[cfg(feature = "osv-live")]
    features.push("osv-live");
    #[cfg(feature = "atoms-fetch")]
    features.push("atoms-fetch");
    #[cfg(feature = "ebpf")]
    features.push("ebpf");
    features.sort();
    for f in &features {
        println!("{f}");
    }
}

fn main() -> std::io::Result<()> {
    let mut cli = Cli::parse();

    // Feature probe (--print-features). Emits one line per
    // compiled-in Cargo feature, exits. Drives `atty doctor`'s
    // feature detection. Order: stable + sorted so consumers can
    // grep / awk / shell-test reliably.
    if cli.print_features {
        print_compiled_features();
        return Ok(());
    }

    let sources = parse_atom_sources(&cli.atoms_sources);
    let interval = parse_interval(&cli.atoms_update_interval)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;

    // V2-I one-shot path: refresh atoms + exit, don't serve UDS.
    // Useful for `atty-guard --update-atoms-now` invocations from
    // systemd timers / pre-commit hooks / CI atom-bundle builders.
    if cli.update_atoms_now {
        let cfg = atom_fetcher::FetcherConfig::default();
        return match atom_fetcher::fetch_all(&cfg, &sources) {
            Ok(report) => {
                eprintln!(
                    "atty-guard: atom refresh ok — {} atoms across {} sources → {}",
                    report.atoms_total,
                    report.per_source.len(),
                    cfg.output_path.display()
                );
                for (sid, res) in &report.per_source {
                    match res {
                        Ok(n) => eprintln!("  {}: {n} atoms", sid.name()),
                        Err(e) => eprintln!("  {}: FAILED — {e}", sid.name()),
                    }
                }
                Ok(())
            }
            Err(e) => {
                eprintln!("atty-guard: atom refresh failed — {e}");
                Err(std::io::Error::new(
                    std::io::ErrorKind::Other,
                    e.to_string(),
                ))
            }
        };
    }

    // If a subcommand was specified, run CLI-client mode instead of
    // starting the daemon. Subcommand handlers do their own argument
    // parsing + socket round-trip; daemon flags like --tier2 are
    // silently ignored. Connect to the daemon at --socket (or the
    // system-daemon default at /run/atty-guard/atty-guard.sock).
    if let Some(cmd) = cli.command.take() {
        let socket = cli.socket.unwrap_or_else(default_socket_path);
        return cli_client::dispatch(&socket, cmd);
    }

    let socket = cli.socket.unwrap_or_else(default_socket_path);
    let backend =
        classifier::BackendKind::parse(&cli.tier2).unwrap_or(classifier::BackendKind::Stub);

    // Optional TOML config — only used by the ONNX backend today,
    // but the loader is generic so future Tier-2 backends + V2-F
    // OSV-lookup tunables can hang here without reshuffling.
    let file_cfg = match cli.config.as_ref() {
        Some(p) => match config::load(p) {
            Ok(c) => c,
            Err(e) => {
                eprintln!(
                    "atty-guard: --config {} ({e}) — using defaults",
                    p.display()
                );
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

    // V2-I cron mode. Spawn the background refresh thread before
    // entering the UDS accept loop. The thread is detached; daemon
    // exit kills it cleanly because `server::serve` returns on
    // signal and we drop straight out of main().
    // Per-UID atom + URL trust state lives under
    // `/var/lib/atty-guard/users/<uid>/`. The StateDirectory= unit
    // directive creates the parent (`/var/lib/atty-guard/`) as
    // atty:atty 0750. The `users/` subdir is created lazily on
    // first write — the directory layout is per-UID isolated so
    // an empty directory is a fine starting state.
    //
    // Constructed BEFORE the cron-fetcher spawn so the cron thread
    // can call `trust_store.reload_system_fetched()` after each
    // successful fetch (the daemon's hot-path classify reads the
    // in-memory copy that this reload populates).
    //
    // Dev runs as a regular user get a STATE_DIRECTORY-less default
    // which resolves to /var/lib/atty-guard/ (not writable) and
    // gracefully no-ops on persistent ops. Tests pass an explicit
    // tempdir to TrustStore::new.
    // STATE_DIRECTORY can be a ':'-separated list when the unit
    // sets multiple StateDirectory= entries; mirror what
    // `atom_fetcher::default_atoms_path` does and use the first.
    let trust_root = std::env::var("STATE_DIRECTORY")
        .ok()
        .and_then(|s| {
            s.split(':')
                .next()
                .filter(|p| !p.is_empty())
                .map(|p| std::path::PathBuf::from(p).join("users"))
        })
        .unwrap_or_else(|| std::path::PathBuf::from("/var/lib/atty-guard/users"));
    let trust_store = std::sync::Arc::new(trust_store::TrustStore::new(trust_root));

    if let Some(iv) = interval {
        if cfg!(feature = "atoms-fetch") {
            let cfg = atom_fetcher::FetcherConfig::default();
            if cli.verbosity >= 1 {
                eprintln!(
                    "atty-guard: atom refresh cron enabled — every {}s, sources={:?}",
                    iv.as_secs(),
                    sources
                );
            }
            atom_fetcher::spawn_periodic_refresh(cfg, sources, iv, trust_store.clone());
        } else {
            // Without the feature, `spawn_periodic_refresh` is a
            // no-op. Loud warn so the operator knows their cron
            // schedule is doing nothing — silently swallowing the
            // request would be worse.
            eprintln!(
                "atty-guard: --atoms-update-interval {}s ignored — built without `atoms-fetch` feature",
                iv.as_secs()
            );
        }
    }

    // Eagerly load atoms.system.txt at startup so the very first
    // classify after daemon start sees the fetched corpus (without
    // this, the first classify lazy-loads + the warning about a
    // perm-gate refusal happens mid-keystroke instead of in the
    // operator's view at boot). Errors are non-fatal: missing file
    // is normal (no fetch run yet), perm-refused is logged with
    // remediation hints.
    match trust_store.reload_system_fetched() {
        Ok(n) if n > 0 && cli.verbosity >= 1 => {
            eprintln!("atty-guard: atoms.system.txt loaded ({n} atoms)");
        }
        Ok(_) => {}
        Err(e) => {
            eprintln!("atty-guard: atoms.system.txt not loaded — {e}");
        }
    }

    server::serve(
        &socket,
        cli.verbosity,
        backend,
        &file_cfg.tier2.onnx,
        file_cfg.accumulator.block_threshold,
        ebpf_state,
        osv_client,
        trust_store,
    )
}
