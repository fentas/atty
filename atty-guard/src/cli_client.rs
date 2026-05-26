//! Client-mode handlers for the mediated trust CLI (PR #141).
//!
//! When invoked as `atty-guard atoms add ...` / `urls allow ...` /
//! `session write` etc., atty-guard runs in CLI-client mode: it
//! connects to the running daemon over the UDS, sends one Request,
//! prints the reply, exits with status 0 on success / 1 on error.
//!
//! Mutating subcommands (atoms add/remove, urls allow/block,
//! session write) require sudo. The daemon enforces this via
//! SO_PEERCRED; the CLI surface here just builds the request +
//! relays the error message verbatim. No extra "are you root?"
//! check here — the daemon's check is authoritative and gives a
//! single source of truth for the privilege rule.
//!
//! Read-only ops (atoms list, urls list, session list/clear) work
//! without sudo. They still go via the daemon (vs. reading the
//! files directly) because session state lives in daemon memory.

use crate::protocol::{AtomScope, Envelope, Request, ResponseBody};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;

pub fn dispatch(socket: &Path, sub: crate::Subcommand) -> std::io::Result<()> {
    use crate::{AtomsOp, SessionOp, Subcommand, TrustOp, UrlsOp};
    let target_uid = sudo_target_uid();
    match sub {
        Subcommand::Atoms { op } => match op {
            AtomsOp::Add { pattern } => send_and_check(
                socket,
                Request::AtomsAdd {
                    pattern,
                    target_uid,
                },
            ),
            AtomsOp::Remove { pattern } => send_and_check(
                socket,
                Request::AtomsRemove {
                    pattern,
                    target_uid,
                },
            ),
            AtomsOp::List {
                system,
                user,
                session,
            } => {
                let scope = if system {
                    AtomScope::System
                } else if session {
                    AtomScope::Session
                } else {
                    // `--user` is the default when no flag is given,
                    // matching the operator's usual case: "what atoms
                    // did I add?"
                    let _ = user;
                    AtomScope::User
                };
                handle_atoms_list(socket, scope, target_uid)
            }
            AtomsOp::Drift { json } => handle_atoms_drift(socket, json),
            AtomsOp::PinInit { force } => handle_pin_init(force),
        },
        Subcommand::Urls { op } => match op {
            UrlsOp::Allow { host } => send_and_check(
                socket,
                Request::UrlsAllow { host, target_uid },
            ),
            UrlsOp::Block { host } => send_and_check(
                socket,
                Request::UrlsBlock { host, target_uid },
            ),
            UrlsOp::List => handle_urls_list(socket, target_uid),
        },
        Subcommand::Session { op } => match op {
            SessionOp::List => handle_session_list(socket, target_uid),
            SessionOp::Clear => send_and_check(socket, Request::SessionClear { target_uid }),
            SessionOp::Write => send_and_check(socket, Request::SessionWrite { target_uid }),
        },
        Subcommand::Trust { op } => match op {
            TrustOp::List => handle_trust_list(socket, target_uid),
            TrustOp::Add { hash } => send_and_check(
                socket,
                Request::TrustAdd { hash, target_uid },
            ),
        },
    }
}

fn handle_trust_list(socket: &Path, target_uid: Option<u32>) -> std::io::Result<()> {
    let response = send_request(socket, Request::TrustList { target_uid })?;
    match response {
        ResponseBody::TrustList { trust } => {
            for hash in trust {
                println!("{hash}");
            }
            Ok(())
        }
        ResponseBody::Error { message } => {
            eprintln!("atty-guard: {message}");
            std::process::exit(1);
        }
        other => {
            eprintln!("atty-guard: unexpected response: {other:?}");
            std::process::exit(1);
        }
    }
}

