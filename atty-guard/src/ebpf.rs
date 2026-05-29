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
    pub fn attach(_mode: LoadedMode) -> Result<Self, LoadError> {
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
}

// ===========================================================================
// Feature-ON impl.

#[cfg(feature = "ebpf")]
mod with_libbpf {
    use super::{LoadError, LoadedMode, ThreatLevel};
    use libbpf_rs::{MapCore, MapFlags};
    use std::path::PathBuf;
    use std::sync::Mutex;

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

    /// Loaded + attached BPF state. Holds `Object` (programs + maps)
    /// + the `Link` handles that keep the programs attached —
    /// dropping the Links detaches.
    ///
    /// `Mutex<Object>` is the simpler half of the design options
    /// the original skeleton noted: `libbpf_rs::Object` is `!Sync`,
    /// so a daemon-shared `Arc<EbpfState>` model requires this
    /// serialise point. Lock cost is negligible — the only callers
    /// are atty (writing one PID per Enter) and infrequent
    /// `GetThreatLevel` lookups.
    pub struct EbpfState {
        obj: Mutex<libbpf_rs::Object>,
        _lsm_link: libbpf_rs::Link,
        _tp_execve_link: libbpf_rs::Link,
        /// AF_ALG socket() tracepoint — copy.fail-class kernel-LPE
        /// signal. Loaded as part of the same .o so the user pays
        /// for one BPF object load even if they only care about
        /// the execve enforcement path.
        _tp_socket_link: libbpf_rs::Link,
        mode: LoadedMode,
    }

    // SAFETY: `libbpf_rs::Object` and `libbpf_rs::Link` wrap raw
    // `NonNull<bpf_object>` / `NonNull<bpf_link>` and aren't
    // auto-Send/Sync. We serialize all access to the inner
    // pointers through `Mutex<Object>`, and libbpf's own map
    // operations (BPF_MAP_LOOKUP_ELEM / BPF_MAP_UPDATE_ELEM) are
    // thread-safe by the kernel's own contract. Link is only
    // touched at `EbpfState::Drop`, which runs once when the
    // last Arc handle drops. Sharing the EbpfState across the
    // daemon's per-connection threads via Arc is therefore safe.
    unsafe impl Send for EbpfState {}
    unsafe impl Sync for EbpfState {}

    impl EbpfState {
        pub fn attach(mode: LoadedMode) -> Result<Self, LoadError> {
            let path = locate_bpf_object()?;
            let mut obj_builder = libbpf_rs::ObjectBuilder::default();
            let open_obj = obj_builder
                .open_file(&path)
                .map_err(|e| LoadError::LoadFailed(format!("open {}: {e}", path.display())))?;
            let obj = open_obj
                .load()
                .map_err(|e| LoadError::LoadFailed(format!("load: {e}")))?;

            // Auto-attach uses the SEC() annotations on each program
            // (lsm/bprm_check_security, tracepoint/syscalls/sys_enter_execve)
            // to pick the right hook + attach helper.
            let lsm_link = obj
                .progs_mut()
                .find(|p| p.name() == "check_execve")
                .ok_or_else(|| {
                    LoadError::LoadFailed("program check_execve missing from .o".into())
                })?
                .attach()
                .map_err(|e| LoadError::LoadFailed(format!("attach lsm: {e}")))?;

            let tp_execve_link = obj
                .progs_mut()
                .find(|p| p.name() == "trace_execve")
                .ok_or_else(|| {
                    LoadError::LoadFailed("program trace_execve missing from .o".into())
                })?
                .attach()
                .map_err(|e| LoadError::LoadFailed(format!("attach execve tracepoint: {e}")))?;

            let tp_socket_link = obj
                .progs_mut()
                .find(|p| p.name() == "trace_socket")
                .ok_or_else(|| {
                    LoadError::LoadFailed("program trace_socket missing from .o".into())
                })?
                .attach()
                .map_err(|e| LoadError::LoadFailed(format!("attach socket tracepoint: {e}")))?;

            Ok(Self {
                obj: Mutex::new(obj),
                _lsm_link: lsm_link,
                _tp_execve_link: tp_execve_link,
                _tp_socket_link: tp_socket_link,
                mode,
            })
        }

        pub fn mode(&self) -> LoadedMode {
            self.mode
        }

        /// Look up a PID's threat level. Returns Low for unmapped
        /// keys (matches the kernel-side `if (level && ...)`
        /// check which treats absence-of-mark as Low).
        pub fn get_threat(&self, pid: u32) -> ThreatLevel {
            let guard = self.obj.lock().expect("ebpf obj poisoned");
            let map = match guard.maps().find(|m| m.name() == "threat_map") {
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
                (LoadedMode::Warn, ThreatLevel::Critical) => {
                    self.update("warn_pids", &key, &[1u8])
                }
                (LoadedMode::Block, ThreatLevel::Critical) => {
                    self.update("threat_map", &key, &[2u8])
                }
                (_, ThreatLevel::High) => self.update("threat_map", &key, &[1u8]),
                _ => Ok(()),
            }
        }

        /// Clear the PID from BOTH maps under ONE lock. The naive
        /// "delete from threat_map, then delete from warn_pids"
        /// shape used to take the mutex twice — a concurrent
        /// `get_threat` could observe a half-cleared state (gone
        /// from threat_map, still in warn_pids). Single-lock keeps
        /// the clear atomic from every reader's perspective.
        fn clear_both(&self, key: &[u8]) -> Result<(), LoadError> {
            let guard = self.obj.lock().expect("ebpf obj poisoned");
            for map_name in ["threat_map", "warn_pids"] {
                if let Some(map) = guard.maps().find(|m| m.name() == map_name) {
                    let _ = map.delete(key);
                }
            }
            Ok(())
        }

        fn update(&self, map_name: &str, key: &[u8], value: &[u8]) -> Result<(), LoadError> {
            let guard = self.obj.lock().expect("ebpf obj poisoned");
            let map = guard
                .maps()
                .find(|m| m.name() == map_name)
                .ok_or_else(|| {
                    LoadError::LoadFailed(format!("{map_name} missing from loaded object"))
                })?;
            map.update(key, value, MapFlags::ANY)
                .map_err(|e| LoadError::LoadFailed(format!("{map_name} update: {e}")))
        }

        fn delete(&self, map_name: &str, key: &[u8]) -> Result<(), LoadError> {
            let guard = self.obj.lock().expect("ebpf obj poisoned");
            let map = guard
                .maps()
                .find(|m| m.name() == map_name)
                .ok_or_else(|| {
                    LoadError::LoadFailed(format!("{map_name} missing from loaded object"))
                })?;
            map.delete(key)
                .map_err(|e| LoadError::LoadFailed(format!("{map_name} delete: {e}")))
        }
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
        match EbpfState::attach(LoadedMode::Block) {
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
