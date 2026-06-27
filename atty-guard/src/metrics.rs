//! Dashboard metrics store (P1) — per-UID, per-pid instance records the
//! `metrics_exporter` module reports and the `attop` dashboard queries.
//!
//! Ephemeral (in-memory) by default; persistent retention is a later,
//! config-gated layer (see docs/dashboard.md). Stale instances (a process
//! that stopped reporting because its atty exited) are pruned by a
//! last-seen TTL so the map can't grow without bound.

use crate::protocol::{InstanceInfo, MetricsCounters};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Drop an instance the dashboard's way if it hasn't reported within this
/// window — the exporter flushes on the proxy's tick (seconds), so a
/// minute of silence means the session is gone.
const STALE_MS: u64 = 60_000;

struct Record {
    cwd: String,
    shell: String,
    incognito: bool,
    last_seen_ms: u64, // daemon wall-clock receipt time
    counters: MetricsCounters,
}

/// In-memory metrics store. Keyed UID → pid → record; the UID is the
/// SO_PEERCRED owner of the reporting socket, so an instance can only
/// write under its own UID.
#[derive(Default)]
pub struct MetricsStore {
    inner: Mutex<HashMap<u32, HashMap<u32, Record>>>,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl MetricsStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Upsert an instance's report under its owning UID. `last_seen` is
    /// stamped with the daemon's clock (not the instance's `ts_ms`) so
    /// staleness is immune to client clock skew. Prunes the UID's stale
    /// entries while the lock is held.
    pub fn report(
        &self,
        uid: u32,
        pid: u32,
        cwd: String,
        shell: String,
        incognito: bool,
        counters: MetricsCounters,
    ) {
        let now = now_ms();
        let mut g = self.inner.lock().expect("metrics store poisoned");
        let per = g.entry(uid).or_default();
        per.retain(|_, r| now.saturating_sub(r.last_seen_ms) < STALE_MS);
        per.insert(
            pid,
            Record {
                cwd,
                shell,
                incognito,
                last_seen_ms: now,
                counters,
            },
        );
    }

    /// Live instances for `uid` (or all UIDs when `all`, for root).
    pub fn instances(&self, uid: u32, all: bool) -> Vec<InstanceInfo> {
        let now = now_ms();
        let g = self.inner.lock().expect("metrics store poisoned");
        let mut out = Vec::new();
        for (&u, per) in g.iter() {
            if !all && u != uid {
                continue;
            }
            for (&pid, r) in per.iter() {
                if now.saturating_sub(r.last_seen_ms) >= STALE_MS {
                    continue;
                }
                out.push(InstanceInfo {
                    pid,
                    cwd: r.cwd.clone(),
                    shell: r.shell.clone(),
                    incognito: r.incognito,
                    last_seen_ms: r.last_seen_ms,
                    counters: r.counters.clone(),
                });
            }
        }
        out
    }

    /// Field-wise aggregate + live instance count for `uid` (or all).
    pub fn aggregate(&self, uid: u32, all: bool) -> (MetricsCounters, usize) {
        let now = now_ms();
        let g = self.inner.lock().expect("metrics store poisoned");
        let mut agg = MetricsCounters::default();
        let mut n = 0usize;
        for (&u, per) in g.iter() {
            if !all && u != uid {
                continue;
            }
            for r in per.values() {
                if now.saturating_sub(r.last_seen_ms) >= STALE_MS {
                    continue;
                }
                agg.add(&r.counters);
                n += 1;
            }
        }
        (agg, n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn counters(commands: u64, blocks: u64) -> MetricsCounters {
        MetricsCounters {
            commands,
            guard_block: blocks,
            ..Default::default()
        }
    }

    #[test]
    fn report_then_query_roundtrips_per_uid() {
        let s = MetricsStore::new();
        s.report(1000, 10, "/a".into(), "bash".into(), false, counters(5, 1));
        s.report(1000, 11, "/b".into(), "zsh".into(), false, counters(3, 0));
        s.report(2000, 20, "/c".into(), "fish".into(), false, counters(9, 2));

        // uid 1000 sees only its two instances.
        let mine = s.instances(1000, false);
        assert_eq!(mine.len(), 2);
        let (agg, n) = s.aggregate(1000, false);
        assert_eq!(n, 2);
        assert_eq!(agg.commands, 8);
        assert_eq!(agg.guard_block, 1);

        // root (all) sees all three.
        let (agg_all, n_all) = s.aggregate(0, true);
        assert_eq!(n_all, 3);
        assert_eq!(agg_all.commands, 17);
        assert_eq!(agg_all.guard_block, 3);
    }

    #[test]
    fn report_upserts_same_pid() {
        let s = MetricsStore::new();
        s.report(1000, 10, "/a".into(), "bash".into(), false, counters(5, 0));
        s.report(1000, 10, "/a".into(), "bash".into(), false, counters(12, 1));
        let (agg, n) = s.aggregate(1000, false);
        assert_eq!(n, 1);
        assert_eq!(agg.commands, 12); // latest snapshot, not summed
    }

    #[test]
    fn cross_uid_isolation() {
        let s = MetricsStore::new();
        s.report(2000, 20, "/c".into(), "fish".into(), false, counters(9, 0));
        // uid 1000 (non-root) sees nothing of uid 2000.
        assert!(s.instances(1000, false).is_empty());
        assert_eq!(s.aggregate(1000, false).1, 0);
    }
}