/// Resolve the user the operation should target. When the CLI runs
/// under sudo, `SUDO_UID` is set to the invoking user's UID — we
/// forward that as `target_uid` so the daemon writes into THAT
/// user's `/var/lib/atty-guard/users/<uid>/` directory rather than
/// root's. Without sudo (or running directly as root with no
/// SUDO_UID), returns None — the daemon falls back to the connecting
/// peer's own UID, which is the normal read-only / single-user case.
fn sudo_target_uid() -> Option<u32> {
    std::env::var("SUDO_UID")
        .ok()
        .and_then(|s| s.parse::<u32>().ok())
}

fn send_and_check(socket: &Path, request: Request) -> std::io::Result<()> {
    let response = send_request(socket, request)?;
    match response {
        ResponseBody::Ok => Ok(()),
        ResponseBody::Error { message } => {
            eprintln!("atty-guard: {message}");
            std::process::exit(1);
        }
        other => {
            eprintln!("atty-guard: unexpected response: {other:?}");
            std::process::exit(1);
        }
    }
}

fn handle_atoms_list(
    socket: &Path,
    scope: AtomScope,
    target_uid: Option<u32>,
) -> std::io::Result<()> {
    let response = send_request(socket, Request::AtomsList { scope, target_uid })?;
    match response {
        ResponseBody::AtomsList { atoms } => {
            for atom in atoms {
                println!("{atom}");
            }
            Ok(())
        }
        ResponseBody::Error { message } => {
            eprintln!("atty-guard: {message}");
            std::process::exit(1);
        }
        other => {
            eprintln!("atty-guard: unexpected response: {other:?}");
            std::process::exit(1);
        }
    }
}

fn handle_urls_list(socket: &Path, target_uid: Option<u32>) -> std::io::Result<()> {
    let response = send_request(socket, Request::UrlsList { target_uid })?;
    match response {
        ResponseBody::UrlsList { entries } => {
            for entry in entries {
                // `decision\thost` so output pipes cleanly through
                // awk/grep — operators do `atty-guard urls list |
                // grep allow` etc.
                println!("{}\t{}", entry.decision, entry.host);
            }
            Ok(())
        }
        ResponseBody::Error { message } => {
            eprintln!("atty-guard: {message}");
            std::process::exit(1);
        }
        other => {
            eprintln!("atty-guard: unexpected response: {other:?}");
            std::process::exit(1);
        }
    }
}

fn handle_session_list(socket: &Path, target_uid: Option<u32>) -> std::io::Result<()> {
    let response = send_request(socket, Request::SessionList { target_uid })?;
    match response {
        ResponseBody::SessionList {
            atoms,
            urls_allow,
            urls_block,
            trust,
        } => {
            if atoms.is_empty()
                && urls_allow.is_empty()
                && urls_block.is_empty()
                && trust.is_empty()
            {
                println!("(session is empty)");
                return Ok(());
            }
            if !atoms.is_empty() {
                println!("atoms ({}):", atoms.len());
                for a in atoms {
                    println!("  {a}");
                }
            }
            if !urls_allow.is_empty() {
                println!("urls allow ({}):", urls_allow.len());
                for h in urls_allow {
                    println!("  {h}");
                }
            }
            if !urls_block.is_empty() {
                println!("urls block ({}):", urls_block.len());
                for h in urls_block {
                    println!("  {h}");
                }
            }
            if !trust.is_empty() {
                println!("trust ({}):", trust.len());
                for h in trust {
                    println!("  {h}");
                }
            }
            Ok(())
        }
        ResponseBody::Error { message } => {
            eprintln!("atty-guard: {message}");
            std::process::exit(1);
        }
        other => {
            eprintln!("atty-guard: unexpected response: {other:?}");
            std::process::exit(1);
        }
    }
}

/// Embedded copy of `contrib/atoms.pins.toml.example`. Shipped as a
/// compile-time string so `atoms pin-init` works even if the
/// `/etc/atty-guard/` install dropped the standalone `.example`
/// file (some package managers strip docs / examples).
const PIN_FILE_TEMPLATE: &str = include_str!("../contrib/atoms.pins.toml.example");

