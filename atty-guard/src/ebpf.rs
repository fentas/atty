//! V2-B userspace loader for the eBPF programs in `atty-guard/ebpf/`.
//!
//! When built with `--features ebpf`, `EbpfState::attach()` loads
//! the pre-built `atty_guard.bpf.o` (produced by `atty-guard/ebpf/
//! Makefile` — `make` in that dir), attaches the LSM hook + execve
//! tracepoint, and exposes typed accessors to the threat-level
//! hash map.
//!
//! Without the feature, every entry point returns
//! `LoadError::FeatureNotBuilt` so the daemon's startup path can
//! gracefully fall back to V2-A's in-memory threat map.
//!
//! Build path (one-time on the runtime host):
//!   cd atty-guard/ebpf && make    # produces atty_guard.bpf.o
//!   cargo build --release --features ebpf
//!
//! See `atty-guard/ebpf/README.md` for the kernel prereqs (≥ 5.7,
//! BTF, BPF LSM enabled, CAP_BPF).

use crate::protocol::ThreatLevel;

/// Which BPF map a `set_threat(Critical)` call writes to. Set
/// once at `EbpfState::attach()` and immutable for the daemon's
/// lifetime — flipping at runtime would race ongoing LSM hook
/// reads. `Disabled` isn't a variant: when the operator picks
/// disabled, `EbpfState` is never constructed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoadedMode {
    /// LSM programs loaded, but no daemon-driven map writes —
    /// kernel still emits tracepoint events for observability,
    /// nothing gets blocked or warn-flagged.
    Observe,
    /// `set_threat(Critical)` writes to `warn_pids`. LSM hook
    /// allows the execve, emits a `VERDICT_WARN` event.
    Warn,
    /// `set_threat(Critical)` writes to `threat_map`. LSM hook
    /// returns -EPERM (existing V2-B behaviour).
    Block,
}

/// Errors the loader can return. Kept narrow so the daemon's
/// startup path can degrade gracefully — any of these makes
/// atty-guard fall back to V2-A behaviour (in-memory threat map,
/// no kernel enforcement) and surface a warning to the user.
#[derive(Debug)]
pub enum LoadError {
    /// `--enable-ebpf` was passed but the crate wasn't built with
    /// the `ebpf` feature.
    FeatureNotBuilt,
    /// Kernel too old (< 5.7) or BTF unavailable.
    UnsupportedKernel(&'static str),
    /// CAP_BPF (or equivalent) not granted to the daemon process.
    MissingCapability(&'static str),
    /// Couldn't find `atty_guard.bpf.o` on disk.
    ObjectMissing(String),
    /// libbpf rejected the program (verifier failure / map create
    /// failure / attach error).
    LoadFailed(String),
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LoadError::FeatureNotBuilt => write!(
                f,
                "atty-guard was built without the `ebpf` feature — rebuild with `cargo build --features ebpf`"
            ),
            LoadError::UnsupportedKernel(why) => write!(f, "kernel does not support BPF LSM: {why}"),
            LoadError::MissingCapability(c) => write!(f, "missing capability: {c}"),
            LoadError::ObjectMissing(p) => write!(f, "atty_guard.bpf.o not found at {p}"),
            LoadError::LoadFailed(d) => write!(f, "libbpf failed: {d}"),
        }
    }
}

impl std::error::Error for LoadError {}

impl From<LoadError> for std::io::Error {
    fn from(e: LoadError) -> Self {
        std::io::Error::new(std::io::ErrorKind::Other, e.to_string())
    }
}

/// Byte length of `struct deny_key.path` in the BPF object — the deny-map
/// key is a fixed null-padded buffer of this size.
pub(crate) const DENY_PATH_LEN: usize = 256;

/// Encode a `strict` deny-binary path into the kernel deny-map key: a
/// fixed [DENY_PATH_LEN] null-padded buffer that byte-matches what the LSM
/// hook builds (`bpf_core_read_str(bprm->filename)` into a zeroed key).
/// Rejects empty, over-length, OR NUL-containing paths rather than
/// silently producing a key the kernel can never match — an exec path is a
/// NUL-terminated C string, so a `\0` in the daemon key would diverge from
/// the kernel's (which stops at the NUL), i.e. a deny that wouldn't deny.
/// Free function (not a method) so the encoding is unit-testable without a
/// loaded BPF object.
pub(crate) fn encode_deny_key(path: &str) -> Result<[u8; DENY_PATH_LEN], LoadError> {
    let bytes = path.as_bytes();
    if bytes.is_empty() || bytes.len() >= DENY_PATH_LEN {
        return Err(LoadError::LoadFailed(format!(
            "deny binary path {path:?} must be 1..={} bytes",
            DENY_PATH_LEN - 1
        )));
    }
    if bytes.contains(&0) {
        return Err(LoadError::LoadFailed(format!(
            "deny binary path {path:?} contains a NUL byte"
        )));
    }
    let mut key = [0u8; DENY_PATH_LEN];
    key[..bytes.len()].copy_from_slice(bytes);
    Ok(key)
}

/// Byte length of `struct bname_key.name` — the basename deny-map key (A+).
pub(crate) const DENY_NAME_LEN: usize = 64;

