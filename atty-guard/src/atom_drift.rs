//! V2-I drift detection (#209) for the atom-fetcher's pinned mode.
//!
//! After each cron tick the daemon probes each source's
//! `refs/heads/master` head SHA via the GitHub commits API and
//! compares to the pinned commit. The resulting `DriftSnapshot` is
//! written to `/var/lib/atty-guard/atoms.drift.json` and surfaced
//! over the UDS (`AtomsDrift` RPC), the `atty-guard atoms drift`
//! CLI subcommand, and `atty doctor` (Zig side, future PR).
//!
//! Read-only telemetry: drift never affects fetch behavior. The
//! sha256 verification in `atom_fetcher::fetch_all` is the
//! security gate; drift detection is the UX layer that tells
//! operators when their pin is N commits behind upstream so they
//! can decide whether to bump.
//!
//! Failure posture: best-effort throughout. A network blip during
//! the head-SHA probe leaves the previous snapshot unchanged
//! (the file isn't rewritten, the `atty-guard atoms drift`
//! reader just sees stale data + a `updated_at` timestamp the
//! operator can spot). A snapshot-write failure logs to journald
//! and continues; classifier behavior is unaffected.

use std::path::Path;
#[cfg(feature = "atoms-fetch")]
use std::time::Duration;

#[cfg(feature = "atoms-fetch")]
use crate::atom_fetcher::{AtomPins, SourceId};

/// `<owner>/<repo>` slug for each source. Source of truth for both
/// the head-SHA probe URL and the operator-facing source label.
#[cfg(feature = "atoms-fetch")]
pub fn source_repo(id: SourceId) -> &'static str {
    match id {
        SourceId::Gtfobins => "GTFOBins/GTFOBins.github.io",
        SourceId::Sigma => "SigmaHQ/sigma",
    }
}

/// One source's snapshot. `pinned` is the operator's configured
/// commit (or `None` for live tracking). `upstream` is the latest
/// `refs/heads/master` head SHA from the probe (or `None` if the
/// probe failed this tick). `behind_since` is the first tick we
/// observed drift (i.e. `pinned != upstream`); cleared when the
/// operator bumps the pin to match.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DriftSource {
    pub name: String,
    pub pinned: Option<String>,
    pub upstream: Option<String>,
    /// RFC 3339 timestamp of the first tick this source was
    /// observed behind its pin. `None` when in-sync or when
    /// live-tracking.
    pub behind_since: Option<String>,
}

impl DriftSource {
    /// Is this source out-of-sync with upstream? Returns false for
    /// live-tracking (no pin) and for missing-upstream (probe
    /// failure — the operator can't act on it yet).
    #[cfg(any(feature = "atoms-fetch", test))]
    pub fn is_behind(&self) -> bool {
        match (&self.pinned, &self.upstream) {
            (Some(p), Some(u)) => p != u,
            _ => false,
        }
    }
}

/// Top-level snapshot. `updated_at` is set on every successful
/// write — the operator can spot a stale snapshot by comparing
/// against expected cron cadence.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DriftSnapshot {
    pub updated_at: String,
    pub sources: Vec<DriftSource>,
}

impl DriftSnapshot {
    #[cfg(any(feature = "atoms-fetch", test))]
    pub fn any_behind(&self) -> bool {
        self.sources.iter().any(DriftSource::is_behind)
    }
}

/// Where the daemon writes the drift JSON. Daemon-owned
/// (atty:atty 0640) so the CLI's no-sudo read path works for any
/// user in the atty group, but a non-privileged process can't
/// forge it.
pub const DEFAULT_DRIFT_FILE: &str = "/var/lib/atty-guard/atoms.drift.json";

/// Endpoint for the head-SHA probe. Hardcoded to api.github.com;
/// no air-gap support today (the cron fetcher already requires
/// network). The unauthenticated rate limit (60 req/h per IP) is
/// far above the realistic tick cadence (default 6h → 4 req/d).
#[cfg(feature = "atoms-fetch")]
fn head_sha_url(repo: &str) -> String {
    format!("https://api.github.com/repos/{repo}/commits/master?per_page=1")
}