/// Render the drift snapshot. Exit codes:
///   0 — in-sync, live-tracking, or no snapshot available yet.
///   1 — daemon error / unexpected response (CLI-wide convention).
///   2 — at least one source is drifted. Honored by BOTH the human
///       and `--json` modes so CI gates work either way. Mind the
///       shell: in a pipeline `... | jq ...`, `$?` reflects jq's
///       exit code unless `set -o pipefail` is on. Either:
///         `set -o pipefail; atty-guard atoms drift --json | jq .`
///       or capture the status directly with the non-pipe form:
///         `atty-guard atoms drift --json > out.json; [ $? -eq 0 ]`.
fn handle_atoms_drift(socket: &Path, json: bool) -> std::io::Result<()> {
    let response = send_request(socket, Request::AtomsDrift)?;
    match response {
        ResponseBody::AtomsDrift {
            available,
            updated_at,
            sources,
        } => {
            let behind_count = sources.iter().filter(|s| s.is_behind()).count();
            if json {
                #[derive(serde::Serialize)]
                struct WirePayload<'a> {
                    available: bool,
                    updated_at: &'a Option<String>,
                    sources: &'a Vec<crate::protocol::DriftEntry>,
                }
                let payload = WirePayload {
                    available,
                    updated_at: &updated_at,
                    sources: &sources,
                };
                let s = serde_json::to_string_pretty(&payload).map_err(|e| {
                    std::io::Error::new(std::io::ErrorKind::Other, e)
                })?;
                println!("{s}");
                if behind_count > 0 {
                    // Explicit stdout flush before exit — `println!`
                    // is line-buffered on TTYs but BLOCK-buffered
                    // when stdout is piped (the CI usage path
                    // `atoms drift --json | jq`). `process::exit`
                    // doesn't run Rust's stdout LineWriter Drop, so
                    // a piped consumer could see an empty stdin
                    // before the exit code lands.
                    use std::io::Write;
                    let _ = std::io::stdout().flush();
                    std::process::exit(2);
                }
                return Ok(());
            }
            if !available {
                println!(
                    "atty-guard: no drift snapshot yet. The daemon writes \
                     /var/lib/atty-guard/atoms.drift.json after the first \
                     successful atom-refresh tick, which requires:\n\
                     \n  \
                     1. the daemon built with the `atoms-fetch` cargo \
                     feature\n  \
                     2. started with `--atoms-update-interval <N>` (or \
                     trigger a one-shot fetch via `sudo atty-guard \
                     --update-atoms-now`)\n\
                     \n\
                     If neither is configured, this is the expected \
                     steady state."
                );
                return Ok(());
            }
            if let Some(ts) = &updated_at {
                println!("# snapshot updated at {ts}");
            }
            for src in &sources {
                let pinned = src.pinned.as_deref().unwrap_or("(live tracking)");
                let upstream = src.upstream.as_deref().unwrap_or("(probe failed)");
                let status = match (&src.pinned, &src.upstream) {
                    (Some(p), Some(u)) if p == u => "in-sync",
                    (Some(_), Some(_)) => "BEHIND",
                    (None, Some(_)) => "live",
                    _ => "unknown",
                };
                let since = src
                    .behind_since
                    .as_deref()
                    .map(|s| format!(" (since {s})"))
                    .unwrap_or_default();
                println!(
                    "{name}\t{status}\tpinned={pinned}\tupstream={upstream}{since}",
                    name = src.name,
                );
            }
            if behind_count > 0 {
                // Exit 2 distinguishes "drift detected" from "I/O
                // error" (1) — CI scripts can gate on it without
                // having to parse the human output. Flush stdout
                // first; the human-mode println lines above go to
                // a piped consumer's stdout buffer too.
                use std::io::Write;
                let _ = std::io::stdout().flush();
                std::process::exit(2);
            }
            Ok(())
        }
        ResponseBody::Error { message } => {
            eprintln!("atty-guard: {message}");
            std::process::exit(1);
        }
        other => {
            eprintln!("atty-guard: unexpected response: {other:?}");
            std::process::exit(1);
        }
    }
}

