//! V2-B userspace loader for the eBPF programs in `atty-guard/ebpf/`.
//!
//! **This PR ships the skeleton only.** The body is `unimplemented!()`
//! behind the `ebpf` Cargo feature; the type surface is what V2-B's
//! follow-up implements against. Reasoning: the loader's contract
//! lives at the protocol boundary (UDS → daemon → BPF map), and we
//! want the rest of the daemon to be able to import + reference
//! this module today even without a working build of `libbpf-rs`.
//!
//! Build: `cargo build --features ebpf` (needs `libbpf-dev` + the
//! generated `vmlinux.h`; see `ebpf/README.md`).

#[cfg(feature = "ebpf")]
use crate::protocol::ThreatLevel;

/// Errors the loader can return. Kept narrow so the daemon's
/// startup path can degrade gracefully — any of these makes atty-guard
/// fall back to V2-A behaviour (in-memory threat map, no kernel
/// enforcement) and surface a warning to the user.
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

/// Loaded BPF state — once `attach()` returns, the LSM hook + the
/// execve tracepoint are wired and the maps are live.
pub struct EbpfState {
    #[cfg(feature = "ebpf")]
    _placeholder: std::marker::PhantomData<()>,
}

impl EbpfState {
    /// Load `atty_guard.bpf.o` from the conventional locations,
    /// then attach LSM + tracepoint programs. Caller owns the
    /// returned state — dropping it detaches.
    pub fn attach() -> Result<Self, LoadError> {
        #[cfg(not(feature = "ebpf"))]
        return Err(LoadError::FeatureNotBuilt);

        #[cfg(feature = "ebpf")]
        {
            // V2-B will:
            //   - libbpf_rs::ObjectBuilder::default()
            //         .open_file(find_bpf_object()?)
            //         .map_err(...)?;
            //   - obj.load() → returns programs + maps.
            //   - bpf_set_link_xattr to lsm/bprm_check_security.
            //   - bpf_set_link_xattr to tracepoint syscalls:sys_enter_execve.
            //   - spawn a thread reading the ringbuf into the
            //     classifier's async queue.
            unimplemented!("V2-B follow-up — see atty-guard/ebpf/README.md")
        }
    }

    /// Look up a PID's current threat level from the kernel-side
    /// hash map. When `ebpf` feature is off this returns Low —
    /// caller (atty's classify path) treats it identically to "PID
    /// not in the map".
    #[cfg(feature = "ebpf")]
    pub fn get_threat(&self, _pid: u32) -> ThreatLevel {
        unimplemented!("V2-B follow-up")
    }

    /// Write a PID's threat level into the kernel-side map. Atty's
    /// PTY proxy fires this when it decides a typed command warrants
    /// child-process gating.
    #[cfg(feature = "ebpf")]
    pub fn set_threat(&self, _pid: u32, _level: ThreatLevel) {
        unimplemented!("V2-B follow-up")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attach_without_feature_returns_feature_not_built() {
        // The test runs in the default build (no `ebpf` feature),
        // so attach() must report the clean error rather than
        // panicking.
        match EbpfState::attach() {
            Err(LoadError::FeatureNotBuilt) => {}
            Err(other) => panic!("expected FeatureNotBuilt, got {other:?}"),
            Ok(_) => panic!("expected Err on feature-disabled build"),
        }
    }

    #[test]
    fn load_error_display_includes_diagnostic_hint() {
        let e = LoadError::FeatureNotBuilt;
        let s = format!("{e}");
        assert!(s.contains("--features ebpf"));
    }
}