/// Probe one source for its current `refs/heads/master` head SHA.
/// Used by `compute_snapshot`. Best-effort — returns `None` on
/// any network / parse failure so the snapshot still records the
/// known-pinned commit even when the probe is down.
#[cfg(feature = "atoms-fetch")]
pub fn probe_head_sha(repo: &str, user_agent: &str, timeout: Duration) -> Option<String> {
    let agent = ureq::AgentBuilder::new()
        .timeout(timeout)
        .user_agent(user_agent)
        .build();
    let url = head_sha_url(repo);
    let resp = agent.get(&url).set("Accept", "application/vnd.github+json").call().ok()?;
    // The /repos/<owner>/<repo>/commits/master endpoint returns a
    // SINGLE commit object (HEAD) — NOT an array. `per_page=1` is
    // belt-and-braces for older API behavior but the field shape is
    // `{"sha": "...", ...}` either way.
    #[derive(serde::Deserialize)]
    struct CommitResponse {
        sha: String,
    }
    let body = resp.into_string().ok()?;
    let commit: CommitResponse = serde_json::from_str(&body).ok()?;
    Some(commit.sha)
}

/// Build a snapshot for the given source list. Probes each
/// source's head SHA, compares to the operator's pin (when
/// present), preserves `behind_since` from `prev` so a multi-day
/// drift window stays anchored to its first observation.
#[cfg(feature = "atoms-fetch")]
pub fn compute_snapshot(
    pins: Option<&AtomPins>,
    sources: &[SourceId],
    user_agent: &str,
    timeout: Duration,
    prev: Option<&DriftSnapshot>,
) -> DriftSnapshot {
    let now = current_rfc3339();
    let mut entries = Vec::with_capacity(sources.len());
    for &sid in sources {
        let name = source_name(sid).to_owned();
        let pinned = pin_for(pins, sid);
        let upstream = probe_head_sha(source_repo(sid), user_agent, timeout);
        // Preserve behind_since across ticks when still drifted;
        // clear when in-sync or when no pin (live tracking has no
        // "behind" notion).
        let behind_since = if let (Some(p), Some(u)) = (&pinned, &upstream) {
            if p != u {
                prev.and_then(|s| s.sources.iter().find(|e| e.name == name))
                    .and_then(|e| e.behind_since.clone())
                    .or_else(|| Some(now.clone()))
            } else {
                None
            }
        } else {
            None
        };
        entries.push(DriftSource {
            name,
            pinned,
            upstream,
            behind_since,
        });
    }
    DriftSnapshot {
        updated_at: now,
        sources: entries,
    }
}

#[cfg(feature = "atoms-fetch")]
fn source_name(id: SourceId) -> &'static str {
    match id {
        SourceId::Gtfobins => "gtfobins",
        SourceId::Sigma => "sigma",
    }
}

#[cfg(feature = "atoms-fetch")]
fn pin_for(pins: Option<&AtomPins>, id: SourceId) -> Option<String> {
    let p = pins?;
    match id {
        SourceId::Gtfobins => p.gtfobins.as_ref().map(|e| e.commit.clone()),
        SourceId::Sigma => p.sigma.as_ref().map(|e| e.commit.clone()),
    }
}

/// Best-effort current-time RFC 3339 stamp via std::time. Avoids
/// pulling chrono just for one timestamp.
#[cfg(feature = "atoms-fetch")]
fn current_rfc3339() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    // Crude UTC formatting from a unix timestamp — good enough for
    // operator readouts. Doesn't need DST / TZ correctness.
    let (year, month, day, hour, minute, second) = unix_to_utc_parts(now);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

#[cfg(any(feature = "atoms-fetch", test))]
fn unix_to_utc_parts(ts: i64) -> (i64, u32, u32, u32, u32, u32) {
    let days = ts.div_euclid(86_400);
    let secs_of_day = ts.rem_euclid(86_400) as u32;
    let hour = secs_of_day / 3600;
    let minute = (secs_of_day % 3600) / 60;
    let second = secs_of_day % 60;
    // 1970-01-01 epoch → Y/M/D via civil-day algorithm (Howard
    // Hinnant's date.h "civil_from_days"; integer-only, branch-free
    // enough that we don't need a date crate).
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = y + if m <= 2 { 1 } else { 0 };
    (year, m as u32, d as u32, hour, minute, second)
}