/// Seed `/etc/atty-guard/atoms.pins.toml` from the bundled template
/// (the operator's one-shot opt-in entry point per #209 follow-up).
/// Local file op — does NOT round-trip through the daemon, because
/// the file lives at a root-owned path and the daemon's job is to
/// READ this file, not write it.
///
/// Writes are atomic: tmp + rename. If the operator hits Ctrl-C
/// mid-write the destination either contains the full template or
/// the prior file (or nothing on a fresh install). A truncated
/// pins.toml would brick the cron tick because `load_pins`
/// hard-fails on an empty file.
fn handle_pin_init(force: bool) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let path = std::path::Path::new(crate::atom_fetcher::DEFAULT_PIN_FILE);
    // /etc/atty-guard/atoms.pins.toml is root:root by the install
    // script's posture; non-root callers can't write it. Surface
    // the missing-sudo case cleanly rather than letting the
    // open(2) ENOENT/EACCES bubble out as a generic Rust error.
    // Tiny raw bind matches the pattern in atom_fetcher.rs /
    // trust_store.rs — keeps the crate libc-free.
    let euid = unsafe {
        extern "C" {
            fn geteuid() -> u32;
        }
        geteuid()
    };
    if euid != 0 {
        eprintln!(
            "atty-guard: `atoms pin-init` writes {} — run via `sudo`.",
            path.display()
        );
        std::process::exit(1);
    }
    if path.exists() && !force {
        eprintln!(
            "atty-guard: {} already exists. Pass --force to overwrite, or rm the \
             file first.",
            path.display()
        );
        std::process::exit(1);
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            std::io::Error::new(
                e.kind(),
                format!("create {}: {}", parent.display(), e),
            )
        })?;
    }
    // PID-suffixed tmp + create_new closes the symlink-pre-create
    // race AND the parallel-invocation race in one move (matches
    // the posture used by `atom_drift::write_snapshot` and
    // `trust_store::write_atomic`).
    let pid = std::process::id();
    let tmp = path.with_file_name(format!("atoms.pins.toml.tmp.{pid}"));
    {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
            .map_err(|e| {
                std::io::Error::new(e.kind(), format!("create {}: {}", tmp.display(), e))
            })?;
        f.write_all(PIN_FILE_TEMPLATE.as_bytes()).map_err(|e| {
            // Best-effort cleanup on partial write — a stale .tmp
            // shouldn't survive a failed pin-init.
            let _ = std::fs::remove_file(&tmp);
            std::io::Error::new(e.kind(), format!("write {}: {}", tmp.display(), e))
        })?;
        // 0644 matches `atom_fetcher::check_pin_file_perms` (root-
        // owned, no group/world-write). 0600 also passes the check;
        // we pick 0644 so a non-root operator can `cat` the file.
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o644))?;
    }
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        std::io::Error::new(e.kind(), format!("rename {}: {}", path.display(), e))
    })?;
    println!(
        "atty-guard: created {} from the bundled template. Edit it to uncomment \
         + fill the [gtfobins] / [sigma] sections, then `sudo systemctl reload \
         atty-guard` (or wait for the next cron tick).",
        path.display()
    );
    Ok(())
}

fn send_request(socket: &Path, request: Request) -> std::io::Result<ResponseBody> {
    let stream = UnixStream::connect(socket).map_err(|e| {
        std::io::Error::new(
            e.kind(),
            format!(
                "could not connect to atty-guard at {} ({e}). Is the daemon running? \
                 Check `sudo systemctl status atty-guard`. If you're a regular user, \
                 you must be in the `atty` group — `sudo usermod -aG atty $USER` and \
                 re-login.",
                socket.display()
            ),
        )
    })?;
    let mut writer = stream.try_clone()?;
    let mut reader = BufReader::new(stream);
    let envelope = Envelope {
        id: 1,
        body: request,
    };
    let serialized = serde_json::to_string(&envelope)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    writeln!(writer, "{serialized}")?;
    writer.flush()?;
    drop(writer); // signal EOF so the daemon flushes its reply
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let body: ResponseBody = serde_json::from_str(line.trim())
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    Ok(body)
}