/// Encode a `strict` deny-BASENAME into the 64-byte null-padded key that
/// matches `struct bname_key` (the kernel builds it from the basename of
/// bprm->filename via bpf_loop). Rejects empty / over-length / NUL / and a
/// '/': a basename has no slash (the kernel keys the segment AFTER the last
/// '/'), so a slashed entry could never match — reject rather than load a
/// dead rule.
pub(crate) fn encode_basename_key(name: &str) -> Result<[u8; DENY_NAME_LEN], LoadError> {
    let bytes = name.as_bytes();
    if bytes.is_empty() || bytes.len() >= DENY_NAME_LEN {
        return Err(LoadError::LoadFailed(format!(
            "deny basename {name:?} must be 1..={} bytes",
            DENY_NAME_LEN - 1
        )));
    }
    if bytes.contains(&0) || bytes.contains(&b'/') {
        return Err(LoadError::LoadFailed(format!(
            "deny basename {name:?} must not contain NUL or '/'"
        )));
    }
    let mut key = [0u8; DENY_NAME_LEN];
    key[..bytes.len()].copy_from_slice(bytes);
    Ok(key)
}

#[cfg(test)]
mod deny_key_tests {
    use super::{encode_basename_key, encode_deny_key, DENY_NAME_LEN, DENY_PATH_LEN};

    #[test]
    fn rejects_empty_overlong_and_nul() {
        assert!(encode_deny_key("").is_err());
        assert!(encode_deny_key(&"x".repeat(DENY_PATH_LEN)).is_err());
        assert!(encode_deny_key("/usr/bin/n\0c").is_err());
    }

    #[test]
    fn encodes_null_padded_exact() {
        let key = encode_deny_key("/usr/bin/nc").unwrap();
        assert_eq!(&key[.."/usr/bin/nc".len()], b"/usr/bin/nc");
        // Everything past the path is zero — byte-matches the kernel's
        // zeroed key + bpf_core_read_str (path + NUL, rest 0).
        assert!(key["/usr/bin/nc".len()..].iter().all(|&b| b == 0));
    }

    #[test]
    fn basename_key_rejects_slash_nul_empty_overlong() {
        assert!(encode_basename_key("").is_err());
        assert!(encode_basename_key(&"x".repeat(DENY_NAME_LEN)).is_err());
        assert!(encode_basename_key("n\0c").is_err());
        assert!(encode_basename_key("usr/bin/nc").is_err()); // has '/'
        let key = encode_basename_key("nc").unwrap();
        assert_eq!(&key[..2], b"nc");
        assert!(key[2..].iter().all(|&b| b == 0));
    }
}

// ===========================================================================
// Feature-OFF stub.
//
// When the `ebpf` feature is disabled we ship a single-field struct
// that exposes the SAME API as the feature-on path, but every
// method short-circuits with `FeatureNotBuilt`. This keeps the
// daemon's startup code (main.rs) and the threat-map dispatch
// (threat_map.rs) feature-agnostic — they call `attach()` once
// and either get a working state or a clean error.

#[cfg(not(feature = "ebpf"))]
pub struct EbpfState;

#[cfg(not(feature = "ebpf"))]
impl EbpfState {
    pub fn attach(
        _mode: LoadedMode,
        _broadcast: std::sync::Arc<crate::warn_consumer::Broadcast>,
        _classifier: std::sync::Arc<crate::classifier::Classifier>,
        _active_profile: std::sync::Arc<std::sync::atomic::AtomicU8>,
        _smart_can_freeze: bool,
    ) -> Result<Self, LoadError> {
        Err(LoadError::FeatureNotBuilt)
    }
    /// Stub for builds without the `ebpf` feature. `get_threat` on
    /// the no-eBPF path would always be Low since there's no kernel
    /// map to read; the in-memory `ThreatMap` is the only source.
    /// `#[allow(dead_code)]` because nothing invokes this today —
    /// `threat_map.rs` stores `Option<Arc<EbpfState>>` but currently
    /// only writes through `set_threat`. Placeholder for future
    /// kernel-map reads (e.g. the daemon answering "what's the
    /// threat level for pid X" via UDS) where the kernel-side BPF
    /// map would be the source of truth on attach-enabled builds.
    #[allow(dead_code)]
    pub fn get_threat(&self, _pid: u32) -> ThreatLevel {
        ThreatLevel::Low
    }
    pub fn set_threat(&self, _pid: u32, _level: ThreatLevel) -> Result<(), LoadError> {
        Err(LoadError::FeatureNotBuilt)
    }
    pub fn set_watch(&self, _pid: u32) -> Result<(), LoadError> {
        Err(LoadError::FeatureNotBuilt)
    }
    pub fn set_deny_bin(&self, _path: &str) -> Result<(), LoadError> {
        Err(LoadError::FeatureNotBuilt)
    }
    pub fn set_deny_basename(&self, _name: &str) -> Result<(), LoadError> {
        Err(LoadError::FeatureNotBuilt)
    }
    pub fn clear_deny_bin(&self, _path: &str) -> Result<(), LoadError> {
        Err(LoadError::FeatureNotBuilt)
    }
    pub fn clear_deny_basename(&self, _name: &str) -> Result<(), LoadError> {
        Err(LoadError::FeatureNotBuilt)
    }
    pub fn set_basename_gate(&self, _active: bool) -> Result<(), LoadError> {
        Err(LoadError::FeatureNotBuilt)
    }
    pub fn set_enforce_cfg(&self, _mode: u8, _max_depth: u8) -> Result<(), LoadError> {
        Err(LoadError::FeatureNotBuilt)
    }
}

