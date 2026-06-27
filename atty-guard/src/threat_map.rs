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

    /// Record a threat level for `pid`. Convenience wrapper that
    /// reads starttime internally — callers who've already
    /// validated a starttime (e.g. through the SetThreatLevel
    /// auth gate's double-read) should use `set_with_starttime`
    /// instead to avoid a residual TOCTOU window between their
    /// auth check and this internal read.
    ///
    /// For non-Low levels, reads `/proc/<pid>/stat`. Returns
    /// `false` when that read fails for any reason (NotFound or
    /// other I/O). `Low` is pure eviction and always succeeds.
    pub fn set(&self, pid: u32, level: ThreatLevel) -> bool {
        if matches!(level, ThreatLevel::Low) {
            self.evict(pid);
            return true;
        }
        let starttime = match pid_starttime(pid) {
            ProcRead::Found(t) => t,
            ProcRead::NotFound | ProcRead::Error(_) => return false,
        };
        self.set_with_starttime_inner(pid, level, starttime);
        true
    }

    /// Record a threat level using a caller-supplied starttime —
    /// closes the TOCTOU window between an external auth check
    /// and this map's internal /proc read. Caller is responsible
    /// for proving the (pid, starttime) identity is the one they
    /// just authorized. `Low` ignores the starttime and pure-
    /// evicts.
    pub fn set_with_starttime(&self, pid: u32, level: ThreatLevel, starttime: u64) {
        if matches!(level, ThreatLevel::Low) {
            self.evict(pid);
            return;
        }
        self.set_with_starttime_inner(pid, level, starttime);
    }

    fn set_with_starttime_inner(&self, pid: u32, level: ThreatLevel, starttime: u64) {
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
    }

    /// Mark `pid` as watched (security profiles) in the kernel
    /// `watch_pids` map so its execve subtree surfaces classify events.
    /// Best-effort write-through; no-op (returns false) without an
    /// attached eBPF state. Clearing is kernel-side (trace_exit GC).
    pub fn set_watch(&self, pid: u32) -> bool {
        match &self.ebpf {
            Some(state) => match state.set_watch(pid) {
                Ok(()) => true,
                Err(e) => {
                    eprintln!("atty-guard: watch_pids update failed (pid {pid}): {e}");
                    false
                }
            },
            None => false,
        }
    }

    /// Look up the threat level for `pid`. When a non-Low entry
    /// exists, verify the PID still has the same starttime — if
    /// the PID was recycled (NotFound or starttime mismatch),
    /// evict the stale entry AND clear it from the BPF map so the
    /// kernel hook stops blocking the new (potentially cross-user)
    /// occupant. Transient `/proc` read failures (hidepid, I/O)
    /// preserve the stored entry — failing closed (keep
    /// enforcement) is safer than failing open (drop enforcement)
    /// based on uncertain evidence. Common path (no entry) reads
    /// only the in-mem map.
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
            ProcRead::Found(now) if now == stored.starttime => stored.level,
            ProcRead::Found(_) | ProcRead::NotFound => {
                // Definitive identity mismatch (PID reused) or PID
                // gone — evict the stale entry. Conditional remove
                // protects against concurrent `set(pid, fresh)`
                // installing a new entry between our lock-drops.
                self.evict_if_stale(pid, stored.starttime);
                ThreatLevel::Low
            }
            ProcRead::Error(_) => {
                // Uncertain — could be hidepid or a transient
                // read failure. Keep the stored level so we don't
                // silently downgrade enforcement on noise.
                stored.level
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

/// Outcome of reading a `/proc/<pid>/*` file. Lets callers
/// distinguish "the PID is gone" (definitive — we can evict
/// safely / authorize Low) from "we couldn't read it for some
/// other reason" (transient — we should NOT downgrade enforcement
/// based on uncertain evidence).
#[derive(Debug)]
pub(crate) enum ProcRead<T> {
    Found(T),
    NotFound,
    Error(String),
}

/// Read field 22 (`starttime`) of `/proc/<pid>/stat`. Returns:
/// - `Found(t)`: parsed successfully.
/// - `NotFound`: ENOENT — the PID is gone.
/// - `Error(msg)`: any other read/parse failure (hidepid, transient
///   I/O, malformed file). Callers should treat this as "uncertain"
///   and avoid mutating enforcement state from it.
///
/// The comm field (#2) can contain spaces and parentheses, so we
/// anchor on the LAST `)` and split fields from there — matching
/// the parse rule documented in `proc(5)`.
pub(crate) fn pid_starttime(pid: u32) -> ProcRead<u64> {
    let path = format!("/proc/{pid}/stat");
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return ProcRead::NotFound,
        Err(e) => return ProcRead::Error(format!("cannot read {path}: {e}")),
    };
    let last_paren = match content.rfind(')') {
        Some(i) => i,
        None => return ProcRead::Error(format!("{path}: no closing paren after comm")),
    };
    // Fields after `comm`: state(3) ppid(4) pgrp(5) session(6)
    // tty_nr(7) tpgid(8) flags(9) minflt(10) cminflt(11)
    // majflt(12) cmajflt(13) utime(14) stime(15) cutime(16)
    // cstime(17) priority(18) nice(19) num_threads(20)
    // itrealvalue(21) starttime(22) → index 22 - 3 = 19 in the
    // post-`)` token stream (which starts at field 3).
    let mut fields = content[last_paren + 1..].split_whitespace();
    let starttime = match fields.nth(19) {
        Some(s) => s,
        None => return ProcRead::Error(format!("{path}: missing starttime field")),
    };
    match starttime.parse::<u64>() {
        Ok(t) => ProcRead::Found(t),
        Err(e) => ProcRead::Error(format!("{path}: parse starttime: {e}")),
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

    // Note: `ProcRead::Error` arm of `get()` (preserve stored
    // level on transient /proc read failure) is structurally
    // documented in `threat_map.rs:get()` but not unit-testable
    // without injecting a fake /proc reader. The behavior is
    // enforced by the explicit `ProcRead::Error(_) => stored.level`
    // match arm — any refactor changing that branch is a visible
    // code change, not a silent regression.

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
