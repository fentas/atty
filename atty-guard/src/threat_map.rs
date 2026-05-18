//! In-memory PID → threat-level map.
//!
//! V2-A scope: this is a plain HashMap behind a Mutex. V2-B will
//! replace the storage with a libbpf-rs BPF_MAP_TYPE_HASH backing
//! the same API surface, so the kernel-side LSM hook reads the
//! same record atty wrote over UDS.
//!
//! Keeping the surface area minimal here: `set`, `get`. Iteration
//! and TTL-based eviction are deferred — atty needs the per-PID
//! decision at execve time; everything else is operational tooling.

use crate::protocol::ThreatLevel;
use std::collections::HashMap;
use std::sync::Mutex;

pub struct ThreatMap {
    inner: Mutex<HashMap<u32, ThreatLevel>>,
}

impl ThreatMap {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
        }
    }

    pub fn set(&self, pid: u32, level: ThreatLevel) {
        let mut g = self.inner.lock().expect("threat_map poisoned");
        if matches!(level, ThreatLevel::Low) {
            g.remove(&pid);
        } else {
            g.insert(pid, level);
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
}