// ===========================================================================
// Feature-ON impl.

#[cfg(feature = "ebpf")]
mod with_libbpf {
    use super::{LoadError, LoadedMode, ThreatLevel};
    use libbpf_rs::{MapCore, MapFlags};
    use std::path::PathBuf;

    /// Resolve `atty_guard.bpf.o` from one of the conventional
    /// locations. Tries (1) sibling-of-binary, (2) source-tree
    /// path (developer workflow), (3) the standard install path
    /// the systemd unit ships into. Failing all three returns
    /// the search list so the user knows where to drop it.
    fn locate_bpf_object() -> Result<PathBuf, LoadError> {
        let mut tried: Vec<PathBuf> = Vec::with_capacity(3);

        if let Ok(exe) = std::env::current_exe() {
            if let Some(dir) = exe.parent() {
                let p = dir.join("atty_guard.bpf.o");
                if p.exists() {
                    return Ok(p);
                }
                tried.push(p);
            }
        }

        let src = PathBuf::from(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/ebpf/atty_guard.bpf.o"
        ));
        if src.exists() {
            return Ok(src);
        }
        tried.push(src);

        let sys = PathBuf::from("/usr/lib/atty-guard/atty_guard.bpf.o");
        if sys.exists() {
            return Ok(sys);
        }
        tried.push(sys);

