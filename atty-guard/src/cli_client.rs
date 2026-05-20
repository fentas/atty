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
    use crate::{AtomsOp, SessionOp, Subcommand, UrlsOp};
    let result = match sub {
        Subcommand::Atoms { op } => match op {
            AtomsOp::Add { pattern } => send_and_check(socket, Request::AtomsAdd { pattern }),
            AtomsOp::Remove { pattern } => {
                send_and_check(socket, Request::AtomsRemove { pattern })
            }
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
                handle_atoms_list(socket, scope)
            }
        },
        Subcommand::Urls { op } => match op {
            UrlsOp::Allow { host } => send_and_check(socket, Request::UrlsAllow { host }),
            UrlsOp::Block { host } => send_and_check(socket, Request::UrlsBlock { host }),
            UrlsOp::List => handle_urls_list(socket),
        },
        Subcommand::Session { op } => match op {
            SessionOp::List => handle_session_list(socket),
            SessionOp::Clear => send_and_check(socket, Request::SessionClear),
            SessionOp::Write => send_and_check(socket, Request::SessionWrite),
        },
    };
    result
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

fn handle_atoms_list(socket: &Path, scope: AtomScope) -> std::io::Result<()> {
    let response = send_request(socket, Request::AtomsList { scope })?;
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

fn handle_urls_list(socket: &Path) -> std::io::Result<()> {
    let response = send_request(socket, Request::UrlsList)?;
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

fn handle_session_list(socket: &Path) -> std::io::Result<()> {
    let response = send_request(socket, Request::SessionList)?;
    match response {
        ResponseBody::SessionList {
            atoms,
            urls_allow,
            urls_block,
        } => {
            if atoms.is_empty() && urls_allow.is_empty() && urls_block.is_empty() {
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
