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
//! Failure posture: best-effort throughout. A network blip
//! during the head-SHA probe renders the affected source's
//! `upstream` as `null` in the new snapshot AND preserves the
//! `behind_since` anchor from the prior snapshot via
//! `diff_step` rule 4 — so a transient outage doesn't reset the
//! operator's "behind since" audit trail. A snapshot-write
//! failure logs to journald and leaves the prior snapshot file
//! in place; classifier behavior is unaffected throughout.

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
///
/// HTTP non-2xx outcomes are logged to stderr separately from
/// network errors so journald can distinguish them. 403/404 vs.
/// "DNS down" matters operationally: a 404 means the repo was
/// renamed (operator action required), 403 means rate-limit
/// (transient), connect-refused means the IP is offline. Without
/// the split, all three render as "(probe failed)" with no
/// breadcrumb.
#[cfg(feature = "atoms-fetch")]
pub fn probe_head_sha(repo: &str, user_agent: &str, timeout: Duration) -> Option<String> {
    let agent = ureq::AgentBuilder::new()
        .timeout(timeout)
        .user_agent(user_agent)
        .build();
    let url = head_sha_url(repo);
    let resp = match agent
        .get(&url)
        .set("Accept", "application/vnd.github+json")
        .call()
    {
        Ok(r) => r,
        Err(ureq::Error::Status(code, _)) => {
            eprintln!("atty-guard: drift probe for {repo}: HTTP {code}");
            return None;
        }
        Err(e) => {
            eprintln!("atty-guard: drift probe for {repo}: {e}");
            return None;
        }
    };
    // The /repos/<owner>/<repo>/commits/master endpoint returns a
    // SINGLE commit object (HEAD) — NOT an array. `per_page=1` is
    // belt-and-braces for older API behavior but the field shape is
    // `{"sha": "...", ...}` either way.
    #[derive(serde::Deserialize)]
    struct CommitResponse {
        sha: String,
    }
    let body = match resp.into_string() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("atty-guard: drift probe for {repo}: body read failed — {e}");
            return None;
        }
    };
    match serde_json::from_str::<CommitResponse>(&body) {
        Ok(c) => Some(c.sha),
        Err(e) => {
            eprintln!("atty-guard: drift probe for {repo}: JSON parse — {e}");
            None
        }
    }
}

/// Pure decision step for the `behind_since` anchor — extracted
/// so tests can pin the four edge cases (fresh drift, sustained
/// drift, recovery, probe-failure-while-drifted) without a real
/// network probe.
///
/// Rules:
/// - `pinned=None` (live tracking): always `None`. There is no
///   "behind" notion for live tracking.
/// - `pinned=Some & upstream=Some & pinned==upstream`: `None`
///   (in-sync; clear any prior anchor — the operator caught up).
/// - `pinned=Some & upstream=Some & pinned!=upstream` (DRIFTED):
///   carry `prev_behind_since` forward when present, else stamp
///   `now`.
/// - `pinned=Some & upstream=None` (probe failed mid-drift): the
///   operator IS still behind (their pin is `pinned`, the world
///   moved on — we just can't confirm against upstream this
///   tick). Carry `prev_behind_since` forward UNCHANGED. Critical:
///   prior shape cleared the anchor in this branch, which made
///   the operator's UI flip to "behind since <today>" every time
///   the network blipped — losing the audit trail of "I've been
///   behind for 3 weeks." See finding #2 on PR #243.
#[cfg(any(feature = "atoms-fetch", test))]
pub fn diff_step(
    prev_behind_since: Option<&str>,
    pinned: Option<&str>,
    upstream: Option<&str>,
    now: &str,
) -> Option<String> {
    match (pinned, upstream) {
        (None, _) => None,
        (Some(p), Some(u)) if p == u => None,
        (Some(_), Some(_)) => {
            // Pinned + drifted: preserve, else stamp.
            Some(prev_behind_since.map(str::to_owned).unwrap_or_else(|| now.to_owned()))
        }
        (Some(_), None) => {
            // Probe failure while pinned: preserve UNCHANGED. Do
            // NOT stamp `now` here — we can't confirm we're behind,
            // only that we can't tell. If we were already known to
            // be behind (prev_behind_since=Some), keep that anchor;
            // if we weren't (prev=None), stay at None.
            prev_behind_since.map(str::to_owned)
        }
    }
}