        Err(LoadError::ObjectMissing(
            tried
                .into_iter()
                .map(|p| p.display().to_string())
                .collect::<Vec<_>>()
                .join(", "),
        ))
    }

    /// Holds the loaded BPF `Object` via a `Box::leak`'d static
    /// reference (so the RingBuffer in the consumer thread can
    /// borrow from it for 'static) + the `Link` handles that keep
    /// the programs attached — dropping the Links detaches.
    ///
    /// The leak is intentional: the daemon's BPF state lives for
    /// the entire process lifetime (there's no graceful kernel-
    /// side unload path while atty proxies are still subscribed
    /// to the ringbuf), and clean lifetime management of the
    /// Object across the set_threat caller threads + the
    /// long-lived consumer thread is otherwise gnarly. ~10 KB of
    /// permanent heap is a trivial cost for a sidecar.
    pub struct EbpfState {
        obj: ObjectHandle,
        _lsm_link: libbpf_rs::Link,
        /// AF_ALG socket() tracepoint — copy.fail-class kernel-LPE
        /// signal. Loaded as part of the same .o so the user pays
        /// for one BPF object load even if they only care about
        /// the execve enforcement path.
        _tp_socket_link: libbpf_rs::Link,
        /// sched fork/exit tracepoints. trace_fork propagates a mark only
        /// in propagate mode; trace_exit GCs in every mode. Always
        /// attached regardless of the configured depth.
        _tp_fork_link: libbpf_rs::Link,
        _tp_exit_link: libbpf_rs::Link,
        mode: LoadedMode,
        /// Detached ringbuf consumer thread (`atty-guard-ringbuf`).
        /// Held only to make the handle visible in `ps`; we never
        /// join — the thread runs until process exit.
        _consumer: std::thread::JoinHandle<()>,
        /// Detached classify worker (`atty-guard-classify`) — runs the
        /// slow /proc + Tier-1/2 + kill path off the ringbuf poll. Same
        /// lifetime as the consumer; never joined.
        _classify_worker: std::thread::JoinHandle<()>,
    }

    /// Sync wrapper around the leaked `&'static Object`. libbpf-rs
    /// marks `Object` as `!Sync` defensively, but its `&self`
    /// methods we actually call (`maps().find()`, then `Map`'s
    /// `lookup`/`update`/`delete`) all delegate to kernel syscalls
    /// (`bpf(BPF_MAP_*_ELEM)`) which are atomic per-key on the
    /// kernel side. Concurrent access from the consumer thread
    /// (read-only — only iterates maps to find the ringbuf) and
    /// the per-connection RPC threads (lookup/update/delete) is
    /// safe under that contract.
    pub struct ObjectHandle(&'static libbpf_rs::Object);
    // SAFETY-redundant — EbpfState's outer impl also asserts these,
    // but local impl makes the intent self-contained should the
    // wrapper ever leave EbpfState.
    unsafe impl Sync for ObjectHandle {}
    unsafe impl Send for ObjectHandle {}

    /// Daemon-start instant for monotonic `timestamp_ms` on warn
    /// events. `SystemTime::now()` would jump on NTP step / DST /
    /// manual clock set — a backwards-stepping timestamp on a warn
    /// banner looks like a duplicate. Captured once at first read;
    /// `Instant::elapsed` is monotonic per std lib contract.
    static DAEMON_START: std::sync::LazyLock<std::time::Instant> =
        std::sync::LazyLock::new(std::time::Instant::now);

    // SAFETY: `libbpf_rs::Link` wraps `NonNull<bpf_link>` and isn't
    // auto-Send/Sync. We only touch Links at `EbpfState::Drop`,
    // which runs once when the last Arc handle drops. Sharing the
    // EbpfState across the daemon's per-connection threads via
    // Arc is therefore safe.
    unsafe impl Send for EbpfState {}
    unsafe impl Sync for EbpfState {}

    impl EbpfState {
        pub fn attach(
            mode: LoadedMode,
            broadcast: std::sync::Arc<crate::warn_consumer::Broadcast>,
            classifier: std::sync::Arc<crate::classifier::Classifier>,
            // Live profile: the runtime-switchable AtomicU8 (the SetProfile
            // RPC writes it; the worker reads it per-event so a switch takes
            // effect on the next exec). `smart_can_freeze` is the static
            // consent knob — not switchable, so passed by value.
            active_profile: std::sync::Arc<std::sync::atomic::AtomicU8>,
            smart_can_freeze: bool,
        ) -> Result<Self, LoadError> {
            let path = locate_bpf_object()?;
            let mut obj_builder = libbpf_rs::ObjectBuilder::default();
            let open_obj = obj_builder
                .open_file(&path)
                .map_err(|e| LoadError::LoadFailed(format!("open {}: {e}", path.display())))?;
            let mut obj = open_obj
                .load()
                .map_err(|e| LoadError::LoadFailed(format!("load: {e}")))?;

            // Auto-attach uses the SEC() annotations on each program
            // (lsm/bprm_check_security, the sched + AF_ALG tracepoints)
            // to pick the right hook + attach helper.
            let lsm_link = obj
                .progs_mut()
                .find(|p| p.name() == "check_execve")
                .ok_or_else(|| {
                    LoadError::LoadFailed("program check_execve missing from .o".into())
                })?
                .attach()
                .map_err(|e| LoadError::LoadFailed(format!("attach lsm: {e}")))?;

            let tp_socket_link = obj
                .progs_mut()
                .find(|p| p.name() == "trace_socket")
                .ok_or_else(|| {
                    LoadError::LoadFailed("program trace_socket missing from .o".into())
                })?
                .attach()
                .map_err(|e| LoadError::LoadFailed(format!("attach socket tracepoint: {e}")))?;

            let tp_fork_link = obj
                .progs_mut()
                .find(|p| p.name() == "trace_fork")
                .ok_or_else(|| LoadError::LoadFailed("program trace_fork missing from .o".into()))?
                .attach()
                .map_err(|e| LoadError::LoadFailed(format!("attach fork tracepoint: {e}")))?;

            let tp_exit_link = obj
                .progs_mut()
                .find(|p| p.name() == "trace_exit")
                .ok_or_else(|| LoadError::LoadFailed("program trace_exit missing from .o".into()))?
                .attach()
                .map_err(|e| LoadError::LoadFailed(format!("attach exit tracepoint: {e}")))?;

            // Leak the Object so its borrows can live 'static. The
            // consumer thread holds a RingBuffer<'static> built from
            // a Map borrow off this Object; the per-connection RPC
            // threads also borrow Map handles for set_threat. Both
            // need the same Object alive forever — daemon lifetime
            // is process lifetime so the leak is the natural fit.
            let obj_static: &'static libbpf_rs::Object = Box::leak(Box::new(obj));
            let obj_handle = ObjectHandle(obj_static);

            // Build the ringbuf consumer + spawn its thread before
            // returning so the LSM hook's first event has somewhere
            // to land. RingBuffer<'static> moves into the thread;
            // the broadcast Arc clone outlives the callback.
            let events_map = obj_static
                .maps()
                .find(|m| m.name() == "events")
                .ok_or_else(|| LoadError::LoadFailed("events ringbuf missing".into()))?;
            // Slow per-event work (the /proc/cmdline fan-out + Tier-1/2
            // classify + kill) runs on a dedicated WORKER thread, not
            // inline in the ringbuf callback: the callback runs under
            // rb.poll(), and blocking it (the /proc read retries for ms)
            // would back the ringbuf up under a fork storm and drop events
            // — a silent detection bypass. Warn events are a cheap
            // broadcast (no /proc) and stay inline.
            let bcast_for_cb = broadcast.clone();
            // BOUNDED channel (drop-on-full), mirroring the warn path's
            // SyncSender: an in-session exec storm can outrun the worker
            // (each /proc read can take ms), so an unbounded queue would
            // grow daemon RSS without limit. Dropping when full is the
            // same fail-open as a ringbuf overflow.
            let (classify_tx, classify_rx) =
                std::sync::mpsc::sync_channel::<crate::warn_consumer::ExecveEvent>(1024);
            let classify_worker = {
                let classifier = classifier.clone();
                let broadcast = broadcast.clone();
                let active_profile = active_profile.clone();
                std::thread::Builder::new()
                    .name("atty-guard-classify".into())
                    .spawn(move || {
                        while let Ok(evt) = classify_rx.recv() {
                            let now_ms = DAEMON_START.elapsed().as_millis() as u64;
                            // Read the LIVE profile per event so a SetProfile
                            // switch takes effect on the next exec; the
                            // consent knob is static.
                            let policy = crate::profile::RoutingPolicy {
                                profile: crate::profile::SecurityProfile::from_u8(
                                    active_profile.load(std::sync::atomic::Ordering::Relaxed),
                                ),
                                smart_can_freeze,
                            };
                            // Isolate a per-event panic so one bad event
                            // can't permanently kill the effector thread.
                            let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                                dispatch_classify(&evt, now_ms, &broadcast, &classifier, policy);
                            }));
                            if r.is_err() {
                                eprintln!(
                                    "atty-guard: classify worker recovered from a panic (pid {})",
                                    evt.pid
                                );
                            }
                        }
                        eprintln!("atty-guard: classify worker exiting (channel closed)");
                    })
                    .map_err(|e| LoadError::LoadFailed(format!("spawn classify worker: {e}")))?
            };
            let mut rb_builder = libbpf_rs::RingBufferBuilder::new();
            rb_builder
                .add(&events_map, move |data| {
                    ringbuf_callback(data, &bcast_for_cb, &classify_tx);
                    0
                })
                .map_err(|e| LoadError::LoadFailed(format!("ringbuf add: {e}")))?;
            let rb = rb_builder
                .build()
                .map_err(|e| LoadError::LoadFailed(format!("ringbuf build: {e}")))?;
            // Drop the explicit map binding so the implicit borrow
            // ends; the RingBuffer holds its own reference via
            // libbpf-rs internals.
            drop(events_map);

            let consumer = std::thread::Builder::new()
                .name("atty-guard-ringbuf".into())
                .spawn(move || consumer_loop(rb))
                .map_err(|e| LoadError::LoadFailed(format!("spawn ringbuf consumer: {e}")))?;

            Ok(Self {
                obj: obj_handle,
                _lsm_link: lsm_link,
                _tp_socket_link: tp_socket_link,
                _tp_fork_link: tp_fork_link,
                _tp_exit_link: tp_exit_link,
                mode,
                _consumer: consumer,
                _classify_worker: classify_worker,
            })
        }

        pub fn mode(&self) -> LoadedMode {
            self.mode
        }

        /// Look up a PID's threat level. Returns Low for unmapped
        /// keys (matches the kernel-side `if (level && ...)`
        /// check which treats absence-of-mark as Low).
        pub fn get_threat(&self, pid: u32) -> ThreatLevel {
            let map = match self.obj.0.maps().find(|m| m.name() == "threat_map") {
                Some(m) => m,
                None => return ThreatLevel::Low,
            };
            let key = pid.to_ne_bytes();
            match map.lookup(&key, MapFlags::ANY) {
                Ok(Some(bytes)) if !bytes.is_empty() => match bytes[0] {
                    0 => ThreatLevel::Low,
                    1 => ThreatLevel::High,
                    2 => ThreatLevel::Critical,
                    _ => ThreatLevel::Low,
                },
                _ => ThreatLevel::Low,
            }
        }

        /// Write or clear a PID's threat level. Routes to the
        /// kernel map appropriate for the current mode:
        ///
        /// - `Block` mode: `Critical` writes `threat_map[pid]=2`
        ///   so the LSM hook EPERMs (existing V2-B path). `High`
        ///   also writes `threat_map[pid]=1` so tracepoint events
        ///   can be annotated; the LSM hook ignores High.
        /// - `Warn` mode: `Critical` writes `warn_pids[pid]` so
        ///   the LSM hook emits a `VERDICT_WARN` event and
        ///   allows the execve. `High` still writes `threat_map`
        ///   (annotation-only, same as block mode).
        /// - `Observe` mode: every level is a no-op — operator
        ///   asked for tracepoint-only visibility, no daemon-
        ///   driven map state.
        ///
        /// `Low` clears the PID from BOTH maps. Kernel-side LSM
        /// hook checks threat_map then warn_pids; leaving either
        /// stale would leak the prior verdict to the next execve.
        pub fn set_threat(&self, pid: u32, level: ThreatLevel) -> Result<(), LoadError> {
            let key = pid.to_ne_bytes();
            if matches!(level, ThreatLevel::Low) {
                return self.clear_both(&key);
            }
            if matches!(self.mode, LoadedMode::Observe) {
                return Ok(());
            }
            match (self.mode, level) {
                (LoadedMode::Warn, ThreatLevel::Critical) => self.update("warn_pids", &key, &[1u8]),
                (LoadedMode::Block, ThreatLevel::Critical) => {
                    self.update("threat_map", &key, &[2u8])
                }
                (_, ThreatLevel::High) => self.update("threat_map", &key, &[1u8]),
                _ => Ok(()),
            }
        }

        /// Mark `pid` as in the watched atty-session subtree (security
        /// profiles). The fork hook propagates the mark to descendants;
        /// the LSM hook emits a VERDICT_CLASSIFY event for watched execs.
        /// Clearing is handled kernel-side by trace_exit on process exit.
        pub fn set_watch(&self, pid: u32) -> Result<(), LoadError> {
            self.update("watch_pids", &pid.to_ne_bytes(), &[1u8])
        }

        /// Add a binary PATH to the kernel deny-map (`strict`, Phase 3 A):
        /// a watched exec of this exact path is -EPERM'd synchronously by
        /// the LSM hook, before it runs. The key is a fixed 256-byte
        /// null-padded buffer matching `struct deny_key` in the BPF object
        /// (the kernel reads bprm->filename into the same shape, so the
        /// trailing zeros line up for an exact hash match). A path that
        /// wouldn't fit is rejected rather than silently truncated to a
        /// different key. (Basename matching is the A+ layer — it needs an
        /// in-kernel scan the verifier only accepts via bpf_loop.)
        pub fn set_deny_bin(&self, path: &str) -> Result<(), LoadError> {
            let key = super::encode_deny_key(path)?;
            self.update("deny_bins", &key, &[1u8])
        }

        /// Add a binary BASENAME to the kernel deny-map (`strict`, A+): a
        /// watched exec whose basename matches is -EPERM'd synchronously,
        /// catching the target at any path (the kernel extracts the
        /// basename of bprm->filename via bpf_loop).
        pub fn set_deny_basename(&self, name: &str) -> Result<(), LoadError> {
            let key = super::encode_basename_key(name)?;
            self.update("deny_basenames", &key, &[1u8])
        }

        /// Remove a binary PATH from the kernel deny-map — a runtime switch
        /// AWAY from `strict` clears exactly the key set_deny_bin inserted,
        /// so a weaker profile doesn't keep synchronously -EPERM'ing it.
        pub fn clear_deny_bin(&self, path: &str) -> Result<(), LoadError> {
            // A key is only in the map if encode SUCCEEDED at arm time, so an
            // encode error here means there's nothing to clear — no-op, not
            // an error (don't log a phantom failure for a never-armed rule).
            let key = match super::encode_deny_key(path) {
                Ok(k) => k,
                Err(_) => return Ok(()),
            };
            self.delete("deny_bins", &key)
        }

        /// Remove a BASENAME from the kernel deny-map (runtime switch away
        /// from `strict`).
        pub fn clear_deny_basename(&self, name: &str) -> Result<(), LoadError> {
            let key = match super::encode_basename_key(name) {
                Ok(k) => k,
                Err(_) => return Ok(()),
            };
            self.delete("deny_basenames", &key)
        }

        /// Flip the kernel `basename_gate` so the LSM hook only runs the
        /// (expensive) per-exec basename scan when deny_basenames is
        /// non-empty — audit/session leave it off.
        pub fn set_basename_gate(&self, active: bool) -> Result<(), LoadError> {
            self.update("basename_gate", &0u32.to_ne_bytes(), &[active as u8])
        }

        /// Clear the PID from BOTH maps in a single sweep. Map
        /// operations are kernel-side atomic per-key; reading
        /// either map between the two deletes can observe a
        /// half-cleared state, but the LSM hook itself does its
        /// own kernel-side reads against the live maps and never
        /// observes the userspace race (libbpf delete is sync).
        fn clear_both(&self, key: &[u8]) -> Result<(), LoadError> {
            for map_name in ["threat_map", "warn_pids"] {
                if let Some(map) = self.obj.0.maps().find(|m| m.name() == map_name) {
                    let _ = map.delete(key);
                }
            }
            Ok(())
        }

        fn update(&self, map_name: &str, key: &[u8], value: &[u8]) -> Result<(), LoadError> {
            let map = self
                .obj
                .0
                .maps()
                .find(|m| m.name() == map_name)
                .ok_or_else(|| {
                    LoadError::LoadFailed(format!("{map_name} missing from loaded object"))
                })?;
            map.update(key, value, MapFlags::ANY)
                .map_err(|e| LoadError::LoadFailed(format!("{map_name} update: {e}")))
        }

        /// Write the enforcement-depth config the LSM hook reads on
        /// every execve. `mode`: 0 one_level / 1 ancestry / 2
        /// propagate-on-fork. `max_depth` only matters for ancestry
        /// (the kernel walks at most MAX_ANCESTRY=16 hops). Single-entry ARRAY
        /// at key 0; the value layout matches the C `struct
        /// enforce_config` { u8 mode; u8 max_depth; u8 _pad[6] }.
        pub fn set_enforce_cfg(&self, mode: u8, max_depth: u8) -> Result<(), LoadError> {
            let key: u32 = 0;
            let value = [mode, max_depth, 0, 0, 0, 0, 0, 0];
            self.update("enforce_cfg", &key.to_ne_bytes(), &value)
        }

        fn delete(&self, map_name: &str, key: &[u8]) -> Result<(), LoadError> {
            let map = self
                .obj
                .0
                .maps()
                .find(|m| m.name() == map_name)
                .ok_or_else(|| {
                    LoadError::LoadFailed(format!("{map_name} missing from loaded object"))
                })?;
            map.delete(key)
                .map_err(|e| LoadError::LoadFailed(format!("{map_name} delete: {e}")))
        }
    }

    /// Ringbuf consumer entry point — runs in the
    /// `atty-guard-ringbuf` thread until the process exits.
    ///
    /// `poll(500ms)` is the canonical libbpf idiom: blocks via
    /// epoll until kernel pushes data OR the timeout expires.
    /// Errors here are catastrophic libbpf failures (negative fd,
    /// etc) — log + back off briefly so the thread doesn't spin
    /// if libbpf is in a bad state.
    fn consumer_loop(rb: libbpf_rs::RingBuffer<'static>) {
        loop {
            match rb.poll(std::time::Duration::from_millis(500)) {
                Ok(()) => {}
                Err(e) => {
                    eprintln!("atty-guard: ringbuf poll error: {e} — backing off");
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
            }
        }
    }

    /// Per-event callback inside the libbpf poll — kept FAST: parse, then
    /// broadcast warn events inline (cheap, no I/O) and hand classify
    /// events to the worker thread (the slow /proc + classify + kill
    /// path). Block events are ignored (atty renders the banner from the
    /// EPERM).
    fn ringbuf_callback(
        data: &[u8],
        broadcast: &std::sync::Arc<crate::warn_consumer::Broadcast>,
        classify_tx: &std::sync::mpsc::SyncSender<crate::warn_consumer::ExecveEvent>,
    ) {
        let Some(evt) = crate::warn_consumer::ExecveEvent::from_bytes(data) else {
            return;
        };

        // Block-mode warn pilot (existing path): surface VERDICT_WARN.
        if evt.is_warn() {
            let now_ms = DAEMON_START.elapsed().as_millis() as u64;
            broadcast.broadcast(
                evt.pid,
                evt.to_warn_event(now_ms),
                crate::warn_consumer::pid_in_tree_root,
            );
            return;
        }

        // Security-profile path: hand off to the worker — never block the
        // poll. try_send so a full queue (worker behind under an exec
        // storm) or a gone worker drops the event (fail-open, same as a
        // ringbuf overflow) instead of blocking the poll.
        if evt.is_classify() {
            let _ = classify_tx.try_send(evt);
        }
    }

    /// Route a watch-scoped execve: classify → `RoutingPolicy::decide` →
    /// act. Runs on the `atty-guard-classify` worker thread (off both the
    /// syscall path and the ringbuf poll), so a kill here is the reactive
    /// `session` response — the exec has already started.
    fn dispatch_classify(
        evt: &crate::warn_consumer::ExecveEvent,
        now_ms: u64,
        broadcast: &std::sync::Arc<crate::warn_consumer::Broadcast>,
        classifier: &crate::classifier::Classifier,
        policy: crate::profile::RoutingPolicy,
    ) {
        use crate::profile::{ExecContext, LoadPressure, Mechanism, Tier1Verdict};

        // The kernel event carries only bprm->filename (the binary); the
        // Tier-1 atoms match full command patterns (e.g. curl|sh), so fan
        // out to /proc/<pid>/cmdline for the real command. A live read
        // also proves the PID still refers to the process we're about to
        // act on — `session` won't kill on the fallback (see below).
        let live_cmd = read_proc_cmdline(evt.pid);
        let cmd = live_cmd
            .clone()
            .unwrap_or_else(|| crate::warn_consumer::cstr_trim(&evt.argv0));
        let tier1 = match classifier.classify(&cmd).verdict {
            crate::protocol::Verdict::Block => Tier1Verdict::KnownBad,
            crate::protocol::Verdict::Warn => Tier1Verdict::Suspicious,
            crate::protocol::Verdict::Safe => Tier1Verdict::Safe,
        };
        let comm = crate::warn_consumer::cstr_trim(&evt.comm);
        let is_interpreter = matches!(
            comm.as_str(),
            "python"
                | "python3"
                | "node"
                | "sh"
                | "bash"
                | "dash"
                | "zsh"
                | "ruby"
                | "perl"
                | "php"
                | "lua"
        );
        let ctx = ExecContext {
            tier1,
            is_interpreter,
            // Only the `smart` profile (P5) reads this; audit/session
            // ignore it. Conservative false until the proxy reports the
            // session shell pid.
            parent_is_interactive_shell: false,
            in_watch_scope: true,
            load: LoadPressure::Normal,
        };
        let mech = policy.decide(&ctx);
        match mech {
            Mechanism::Allow => {}
            // audit: surface it (reuse the warn-event broadcast/scrollback).
            Mechanism::WarnAsync => broadcast.broadcast(
                evt.pid,
                evt.to_warn_event(now_ms),
                crate::warn_consumer::pid_in_tree_root,
            ),
            // session: reactive SIGKILL if the deeper verdict isn't clean.
            // SIGKILL is terminal + clean (no SIGSTOP limbo). The exec
            // already started; this is the reactive response.
            Mechanism::ClassifyAsyncThenKill => {
                if tier1 != Tier1Verdict::Safe {
                    if live_cmd.is_none() {
                        // The /proc read failed → the process has likely
                        // already exited; killing evt.pid now could hit a
                        // recycled PID (with CAP_KILL, any user's process).
                        // Don't act on a stale identity.
                        eprintln!(
                            "atty-guard: session skipping kill of pid {} — cmdline unreadable (exited?)",
                            evt.pid
                        );
                    } else if unsafe { kill(evt.pid as i32, 9) } != 0 {
                        // Signalling another user's process needs CAP_KILL;
                        // log + degrade to audit-visible rather than a silent
                        // no-op so a missing cap still surfaces the threat.
                        let e = std::io::Error::last_os_error();
                        eprintln!(
                            "atty-guard: session SIGKILL pid {} failed: {e} (need CAP_KILL?)",
                            evt.pid
                        );
                        broadcast.broadcast(
                            evt.pid,
                            evt.to_warn_event(now_ms),
                            crate::warn_consumer::pid_in_tree_root,
                        );
                    }
                }
            }
            // P3 (strict) / P4 (lockdown) effectors aren't driven from the
            // async consumer; log intent until those phases land.
            Mechanism::BlockInKernel | Mechanism::FreezeAndFrisk => {
                eprintln!(
                    "atty-guard: profile would {mech:?} pid {} (effector not in this build)",
                    evt.pid
                );
            }
        }
    }

    /// Best-effort full command line from /proc/<pid>/cmdline (NUL-
    /// separated argv → space-joined). The classify event carries only
    /// the binary path; the full command is what the Tier-1 pattern atoms
    /// need. The event is submitted DURING check_execve (before the exec
    /// finishes populating the new /proc/<pid>/cmdline) and libbpf's
    /// epoll wakes us almost immediately, so the first read can race the
    /// still-empty cmdline — retry briefly while it's present-but-empty.
    /// A read ERROR (ENOENT) means the process already exited: return at
    /// once rather than burn the worker ~22ms retrying a gone PID (the
    /// common case for short-lived in-session execs). None → caller falls
    /// back to argv0 (and `session` won't kill on the fallback).
    fn read_proc_cmdline(pid: u32) -> Option<String> {
        let path = format!("/proc/{pid}/cmdline");
        for attempt in 0..12 {
            let raw = std::fs::read(&path).ok()?;
            let joined = raw
                .split(|&b| b == 0)
                .filter(|seg| !seg.is_empty())
                .map(String::from_utf8_lossy)
                .collect::<Vec<_>>()
                .join(" ");
            if !joined.is_empty() {
                return Some(joined);
            }
            if attempt < 11 {
                std::thread::sleep(std::time::Duration::from_millis(2));
            }
        }
        None
    }

    // Hand-rolled FFI — the crate intentionally avoids the libc crate
    // (matches shutdown.rs / cli_client.rs). SIGKILL = 9.
    extern "C" {
        fn kill(pid: i32, sig: i32) -> i32;
    }
}

