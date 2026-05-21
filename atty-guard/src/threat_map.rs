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

/// Stored entry: level + starttime jiffies for PID-reuse detection.
/// The kernel only reuses PID numbers, not (pid, starttime) pairs
/// within a single boot — so storing the starttime lets `get` reject
/// stale entries that now refer to a different process. Without
/// this, a Critical mark on a short-lived PID could persist and
/// later affect an unrelated (possibly cross-user) process that
/// got the same PID number.
#[derive(Debug, Clone, Copy)]
struct Entry {
    level: ThreatLevel,
    starttime: u64,
}

pub struct ThreatMap {
    inner: Mutex<HashMap<u32, Entry>>,
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

    /// Record a threat level for `pid`. For non-Low levels, reads
    /// the PID's starttime from `/proc/<pid>/stat` so a later `get`
    /// can detect PID reuse and evict the stale entry. Returns
    /// `false` only when the PID is gone before the starttime read
    /// for a non-Low level — in that case no entry is stored and
    /// the BPF map isn't touched. `Low` is a pure eviction and
    /// always succeeds: callers must be able to clear an entry
    /// even after the process has exited, otherwise stale entries
    /// could leak in the BPF map.
    pub fn set(&self, pid: u32, level: ThreatLevel) -> bool {
        if matches!(level, ThreatLevel::Low) {
            self.evict(pid);
            return true;
        }
        let starttime = match pid_starttime(pid) {
            Some(t) => t,
            None => return false,
        };
        {
            let mut g = self.inner.lock().expect("threat_map poisoned");
            g.insert(pid, Entry { level, starttime });
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
        true
    }

    /// Look up the threat level for `pid`. When a non-Low entry
    /// exists, verify the PID still has the same starttime — if
    /// the PID was recycled (or exited), evict the stale entry
    /// AND clear it from the BPF map so the kernel hook stops
    /// blocking the new (potentially cross-user) occupant. Common
    /// path (no entry / Low entry) reads only the in-mem map.
    pub fn get(&self, pid: u32) -> ThreatLevel {
        let stored = {
            let g = self.inner.lock().expect("threat_map poisoned");
            g.get(&pid).copied()
        };
        let stored = match stored {
            Some(e) => e,
            None => return ThreatLevel::Low,
        };
        match pid_starttime(pid) {
            Some(now) if now == stored.starttime => stored.level,
            _ => {
                // Conditional eviction: only remove if the entry
                // we read is STILL the entry on file. Without this,
                // a concurrent `set(pid, High)` for a reused PID
                // could be wiped by an in-flight `get()` that
                // started on the stale view — the new legitimate
                // mark would silently disappear.
                self.evict_if_stale(pid, stored.starttime);
                ThreatLevel::Low
            }
        }
    }

    /// Unconditional eviction — pure `Low` set path, where the
    /// caller's contract is "clear whatever's there, regardless
    /// of identity".
    fn evict(&self, pid: u32) {
        let removed = {
            let mut g = self.inner.lock().expect("threat_map poisoned");
            g.remove(&pid).is_some()
        };
        if removed {
            if let Some(state) = &self.ebpf {
                if let Err(e) = state.set_threat(pid, ThreatLevel::Low) {
                    eprintln!("atty-guard: BPF map evict failed (pid {pid}): {e}");
                }
            }
        }
    }

    /// Conditional eviction — used by `get()`'s PID-reuse defense.
    /// Only removes the entry if its starttime still matches the
    /// value the caller observed; if a concurrent `set` already
    /// installed a fresh entry (different starttime), we leave
    /// it alone so the new mark survives the race.
    ///
    /// BPF clear failure here is the worst-case path: in-mem map
    /// is consistent (entry gone) but the kernel LSM still sees
    /// the stale High/Critical and will EPERM the new process's
    /// execves — and after PID reuse that new process may belong
    /// to a different UID. We log loudly to stderr so the operator
    /// sees the divergence; no userspace retry path exists for the
    /// BPF map today. TODO(observability): wire a metric / persist
    /// the pending eviction so a later classify can re-attempt.
    fn evict_if_stale(&self, pid: u32, expected_starttime: u64) {
        let removed = {
            let mut g = self.inner.lock().expect("threat_map poisoned");
            match g.get(&pid) {
                Some(e) if e.starttime == expected_starttime => g.remove(&pid).is_some(),
                _ => false,
            }
        };
        if removed {
            if let Some(state) = &self.ebpf {
                if let Err(e) = state.set_threat(pid, ThreatLevel::Low) {
                    eprintln!(
                        "atty-guard: BPF stale-entry clear FAILED for pid {pid} ({e}) — \
                         kernel LSM may still block this (possibly cross-user-reused) PID until daemon restart"
                    );
                }
            }
        }
    }
}

/// Read field 22 (`starttime`) of `/proc/<pid>/stat`. Returns
/// `None` if the PID is gone or the file is unreadable. The comm
/// field (#2) can contain spaces and parentheses, so we anchor on
/// the LAST `)` and split fields from there — matching the parse
/// rule documented in `proc(5)`.
fn pid_starttime(pid: u32) -> Option<u64> {
    let content = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let last_paren = content.rfind(')')?;
    // Fields after `comm`: state(3) ppid(4) pgrp(5) session(6)
    // tty_nr(7) tpgid(8) flags(9) minflt(10) cminflt(11)
    // majflt(12) cmajflt(13) utime(14) stime(15) cutime(16)
    // cstime(17) priority(18) nice(19) num_threads(20)
    // itrealvalue(21) starttime(22) → index 22 - 3 = 19 in the
    // post-`)` token stream (which starts at field 3).
    let mut fields = content[last_paren + 1..].split_whitespace();
    let starttime = fields.nth(19)?;
    starttime.parse::<u64>().ok()
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
        let pid = std::process::id();
        assert!(m.set(pid, ThreatLevel::High));
        assert_eq!(m.get(pid), ThreatLevel::High);
    }

