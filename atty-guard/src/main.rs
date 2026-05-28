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

mod atom_drift;
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
    ///              with `model_path` + `tokenizer_path` set. The
    ///              ONNX runtime is pure-Rust (`tract-onnx`); no
    ///              `libonnxruntime.so` system dependency needed.
    /// Omitted → look at config's `[tier2] backend`, then fall
    /// back to `stub`. Use `Option<String>` rather than a clap
    /// `default_value = "stub"` so main can distinguish "operator
    /// didn't pass --tier2" from "operator passed --tier2 stub"
    /// — the latter wins over a config-file `backend = "onnx"`.
    #[arg(long, value_parser = ["stub", "heuristic", "onnx"])]
    tier2: Option<String>,

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
    /// corpora (GTFOBins + Sigma; LOLBAS was prototyped and dropped
    /// — Windows-native, didn't surface Linux shell IOCs), parses
    /// them into atoms, writes `/var/lib/atty-guard/atoms.system.txt`
    /// (or `$STATE_DIRECTORY/atoms.system.txt` under systemd)
    /// atomically, and exits without starting the UDS server.
    /// Requires `--features atoms-fetch`.
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
    Add { pattern: String },
    /// Remove `<pattern>` from the per-user atom list. Requires sudo.
    Remove { pattern: String },
    /// List atoms. Defaults to `--user`. Other scopes:
    /// `--system` (compile-time bundled corpus), `--fetched`
    /// (runtime-fetched corpus at /var/lib/atty-guard/atoms.system.txt
    /// — the source of `system-fetched atom matched: ...` reasons),
    /// `--session` (in-memory daemon session overlay).
    List {
        #[arg(long, conflicts_with_all = &["fetched", "user", "session"])]
        system: bool,
        #[arg(long, conflicts_with_all = &["system", "user", "session"])]
        fetched: bool,
        #[arg(long, conflicts_with_all = &["system", "fetched", "session"])]
        user: bool,
        #[arg(long, conflicts_with_all = &["system", "fetched", "user"])]
        session: bool,
    },
    /// Show the daemon's latest drift snapshot (per-source pin vs.
    /// upstream HEAD). Read-only; no sudo required. Exits 0 when
    /// in-sync or live-tracking, 2 when one or more sources have
    /// drifted (so CI checks can gate on it).
    Drift {
        /// Emit the raw JSON snapshot instead of the human-readable
        /// summary. Useful for scripting (jq pipelines).
        #[arg(long)]
        json: bool,
    },
    /// Seed `/etc/atty-guard/atoms.pins.toml` from the bundled
    /// template so the operator can edit-in-place to opt into
    /// pinned-commit tracking. Refuses to overwrite an existing
    /// file (rm it first if you want a clean reset). Requires sudo
    /// because `/etc/atty-guard/` is root-owned.
    PinInit {
        /// Overwrite the file if it already exists. Off by default
        /// so a casual mistype can't clobber an operator's hand-
        /// edited pin list.
        #[arg(long)]
        force: bool,
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
            None => eprintln!(
                "atty-guard: unknown atom source `{name}` — ignoring (valid: gtfobins, sigma)"
            ),
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

/// Lock-acquisition failure modes — distinguish "another daemon
/// holds the lock" (operator-visible, exit cleanly) from generic
/// I/O failure (open of the lock file failed for some other
/// reason — permission, missing directory, etc.).
#[derive(Debug)]
enum LockError {
    AlreadyRunning,
    Io(std::io::Error),
}

impl From<std::io::Error> for LockError {
    fn from(e: std::io::Error) -> Self {
        LockError::Io(e)
    }
}

/// Compute the lock-file path for a given socket path. Resolves
/// symlinks via canonicalization so two aliases to the same target
/// socket derive the SAME lock path — without this, a daemon
/// running with `/run/atty-guard/real.sock` and another started
/// with `/run/atty-guard/link.sock` (where `link.sock -> real.sock`)
/// would lock DIFFERENT sibling files, both succeed, and the
/// second would unlink the live target via `remove_socket_if_safe`
/// (which already canonicalizes for its own check).
///
/// Strategy:
///   - If the socket already exists: canonicalize the full path,
///     use it directly.
///   - If the socket doesn't exist yet (first startup): canonicalize
///     the parent directory (must exist), keep the basename literal.
///     The parent is the load-bearing piece for alias collision
///     since two paths that resolve to the same socket also share
///     the same canonical parent.
///   - If even the parent can't be canonicalized: fall back to the
///     literal path. The flock still works against the literal
///     name; we just lose the alias-collision guarantee.
fn lock_path_for_socket(socket: &std::path::Path) -> std::path::PathBuf {
    use std::os::unix::ffi::OsStrExt;
    if let Ok(canon) = std::fs::canonicalize(socket) {
        let mut p = canon.into_os_string();
        p.push(".lock");
        return p.into();
    }
    if let Some(parent) = socket.parent() {
        if let Ok(canon_parent) = std::fs::canonicalize(parent) {
            if let Some(name) = socket.file_name() {
                let mut p = canon_parent.into_os_string();
                p.push(std::path::MAIN_SEPARATOR.to_string());
                p.push(name);
                p.push(".lock");
                return p.into();
            }
        }
    }
    // Final fallback — literal path. Less robust but still locks
    // SOMETHING; alias-collision protection is best-effort.
    let mut lock_path = socket.as_os_str().to_owned();
    lock_path.push(".lock");
    let _ = OsStrExt::as_bytes(&*lock_path); // satisfy unused-import lint
    lock_path.into()
}

/// Open (or create) a sibling `<socket>.lock` file and acquire
/// a non-blocking exclusive BSD flock on it. Returns the open
/// `File` whose lifetime carries the lock — caller must keep it
/// alive for the daemon's lifetime. Drop = lock release.
fn acquire_single_instance_lock(socket: &std::path::Path) -> Result<std::fs::File, LockError> {
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::io::{AsRawFd, FromRawFd};

    // Lock file lives next to the socket (same parent dir, so
    // it inherits the daemon's RuntimeDirectory permissions).
    // Mode is `0600`, NOT the socket's `0660` — only the daemon
    // ever opens this file. The socket itself is group-readable
    // so `atty` group members can connect; the lock is purely
    // internal to the daemon process.
    let lock_path = lock_path_for_socket(socket);

    // Open with `O_RDONLY | O_CREAT` via raw libc — Rust's
    // `OpenOptions` refuses read-only + create. `flock` doesn't
    // require write access, and forcing O_RDWR would block
    // restart against a leftover `.lock` file created with
    // 0644 perms by a previous run under a different umask.
    // Contents are irrelevant — only the in-kernel flock state
    // matters — and a concurrent O_CREAT race is safe (both
    // processes see the same inode; only one wins the flock).
    //
    // Constants are pinned to Linux x86_64/aarch64 values — atty
    // targets linux-{gnu,musl} per CLAUDE.md. The compile-error
    // gate below makes the platform assumption explicit at build
    // time rather than silently miscompiling on (e.g.) BSD where
    // O_CLOEXEC has a different numeric value.
    #[cfg(not(target_os = "linux"))]
    compile_error!("atty-guard: lock-file helper hardcodes Linux O_* values");

    // open(2) is C varargs (`int open(const char*, int, ...)`).
    // Declaring it with a fixed 3-arg signature is technically
    // UB — Rust's ABI distinguishes fixed from variadic, and on
    // some platforms the calling conventions differ (e.g.
    // floating-point regs on AArch64 hardfp). The variadic
    // form is the portable correct shape.
    extern "C" {
        fn open(
            path: *const std::os::raw::c_char,
            flags: std::os::raw::c_int,
            ...
        ) -> std::os::raw::c_int;
    }
    const O_RDONLY: std::os::raw::c_int = 0;
    const O_CREAT: std::os::raw::c_int = 0o100;
    const O_CLOEXEC: std::os::raw::c_int = 0o2000000;

    let mut path_z = lock_path.as_os_str().as_bytes().to_vec();
    path_z.push(0);
    // Retry on EINTR — symmetric with the flock loop below.
    // Signal delivery (SIGCHLD during eBPF attach setup, etc.)
    // can interrupt open(2); without the retry, startup dies on
    // a transient kernel quirk.
    let mut open_attempts: u32 = 0;
    let fd = loop {
        let rc = unsafe {
            open(
                path_z.as_ptr() as *const std::os::raw::c_char,
                O_RDONLY | O_CREAT | O_CLOEXEC,
                0o600,
            )
        };
        if rc >= 0 {
            break rc;
        }
        let err = std::io::Error::last_os_error();
        if err.kind() == std::io::ErrorKind::Interrupted && open_attempts < 8 {
            open_attempts += 1;
            continue;
        }
        return Err(LockError::Io(err));
    };
    let file = unsafe { std::fs::File::from_raw_fd(fd) };

    // flock with LOCK_EX | LOCK_NB. Linux constants:
    //   LOCK_EX = 2, LOCK_NB = 4.
    extern "C" {
        fn flock(fd: std::os::raw::c_int, operation: std::os::raw::c_int) -> std::os::raw::c_int;
    }
    const LOCK_EX: std::os::raw::c_int = 2;
    const LOCK_NB: std::os::raw::c_int = 4;

    // Retry on EINTR — a signal interruption isn't a real
    // failure, just a kernel quirk that aborts the syscall.
    // Loop bound prevents pathological signal storms from
    // hanging startup forever (after N retries, give up).
    let mut attempts: u32 = 0;
    loop {
        let rc = unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
        if rc == 0 {
            return Ok(file);
        }
        let err = std::io::Error::last_os_error();
        if err.kind() == std::io::ErrorKind::Interrupted && attempts < 8 {
            attempts += 1;
            continue;
        }
        // EWOULDBLOCK / EAGAIN → contended.
        if err.kind() == std::io::ErrorKind::WouldBlock {
            return Err(LockError::AlreadyRunning);
        }
        return Err(LockError::Io(err));
    }
}

/// Outcome of the pre-bind socket cleanup. `NotASocket` means
/// the existing path is something the daemon shouldn't unlink —
/// arbitrary regular file, directory, etc. — and the operator
/// has likely misconfigured `--socket`.
#[derive(Debug)]
enum SocketRemoveError {
    NotASocket,
    Io(std::io::Error),
}

/// Remove `path` if and only if it points at (or symlinks to) a
/// Unix socket. Non-existent paths return `Ok(())` (first-run /
/// clean restart). Anything else (regular file, dir, FIFO,
/// device) returns `NotASocket` — the caller decides whether to
/// exit or surface the error.
///
/// Symlinks are followed: a legitimate operator setup may
/// symlink `/run/atty-guard.sock` to a different path. The
/// initial `symlink_metadata` is a fast-path check for
/// `NotFound`; if the path exists we follow via `metadata` so
/// the type check sees the link target.
fn remove_socket_if_safe(path: &std::path::Path) -> Result<(), SocketRemoveError> {
    use std::os::unix::fs::FileTypeExt;

    // Fast-path NotFound (first run / clean restart) without
    // following symlinks.
    match std::fs::symlink_metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(SocketRemoveError::Io(e)),
        Ok(_) => {}
    }
    // Path exists. Resolve symlinks for the type check so a
    // legitimate operator setup (e.g. `/run/atty-guard.sock`
    // symlinked to `/var/run/atty/guard.sock`) isn't rejected.
    // `canonicalize` follows the chain to a real existing path
    // (fails with ENOENT only if the link is broken).
    let resolved = std::fs::canonicalize(path).map_err(SocketRemoveError::Io)?;
    let md = std::fs::metadata(&resolved).map_err(SocketRemoveError::Io)?;
    if !md.file_type().is_socket() {
        return Err(SocketRemoveError::NotASocket);
    }
    // Remove the RESOLVED path (the actual socket inode), not
    // the symlink. Keeps the operator's symlink intact so a
    // subsequent `bind(path)` follows it and recreates the
    // socket at the same target — the canonical setup keeps
    // working across restarts.
    std::fs::remove_file(&resolved).map_err(SocketRemoveError::Io)
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
        let cfg = match atom_fetcher::FetcherConfig::default_with_pins() {
            Ok(c) => c,
            Err(e) => {
                eprintln!("atty-guard: pin file rejected — {e}");
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    e.to_string(),
                ));
            }
        };
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

    // Optional TOML config — only used by the ONNX backend today,
    // but the loader is generic so future Tier-2 backends + V2-F
    // OSV-lookup tunables can hang here without reshuffling.
    //
    // Failure posture: when `--config <path>` is EXPLICITLY passed
    // by the operator, a load failure (missing file, parse error,
    // bad permissions) is a HARD error. Pre-fix, the daemon logged
    // and continued with `Config::default()` — which silently
    // disabled `[accumulator] block_threshold` (auto-Block off),
    // reverted `[tier2.onnx]` thresholds, and reset `[server]`
    // connection caps. In a systemd deployment the service looked
    // healthy while running with the wrong policy.
    //
    // Matches the atom-pin-file posture (`/etc/atty-guard/atoms.pins.toml`,
    // shipped via #208): explicit opt-in means the operator wants
    // the policy enforced, so silent fallback defeats the purpose.
    // When `--config` is omitted, defaults are still the right
    // behavior — no operator policy was promised.
    let file_cfg = match cli.config.as_ref() {
        Some(p) => match config::load(p) {
            Ok(c) => c,
            Err(e) => {
                eprintln!(
                    "atty-guard: --config {} rejected ({e}) — refusing to start with defaults; either fix the config or omit --config to use defaults intentionally",
                    p.display()
                );
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!("config load failed: {e}"),
                ));
            }
        },
        None => config::Config::default(),
    };

    // Invalid backend (from CLI or config) is a hard error rather
    // than a silent fallback — operator opt-in should fail loudly.
    let (backend, backend_source) = match classifier::resolve_backend(
        cli.tier2.as_deref(),
        file_cfg.tier2.backend.as_deref(),
    ) {
        Ok(v) => v,
        Err((raw, source)) => {
            eprintln!(
                "atty-guard: invalid tier2 backend {:?} from {} — expected stub|heuristic|onnx",
                raw,
                source.as_str(),
            );
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("invalid tier2 backend: {raw}"),
            ));
        }
    };
    let backend_str: &'static str = match backend {
        classifier::BackendKind::Stub => "stub",
        classifier::BackendKind::Heuristic => "heuristic",
        classifier::BackendKind::Onnx => "onnx",
    };
    // Backend construction here so explicit operator requests
    // (CLI / config) FAIL CLOSED on load failure instead of
    // silently degrading to Stub under a `tier2=onnx` log line.
    // The default path (no operator request) keeps the legacy
    // best-effort fallback so a fresh install doesn't refuse to
    // start because of a missing model file.
    let classifier = match backend_source {
        classifier::BackendSource::Default => {
            classifier::Classifier::new_with_backend(backend, &file_cfg.tier2.onnx)
        }
        classifier::BackendSource::Cli | classifier::BackendSource::Config => {
            match classifier::Classifier::try_new_with_backend(
                backend,
                &file_cfg.tier2.onnx,
            ) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!(
                        "atty-guard: tier2={} requested from {} but backend load failed: {}",
                        backend_str,
                        backend_source.as_str(),
                        e,
                    );
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidInput,
                        format!("tier2 backend load failed: {e}"),
                    ));
                }
            }
        }
    }
    .with_block_threshold(file_cfg.accumulator.block_threshold);
    if cli.verbosity >= 1 {
        // Log BOTH requested + effective so the operator can spot a
        // silent default-path fallback (the Cli/Config paths above
        // refuse to start on mismatch, so effective == requested for
        // those; only the Default path can downgrade to stub).
        eprintln!(
            "atty-guard: tier2={} effective={} (source={})",
            backend_str,
            classifier.tier2_name(),
            backend_source.as_str(),
        );
    }

    // Single-instance guard via flock on a sibling `.lock` file.
    // Holding the file alive for the daemon's lifetime keeps the
    // lock; on process exit (crash or clean), the kernel releases
    // it. A second `atty-guard` against the same socket path will
    // see EWOULDBLOCK and refuse to start — avoids the old race
    // where unconditional `remove_file` could clobber a live
    // daemon's socket and let new clients connect to the wrong
    // process. The `.lock` file itself stays on disk across
    // restarts (its presence is meaningless without the kernel
    // lock state); only the in-kernel BSD lock matters.
    //
    // Bound `_lock` to a name (not `_`) so it survives to the end
    // of `main`; an underscore-only binding would drop
    // immediately, releasing the lock before `server::serve` even
    // starts.
    let _lock = match acquire_single_instance_lock(&socket) {
        Ok(file) => file,
        Err(LockError::AlreadyRunning) => {
            eprintln!(
                "atty-guard: another instance is already running on {} — refusing to start",
                socket.display()
            );
            std::process::exit(1);
        }
        Err(LockError::Io(e)) => {
            eprintln!(
                "atty-guard: cannot acquire single-instance lock for {}: {e}",
                socket.display()
            );
            std::process::exit(1);
        }
    };
    // Lock acquired — safe to unlink any STALE SOCKET left by a
    // previous crashed instance (the kernel already cleared its
    // flock, so no live owner). Guarded against `--socket`
    // pointing at a non-socket regular file: silently unlinking
    // would delete arbitrary data the operator didn't expect.
    match remove_socket_if_safe(&socket) {
        Ok(()) => {}
        Err(SocketRemoveError::NotASocket) => {
            eprintln!(
                "atty-guard: --socket {} exists and is not a Unix socket — refusing to overwrite",
                socket.display()
            );
            std::process::exit(1);
        }
        Err(SocketRemoveError::Io(e)) => {
            // Io can come from symlink_metadata, canonicalize,
            // metadata, OR remove_file. Use a generic phrasing
            // that doesn't lie about which step failed.
            eprintln!(
                "atty-guard: cannot prepare --socket {}: {e}",
                socket.display()
            );
            std::process::exit(1);
        }
    }

    if cli.verbosity >= 1 {
        eprintln!(
            "atty-guard: listening on {} (tier2={})",
            socket.display(),
            backend_str
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
            // Pin-file rejection MUST NOT kill the daemon. The
            // classifier (server::serve below) is the load-bearing
            // service; atom refresh is an auxiliary cron. If the
            // operator's `/etc/atty-guard/atoms.pins.toml` is
            // malformed, log loudly and skip starting the refresh
            // thread — but keep the classifier alive. systemd's
            // Restart=on-failure would see exit(0) as success and
            // not restart us, so a typo in /etc would brick the
            // host's command classification entirely.
            match atom_fetcher::FetcherConfig::default_with_pins() {
                Ok(cfg) => {
                    if cli.verbosity >= 1 {
                        eprintln!(
                            "atty-guard: atom refresh cron enabled — every {}s, sources={:?}",
                            iv.as_secs(),
                            sources
                        );
                    }
                    atom_fetcher::spawn_periodic_refresh(cfg, sources, iv, trust_store.clone());
                }
                Err(e) => {
                    eprintln!(
                        "atty-guard: pin file rejected — atom refresh cron disabled, classifier continues — {e}"
                    );
                }
            }
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
        classifier,
        ebpf_state,
        osv_client,
        trust_store,
        file_cfg.server.clone(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unique_socket_path() -> std::path::PathBuf {
        // pid + monotonic counter — pid alone risks colliding
        // across cargo's parallel test threads (same PID), and
        // SystemTime nanos can repeat on coarse-resolution
        // clocks or fast machines within the same tick.
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let pid = std::process::id();
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        std::path::PathBuf::from(format!("/tmp/atty-guard-lock-test-{pid}-{n}.sock"))
    }

    #[test]
    fn lock_is_exclusive() {
        let socket = unique_socket_path();
        // Cleanup any leftover .lock from a previous run.
        let lock_path = {
            let mut p = socket.as_os_str().to_owned();
            p.push(".lock");
            std::path::PathBuf::from(p)
        };
        let _ = std::fs::remove_file(&lock_path);

        let first = acquire_single_instance_lock(&socket).expect("first lock should succeed");
        match acquire_single_instance_lock(&socket) {
            Err(LockError::AlreadyRunning) => {}
            Ok(_) => panic!("second lock should NOT succeed while first holds it"),
            Err(other) => panic!("expected AlreadyRunning, got {other:?}"),
        }
        // Drop first → kernel releases the flock.
        drop(first);
        let _second = acquire_single_instance_lock(&socket)
            .expect("lock should be re-acquirable after first dropped");
        // Cleanup so /tmp doesn't accumulate stale .lock files.
        let _ = std::fs::remove_file(&lock_path);
    }

    #[test]
    fn remove_socket_if_safe_missing_path_is_ok() {
        let p = unique_socket_path();
        // No file at this path — should succeed silently.
        assert!(matches!(remove_socket_if_safe(&p), Ok(())));
    }

    #[test]
    fn remove_socket_if_safe_regular_file_refused() {
        // If `--socket` points at an existing regular file (operator
        // misconfig), the daemon must NOT silently delete it.
        let p = unique_socket_path();
        std::fs::write(&p, b"important data").expect("write fixture");
        let result = remove_socket_if_safe(&p);
        assert!(matches!(result, Err(SocketRemoveError::NotASocket)));
        assert!(p.exists(), "regular file should NOT have been removed");
        // Cleanup
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn remove_socket_if_safe_actual_socket_is_removed() {
        // Stale socket from a previous run should be removed.
        let p = unique_socket_path();
        let _ = std::fs::remove_file(&p);
        let _listener = std::os::unix::net::UnixListener::bind(&p).expect("bind fixture");
        // listener drops at scope end; binding the socket leaves
        // the inode on disk until we unlink — perfect stale socket
        // simulation. drop the listener so its fd is closed but
        // the inode remains.
        drop(_listener);
        assert!(p.exists(), "socket file should exist after bind");
        assert!(matches!(remove_socket_if_safe(&p), Ok(())));
        assert!(!p.exists(), "socket file should be removed");
    }

    #[test]
    fn remove_socket_if_safe_symlink_to_socket_removes_target() {
        // Operator setup: socket-path is a symlink to a different
        // location. The target socket (stale) must be removed; the
        // symlink itself must survive so `bind(symlink_path)` still
        // resolves correctly.
        let target = unique_socket_path();
        let mut link_buf = unique_socket_path();
        link_buf.set_extension("link");
        let link = link_buf;
        let _ = std::fs::remove_file(&target);
        let _ = std::fs::remove_file(&link);

        let _listener = std::os::unix::net::UnixListener::bind(&target).expect("bind fixture");
        drop(_listener);
        std::os::unix::fs::symlink(&target, &link).expect("symlink fixture");

        assert!(matches!(remove_socket_if_safe(&link), Ok(())));
        assert!(!target.exists(), "target socket should be removed");
        assert!(
            std::fs::symlink_metadata(&link).is_ok(),
            "symlink should still exist (operator setup preserved)"
        );
        // Cleanup the dangling symlink.
        let _ = std::fs::remove_file(&link);
    }

    #[test]
    fn acquire_single_instance_lock_blocks_symlink_alias() {
        // Regression for finding 017. Two paths that resolve to
        // the same target (one direct, one via symlink) must
        // contend on the SAME lock file. Pre-fix the lock path
        // was derived literally from the supplied socket path,
        // so two aliases ended up with DIFFERENT sibling lock
        // files — both flocks would succeed and the second
        // daemon's cleanup path would unlink the live target.
        let target = unique_socket_path();
        let mut link_buf = unique_socket_path();
        link_buf.set_extension("link");
        let link = link_buf;
        let _ = std::fs::remove_file(&target);
        let _ = std::fs::remove_file(&link);

        // Bind a real socket so canonicalize() works on both
        // paths (canonicalize requires the path to exist).
        let _listener = std::os::unix::net::UnixListener::bind(&target).expect("bind fixture");
        std::os::unix::fs::symlink(&target, &link).expect("symlink fixture");

        let _lock_a = acquire_single_instance_lock(&target).expect("lock target should succeed");
        // Second acquisition via the symlink alias MUST fail —
        // both paths resolve to the same canonical lock file.
        let alias_result = acquire_single_instance_lock(&link);
        assert!(
            matches!(alias_result, Err(LockError::AlreadyRunning)),
            "alias lock should have been blocked by existing lock, got {alias_result:?}"
        );
        // Cleanup.
        drop(_lock_a);
        let _ = std::fs::remove_file(&target);
        let _ = std::fs::remove_file(&link);
        let mut lock_path = target.as_os_str().to_owned();
        lock_path.push(".lock");
        let _ = std::fs::remove_file(std::path::PathBuf::from(lock_path));
    }

    #[test]
    fn lock_path_is_socket_sibling() {
        // Belt-and-braces: the lock path must be `<socket>.lock`,
        // not e.g. moved into /var/lock or /tmp. Operators rely
        // on it living next to the socket.
        let socket = unique_socket_path();
        let lock_path = {
            let mut p = socket.as_os_str().to_owned();
            p.push(".lock");
            std::path::PathBuf::from(p)
        };
        let _ = std::fs::remove_file(&lock_path);

        let _lock = acquire_single_instance_lock(&socket).expect("lock should succeed");
        assert!(
            lock_path.exists(),
            "lock file at {lock_path:?} should exist"
        );
        drop(_lock);
        let _ = std::fs::remove_file(&lock_path);
    }

    #[test]
    fn service_unit_does_not_set_protect_proc_invisible() {
        // Regression test for the second review's finding 012:
        // `ProtectProc=invisible` mount-namespaces other UIDs'
        // /proc entries out of the daemon's view, which makes
        // the `/proc`-based `set_threat_level` auth gate
        // (shipped by PR #188) silently reject every cross-UID
        // request. Unit tests pass either way because they run
        // outside the sandbox; the only mechanical guard is to
        // pin the service file's contract here. If a future
        // contributor re-adds the directive without realizing
        // it breaks auth in production, this test fails.
        let service =
            std::fs::read_to_string("contrib/atty-guard.service").expect("read service file");
        // Walk lines so a commented-out occurrence doesn't false-positive.
        for line in service.lines() {
            let trimmed = line.trim_start();
            if trimmed.starts_with('#') {
                continue;
            }
            assert!(
                !trimmed.eq_ignore_ascii_case("ProtectProc=invisible"),
                "atty-guard.service must NOT set ProtectProc=invisible — \
                 it hides other UIDs' /proc entries from the `atty`-user \
                 daemon and breaks the set_threat_level auth gate. \
                 If you need to re-add directory hardening, prefer a \
                 pidfd-based ownership check (kernel >= 6.9) instead."
            );
        }
    }
}