#[cfg(feature = "ebpf")]
pub use with_libbpf::EbpfState;

// ===========================================================================
// Tests — only the no-feature path runs from this crate's test
// suite. The feature-on path needs CAP_BPF + a running kernel
// with BPF LSM enabled; that's manual / integration territory.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_error_display_includes_diagnostic_hint() {
        let e = LoadError::FeatureNotBuilt;
        let s = format!("{e}");
        assert!(s.contains("--features ebpf"));
    }

    #[test]
    fn load_error_unsupported_kernel_includes_reason() {
        let e = LoadError::UnsupportedKernel("BTF missing");
        let s = format!("{e}");
        assert!(s.contains("BTF missing"));
    }

    #[test]
    fn load_error_converts_to_io_error_with_message() {
        let e = LoadError::ObjectMissing("/x/y.o".into());
        let io: std::io::Error = e.into();
        let msg = io.to_string();
        assert!(msg.contains("/x/y.o"));
    }

    #[cfg(not(feature = "ebpf"))]
    #[test]
    fn attach_without_feature_returns_feature_not_built() {
        match EbpfState::attach(
            LoadedMode::Block,
            std::sync::Arc::new(crate::warn_consumer::Broadcast::new()),
            std::sync::Arc::new(crate::classifier::Classifier::new()),
            std::sync::Arc::new(std::sync::atomic::AtomicU8::new(0)),
            false,
        ) {
            Err(LoadError::FeatureNotBuilt) => {}
            Err(other) => panic!("expected FeatureNotBuilt, got {other:?}"),
            Ok(_) => panic!("expected Err on feature-disabled build"),
        }
    }

    #[cfg(not(feature = "ebpf"))]
    #[test]
    fn set_threat_without_feature_returns_error() {
        let s = EbpfState;
        match s.set_threat(123, ThreatLevel::High) {
            Err(LoadError::FeatureNotBuilt) => {}
            other => panic!("expected FeatureNotBuilt, got {other:?}"),
        }
    }

    #[cfg(not(feature = "ebpf"))]
    #[test]
    fn get_threat_without_feature_returns_low() {
        let s = EbpfState;
        assert!(matches!(s.get_threat(123), ThreatLevel::Low));
    }

    #[test]
    fn loaded_mode_variants_exhausted() {
        // Sentinel — adding a new LoadedMode variant must also be
        // matched here. Wildcard `_` arm intentionally omitted so
        // the compiler surfaces the gap; the conversion in
        // main.rs's effective_mode → LoadedMode + the set_threat
        // dispatch in this file both need updating in lockstep.
        fn _exhaust(m: LoadedMode) {
            match m {
                LoadedMode::Observe => {}
                LoadedMode::Warn => {}
                LoadedMode::Block => {}
            }
        }
        _exhaust(LoadedMode::Block);
    }
}