/// Write the snapshot to `path` atomically (tmp + rename). 0640
/// perms when run as the daemon user (matches the rest of
/// /var/lib/atty-guard/'s posture).
#[cfg(any(feature = "atoms-fetch", test))]
pub fn write_snapshot(path: &Path, snapshot: &DriftSnapshot) -> std::io::Result<()> {
    use std::io::Write;
    if let Some(parent) = path.parent() {
        if !parent.exists() {
            // Best-effort dir create. The install path expects the
            // directory to exist (systemd unit's ReadWritePaths
            // creates it); this catches dev / test envs that don't.
            let _ = std::fs::create_dir_all(parent);
        }
    }
    let tmp = path.with_extension("json.tmp");
    {
        let mut f = std::fs::File::create(&tmp)?;
        let bytes = serde_json::to_vec_pretty(snapshot).map_err(std::io::Error::other)?;
        f.write_all(&bytes)?;
        // Match the rest of /var/lib/atty-guard's 0640 posture so
        // any user in the atty group can read but only the daemon
        // can write.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o640));
        }
    }
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// Read the snapshot. Returns `Ok(None)` when the file doesn't
/// exist yet (cron hasn't run yet; common on first install).
pub fn read_snapshot(path: &Path) -> std::io::Result<Option<DriftSnapshot>> {
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    let snapshot: DriftSnapshot = serde_json::from_slice(&bytes).map_err(std::io::Error::other)?;
    Ok(Some(snapshot))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drift_source_is_behind_only_when_pinned_and_diff() {
        let live = DriftSource {
            name: "x".into(),
            pinned: None,
            upstream: Some("abc".into()),
            behind_since: None,
        };
        assert!(!live.is_behind(), "live-tracking is never 'behind'");

        let probe_failed = DriftSource {
            name: "x".into(),
            pinned: Some("abc".into()),
            upstream: None,
            behind_since: None,
        };
        assert!(!probe_failed.is_behind(), "no upstream → can't decide");

        let in_sync = DriftSource {
            name: "x".into(),
            pinned: Some("abc".into()),
            upstream: Some("abc".into()),
            behind_since: None,
        };
        assert!(!in_sync.is_behind());

        let drifted = DriftSource {
            name: "x".into(),
            pinned: Some("aaa".into()),
            upstream: Some("bbb".into()),
            behind_since: Some("2026-01-01T00:00:00Z".into()),
        };
        assert!(drifted.is_behind());
    }

    #[test]
    fn snapshot_round_trips_through_json() {
        let snap = DriftSnapshot {
            updated_at: "2026-05-26T08:00:00Z".into(),
            sources: vec![DriftSource {
                name: "gtfobins".into(),
                pinned: Some("aaa".into()),
                upstream: Some("bbb".into()),
                behind_since: Some("2026-05-20T14:00:00Z".into()),
            }],
        };
        let s = serde_json::to_string(&snap).unwrap();
        let back: DriftSnapshot = serde_json::from_str(&s).unwrap();
        assert_eq!(back.sources.len(), 1);
        assert_eq!(back.sources[0].name, "gtfobins");
        assert!(back.any_behind());
    }

    #[test]
    fn write_then_read_round_trip() {
        let dir = std::env::temp_dir().join(format!(
            "atty-guard-drift-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("atoms.drift.json");
        let snap = DriftSnapshot {
            updated_at: "2026-05-26T08:00:00Z".into(),
            sources: vec![DriftSource {
                name: "sigma".into(),
                pinned: None,
                upstream: Some("xyz".into()),
                behind_since: None,
            }],
        };
        write_snapshot(&path, &snap).unwrap();
        let back = read_snapshot(&path).unwrap().unwrap();
        assert_eq!(back.sources[0].upstream.as_deref(), Some("xyz"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn read_snapshot_missing_returns_none() {
        let path = std::path::Path::new("/tmp/atty-guard-drift-nonexistent-test.json");
        let _ = std::fs::remove_file(path);
        let r = read_snapshot(path).unwrap();
        assert!(r.is_none());
    }

    #[test]
    fn unix_to_utc_parts_known_dates() {
        // 2024-01-01 00:00:00 UTC = 1704067200
        let (y, m, d, h, mi, s) = unix_to_utc_parts(1_704_067_200);
        assert_eq!((y, m, d, h, mi, s), (2024, 1, 1, 0, 0, 0));
        // 2026-05-26 08:00:00 UTC = 1779782400
        let (y, m, d, h, mi, s) = unix_to_utc_parts(1_779_782_400);
        assert_eq!((y, m, d, h, mi, s), (2026, 5, 26, 8, 0, 0));
        // Leap-day check: 2024-02-29 12:00:00 UTC = 1709208000
        let (y, m, d, h, _mi, _s) = unix_to_utc_parts(1_709_208_000);
        assert_eq!((y, m, d, h), (2024, 2, 29, 12));
        // Pre-epoch check: 1969-12-31 23:59:59 UTC = -1
        let (y, m, d, h, mi, s) = unix_to_utc_parts(-1);
        assert_eq!((y, m, d, h, mi, s), (1969, 12, 31, 23, 59, 59));
    }
}
