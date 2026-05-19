//! PID → threat-level map.
//!
//! Dual-backed: an in-memory `HashMap` always holds the current
//! state (cheap reads for the daemon's own RPCs), and when V2-B
//! eBPF is attached the same writes also propagate to the BPF
//! `BPF_MAP_TYPE_HASH` so the kernel-side LSM hook reads the same
//! record atty wrote over UDS.
//!
//! When eBPF isn't attached, the BPF-side writes are no-ops and
//! the in-mem map is the only source of truth — V2-A behaviour.
//!
//! Keeping the surface area minimal here: `set`, `get`. Iteration
//! and TTL-based eviction are deferred — atty needs the per-PID
//! decision at execve time; everything else is operational
//! tooling.

use crate::ebpf::EbpfState;
use crate::protocol::ThreatLevel;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

pub struct ThreatMap {
    inner: Mutex<HashMap<u32, ThreatLevel>>,
    /// V2-B kernel-side backing. When attached, every `set` writes
    /// through to the BPF hash map so the LSM hook can read it
    /// from the kernel. When `None`, V2-A in-mem-only semantics.
    ebpf: Option<Arc<EbpfState>>,
}

impl ThreatMap {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
            ebpf: None,
        }
    }

    /// Wire the V2-B BPF state into this map. Subsequent `set`
    /// calls will write through to the kernel-side hash map AS
    /// WELL AS the in-mem map. Idempotent in spirit — calling
    /// twice replaces the previous handle (drop detaches).
    pub fn with_ebpf(mut self, state: Arc<EbpfState>) -> Self {
        self.ebpf = Some(state);
        self
    }

    pub fn set(&self, pid: u32, level: ThreatLevel) {
        {
            let mut g = self.inner.lock().expect("threat_map poisoned");
            if matches!(level, ThreatLevel::Low) {
                g.remove(&pid);
            } else {
                g.insert(pid, level);
            }
        }
        // Best-effort write-through. A failed BPF map update doesn't
        // invalidate the in-mem state — the daemon's view stays
        // consistent and we surface "no kernel enforcement" rather
        // than failing the whole RPC. eprintln stays cheap: this
        // path fires only on user-confirmed risky commands, not
        // on every classify.
        if let Some(state) = &self.ebpf {
            if let Err(e) = state.set_threat(pid, level) {
                eprintln!("atty-guard: BPF map update failed (pid {pid}): {e}");
            }
        }
    }

    pub fn get(&self, pid: u32) -> ThreatLevel {
        let g = self.inner.lock().expect("threat_map poisoned");
        g.get(&pid).copied().unwrap_or(ThreatLevel::Low)
    }
}

impl Default for ThreatMap {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_low() {
        let m = ThreatMap::new();
        assert_eq!(m.get(123), ThreatLevel::Low);
    }

    #[test]
    fn set_then_get() {
        let m = ThreatMap::new();
        m.set(42, ThreatLevel::High);
        assert_eq!(m.get(42), ThreatLevel::High);
    }

    #[test]
    fn set_low_removes_entry() {
        let m = ThreatMap::new();
        m.set(42, ThreatLevel::Critical);
        m.set(42, ThreatLevel::Low);
        assert_eq!(m.get(42), ThreatLevel::Low);
    }

    // The ebpf-on branch needs CAP_BPF + a real kernel attach —
    // exercised manually + via the daemon's integration harness
    // when V2-B is enabled. Default-build branch is `None`, fully
    // covered by the tests above.
}
