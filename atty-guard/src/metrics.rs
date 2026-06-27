//! Dashboard metrics store (P1) — per-UID, per-pid instance records the
//! `metrics_exporter` module reports and the `attop` dashboard queries.
//!
//! Ephemeral (in-memory) by default; persistent retention is a later,
//! config-gated layer (see docs/dashboard.md). Stale instances (a process
//! whose atty exited) are pruned by a last-seen TTL: every report sweeps
//! ALL UIDs — dropping stale records AND emptied UID buckets — so a
//! session that goes silent can't pin memory on the shared daemon, and a
//! per-UID instance cap bounds a same-UID spammer within the TTL window.
//!
//! Privacy boundary: this store keeps what the exporter sends verbatim.
//! Incognito redaction is the EXPORTER's job (it applies the user's
//! configurable incognito-reporting policy — report nothing / existence +
//! security counters / normal); the daemon can't re-derive that policy, so
//! it trusts the reported fields. See docs/dashboard.md "Privacy".

use crate::protocol::{InstanceInfo, MetricsCounters};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Drop an instance the dashboard's way if it hasn't reported within this
/// window — the exporter flushes on the proxy's tick (seconds), so a
/// minute of silence means the session is gone.
const STALE_MS: u64 = 60_000;

/// Cap instances per UID — a real user has a handful of terminals; this
/// bounds a same-UID / atty-group process spamming distinct pids at the
/// shared daemon (the TTL only reclaims after its window).
const MAX_INSTANCES_PER_UID: usize = 1024;

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
        // Sweep EVERY UID (not just the reporting one) + drop emptied
        // buckets, so a session that went silent can't pin memory on the
        // shared daemon — any report reclaims all stale state.
        g.retain(|_, per| {
            per.retain(|_, r| now.saturating_sub(r.last_seen_ms) < STALE_MS);
            !per.is_empty()
        });
        let per = g.entry(uid).or_default();
        // Cap a spammer: a NEW pid beyond the per-UID cap is dropped;
        // existing pids still update (so a real fleet keeps refreshing).
        if per.len() >= MAX_INSTANCES_PER_UID && !per.contains_key(&pid) {
            return;
        }
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
        // Non-root indexes straight to its own bucket; root scans all.
        let buckets: Vec<(u32, &HashMap<u32, Record>)> = if all {
            g.iter().map(|(&u, per)| (u, per)).collect()
        } else {
            g.get(&uid).map(|per| (uid, per)).into_iter().collect()
        };
        for (u, per) in buckets {
            for (&pid, r) in per {
                if now.saturating_sub(r.last_seen_ms) >= STALE_MS {
                    continue;
                }
                out.push(InstanceInfo {
                    uid: u,
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
        let buckets: Vec<&HashMap<u32, Record>> = if all {
            g.values().collect()
        } else {
            g.get(&uid).into_iter().collect()
        };
        for per in buckets {
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
    fn per_uid_cap_drops_new_pids() {
        let s = MetricsStore::new();
        for pid in 0..(MAX_INSTANCES_PER_UID as u32 + 50) {
            s.report(1000, pid, "/x".into(), "bash".into(), false, counters(1, 0));
        }
        // New pids beyond the cap are dropped, not grown unbounded.
        assert_eq!(s.aggregate(1000, false).1, MAX_INSTANCES_PER_UID);
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