/// Build a snapshot for the given source list. Probes each
/// source's head SHA, runs `diff_step` per-source to decide the
/// `behind_since` anchor.
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
        let prev_anchor = prev
            .and_then(|s| s.sources.iter().find(|e| e.name == name))
            .and_then(|e| e.behind_since.as_deref());
        let behind_since = diff_step(prev_anchor, pinned.as_deref(), upstream.as_deref(), &now);
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
            // Bubble create errors up: if the parent can't be
            // made, the subsequent File::create gives a less
            // useful "ENOENT on .tmp" error.
            std::fs::create_dir_all(parent)?;
        }
    }
    // PID-suffixed tmp filename to (a) avoid two daemon instances
    // racing on the same tmp slot when both write to the same
    // STATE_DIRECTORY (dev / hand-rolled setups), and (b) raise
    // the bar on a symlink-pre-creation attack against a tmp file
    // with a predictable name. Mirrors trust_store::write_atomic's
    // pattern.
    let pid = std::process::id();
    let tmp_name = match path.file_name().and_then(|n| n.to_str()) {
        Some(n) => format!("{n}.tmp.{pid}"),
        None => format!("atoms.drift.json.tmp.{pid}"),
    };
    let tmp = match path.parent() {
        Some(p) => p.join(tmp_name),
        None => std::path::PathBuf::from(tmp_name),
    };
    {
        // create_new=true refuses to follow an existing symlink at
        // the tmp path. Combined with the PID suffix this closes
        // the symlink-target-chmod race that std::fs::File::create
        // would otherwise leave open.
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)?;
        let bytes = serde_json::to_vec_pretty(snapshot).map_err(std::io::Error::other)?;
        // Remove the (PID-stable, create_new) tmp on any error so a
        // later snapshot in the same process doesn't hit a deterministic
        // EEXIST on the leftover scratch file.
        f.write_all(&bytes).map_err(|e| {
            let _ = std::fs::remove_file(&tmp);
            e
        })?;
        // Match the rest of /var/lib/atty-guard's 0640 posture so
        // any user in the atty group can read but only the daemon
        // can write. A chmod failure is logged but not propagated:
        // the snapshot CONTENT is operator-readable telemetry (no
        // secrets), and on a system where chmod fails the operator
        // already has bigger problems than a slightly-loose drift
        // file. Surfacing the warning means they can tighten by
        // hand or investigate; failing the whole tick would block
        // a chmod hiccup from being seen at all.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Err(e) =
                std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o640))
            {
                eprintln!(
                    "atty-guard: drift snapshot chmod 0640 failed on {} — {e}",
                    tmp.display()
                );
            }
        }
        // fsync the content before the rename so a crash can't publish a
        // truncated snapshot. Clean up the tmp on failure (same EEXIST
        // reasoning as the write above).
        f.sync_all().map_err(|e| {
            let _ = std::fs::remove_file(&tmp);
            e
        })?;
    }
    match std::fs::rename(&tmp, path) {
        Ok(()) => {
            // Make the rename itself durable, not just the bytes.
            crate::fsutil::fsync_parent_dir(path);
            Ok(())
        }
        Err(e) => {
            // Best-effort cleanup so a failed rename doesn't leave
            // a stale .tmp.<pid> sitting around forever.
            let _ = std::fs::remove_file(&tmp);
            Err(e)
        }
    }
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
    fn diff_step_live_tracking_never_anchors() {
        assert_eq!(diff_step(None, None, Some("abc"), "now"), None);
        assert_eq!(
            diff_step(Some("2026-01-01T00:00:00Z"), None, Some("abc"), "now"),
            None,
            "switching from pinned to live clears any anchor"
        );
    }

    #[test]
    fn diff_step_in_sync_clears_anchor() {
        assert_eq!(diff_step(None, Some("abc"), Some("abc"), "now"), None);
        assert_eq!(
            diff_step(Some("2026-01-01T00:00:00Z"), Some("abc"), Some("abc"), "now"),
            None,
            "operator caught up → clear anchor"
        );
    }

    #[test]
    fn diff_step_fresh_drift_stamps_now() {
        assert_eq!(
            diff_step(None, Some("aaa"), Some("bbb"), "now"),
            Some("now".to_owned())
        );
    }

    #[test]
    fn diff_step_sustained_drift_preserves_anchor() {
        assert_eq!(
            diff_step(
                Some("2026-05-20T14:00:00Z"),
                Some("aaa"),
                Some("bbb"),
                "2026-05-26T08:00:00Z"
            ),
            Some("2026-05-20T14:00:00Z".to_owned())
        );
    }

    #[test]
    fn diff_step_probe_failure_preserves_drift_anchor() {
        // Critical: when previously drifted and the probe now
        // fails, the anchor must be carried forward — we ARE
        // still behind, we just can't confirm against upstream
        // this tick. Earlier behavior cleared the anchor here,
        // making the operator's "behind since" stamp reset every
        // network blip.
        assert_eq!(
            diff_step(
                Some("2026-05-20T14:00:00Z"),
                Some("aaa"),
                None,
                "2026-05-26T08:00:00Z"
            ),
            Some("2026-05-20T14:00:00Z".to_owned())
        );
        // Probe failure with no prior anchor stays at None — we
        // can't fabricate an anchor we don't know.
        assert_eq!(diff_step(None, Some("aaa"), None, "now"), None);
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
        // Per-process + per-nanosecond suffix so repeated `cargo
        // test` runs (or two flavors of the same binary) can't
        // collide on a fixed slot.
        let dir = std::env::temp_dir().join(format!(
            "atty-guard-drift-rt-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0),
        ));
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
        // Unique-per-process path under the OS tempdir so parallel
        // test runs (or repeated invocations) don't collide on a
        // fixed `/tmp/...` slot — and a stale leftover with the
        // wrong perms can't accidentally make the test green.
        let dir = std::env::temp_dir().join(format!(
            "atty-guard-drift-missing-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0),
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("nonexistent.json");
        let r = read_snapshot(&path).unwrap();
        assert!(r.is_none());
        std::fs::remove_dir_all(&dir).ok();
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