    #[test]
    fn set_low_removes_entry() {
        let m = ThreatMap::new();
        let pid = std::process::id();
        assert!(m.set(pid, ThreatLevel::Critical));
        assert!(m.set(pid, ThreatLevel::Low));
        assert_eq!(m.get(pid), ThreatLevel::Low);
        // Confirm the eviction actually removed the entry — without
        // this the test could pass when both `set` calls fail and
        // `get` returns the default Low.
        let g = m.inner.lock().unwrap();
        assert!(!g.contains_key(&pid));
    }

    #[test]
    fn set_low_succeeds_for_nonexistent_pid() {
        // Pure-eviction path must work even when the PID is gone —
        // otherwise a daemon restart-then-cleanup couldn't clear
        // stale BPF map entries left by a previous incarnation.
        let m = ThreatMap::new();
        assert!(m.set(0, ThreatLevel::Low));
    }

    #[test]
    fn set_returns_false_for_nonexistent_pid() {
        // PID 0 is the kernel scheduler sentinel — /proc/0 doesn't
        // exist, so starttime read fails and set returns false
        // without mutating state.
        let m = ThreatMap::new();
        assert!(!m.set(0, ThreatLevel::High));
        assert_eq!(m.get(0), ThreatLevel::Low);
    }

    #[test]
    fn get_preserves_fresh_entry_after_concurrent_reset() {
        // Race emulation: `get()` reads a stale entry, decides to
        // evict (starttime mismatch). Between the read and the
        // eviction, another thread `set()`s a fresh entry for the
        // same PID. The fresh entry must survive — without the
        // conditional eviction in evict_if_stale, the get() would
        // wipe the just-installed mark.
        let m = ThreatMap::new();
        let pid = std::process::id();
        // Step 1: simulate a stale entry the test "saw" first.
        let stale_starttime = u64::MAX;
        // Step 2: the racing concurrent `set` lands.
        assert!(m.set(pid, ThreatLevel::High));
        // Step 3: the original `get()` discovers starttime
        // mismatch (because the stale entry it captured had
        // u64::MAX) and calls evict_if_stale with the OLD value.
        m.evict_if_stale(pid, stale_starttime);
        // The fresh entry must still be there.
        assert_eq!(m.get(pid), ThreatLevel::High);
    }

    #[test]
    fn get_evicts_when_starttime_mismatches() {
        // Simulate PID reuse by writing a fake entry with a
        // mismatched starttime, then verifying `get` evicts it
        // and returns Low. (Real reuse would require waiting for
        // a kernel PID wrap, which is impractical in a unit test.)
        let m = ThreatMap::new();
        let pid = std::process::id();
        // Seed the map directly so we control starttime.
        {
            let mut g = m.inner.lock().unwrap();
            g.insert(
                pid,
                Entry {
                    level: ThreatLevel::Critical,
                    starttime: u64::MAX, // can't match a real starttime
                },
            );
        }
        assert_eq!(m.get(pid), ThreatLevel::Low);
        // Confirm eviction landed.
        let g = m.inner.lock().unwrap();
        assert!(!g.contains_key(&pid));
    }

    // The ebpf-on branch needs CAP_BPF + a real kernel attach —
    // exercised manually + via the daemon's integration harness
    // when V2-B is enabled. Default-build branch is `None`, fully
    // covered by the tests above.
}
