#![cfg(feature = "atoms-fetch")]

use std::path::Path;
use std::time::Duration;

use super::fetch::fetch_all;
use super::pins::load_pins;
use super::{FetcherConfig, SourceId, DEFAULT_PIN_FILE};

/// Spawn the cron-style background refresh. Fetches FIRST
/// (so a daemon launched with `--atoms-update-interval` always
/// gets a fresh corpus on startup, not after one interval), then
/// sleeps. Failures don't abort the thread — the next interval
/// gets another shot.
pub fn spawn_periodic_refresh(
    cfg: FetcherConfig,
    sources: Vec<SourceId>,
    interval: Duration,
    trust_store: std::sync::Arc<crate::trust_store::TrustStore>,
) {
    let builder = std::thread::Builder::new().name("atty-guard-atoms-refresh".into());
    // `cfg` is mutable inside the loop so successful pin
    // reloads stick across ticks. Earlier shape used
    // `cfg.clone()` per iteration, which always cloned the
    // STARTUP cfg — meaning a mid-life pin bump that loaded
    // successfully at tick N would be silently reverted by
    // ANY error at tick N+1 (parse fail, transient FS
    // hiccup, etc.). The mutable form preserves the last
    // successful state across the error arm.
    //
    // Tracks pin-state transitions for journald breadcrumbs
    // when the operator removes/re-creates the file.
    let spawn_result = builder.spawn(move || {
        let mut cfg = cfg;
        let mut had_pins = cfg.pins.is_some();
        loop {
            // Re-read /etc/atty-guard/atoms.pins.toml every tick so
            // an operator bumping pins doesn't need to restart the
            // daemon to get a fresh fetch under the new pin. A
            // newly-broken pin file (operator mid-edit) keeps the
            // last-good cfg.pins — the cron is fail-safe rather
            // than fail-closed for this auxiliary path. An ENOENT
            // (operator removed the file) is treated as a state
            // transition to live tracking, but we log it so the
            // operator sees the downgrade in journald.
            match load_pins(Path::new(DEFAULT_PIN_FILE)) {
                Ok(pins) => {
                    let now_pinned = pins.is_some();
                    if had_pins && !now_pinned {
                        eprintln!(
                            "atty-guard: pin file removed — switching to live tracking (refs/heads/master). Restore /etc/atty-guard/atoms.pins.toml if this was unintentional."
                        );
                    } else if !had_pins && now_pinned {
                        eprintln!(
                            "atty-guard: pin file detected — switching to pinned-commit tracking."
                        );
                    }
                    had_pins = now_pinned;
                    cfg.pins = pins;
                }
                Err(e) => {
                    // Keep the last-known cfg.pins unchanged —
                    // mid-edit truncation shouldn't revert a
                    // previously-successful pin reload.
                    eprintln!(
                        "atty-guard: pin reload failed (keeping last-known) — {e}"
                    );
                }
            }
            match fetch_all(&cfg, &sources) {
                Ok(report) => {
                    eprintln!(
                        "atty-guard: atom refresh ok — {} atoms across {} sources",
                        report.atoms_total,
                        report.per_source.len()
                    );
                    // Reload the in-memory corpus from the file we
                    // just wrote so classify dispatch picks up the
                    // new entries without waiting for daemon restart.
                    // Failure here is non-fatal: the next refresh
                    // tick gets another shot, and the perm-gate error
                    // (if any) already went to journald.
                    match trust_store.reload_system_fetched() {
                        Ok(n) => eprintln!(
                            "atty-guard: atoms.system.txt reloaded ({n} atoms in memory)"
                        ),
                        Err(e) => {
                            eprintln!("atty-guard: atoms.system.txt reload failed — {e}");
                        }
                    }
                    // V2-I drift snapshot (#209): after a
                    // successful fetch, probe each source's
                    // current `refs/heads/master` head SHA and
                    // diff it against the operator's pin. Read
                    // the prior snapshot first so `behind_since`
                    // anchors to the first observed drift, not
                    // each tick. A probe failure renders the
                    // affected source's `upstream` as null in
                    // the NEW snapshot AND preserves the prior
                    // `behind_since` anchor via `diff_step`.
                    let drift_path = std::path::Path::new(
                        crate::atom_drift::DEFAULT_DRIFT_FILE,
                    );
                    let prev = crate::atom_drift::read_snapshot(drift_path).ok().flatten();
                    let snapshot = crate::atom_drift::compute_snapshot(
                        cfg.pins.as_ref(),
                        &sources,
                        &cfg.user_agent,
                        cfg.timeout,
                        prev.as_ref(),
                    );
                    // Log a journald breadcrumb on drift onset
                    // (in-sync → behind) so operators see the
                    // signal without polling `atoms drift`. We
                    // only log the transition, not every tick,
                    // to keep logs quiet during a long-running
                    // drift window.
                    let was_behind = prev.as_ref().map(|s| s.any_behind()).unwrap_or(false);
                    if !was_behind && snapshot.any_behind() {
                        eprintln!(
                            "atty-guard: atom pin drift detected — run \
                             `atty-guard atoms drift` for details. Bump pins in \
                             /etc/atty-guard/atoms.pins.toml when ready."
                        );
                    }
                    if let Err(e) =
                        crate::atom_drift::write_snapshot(drift_path, &snapshot)
                    {
                        eprintln!(
                            "atty-guard: drift snapshot write failed — {e} \
                             (telemetry only; classifier unaffected)"
                        );
                    }
                }
                Err(e) => {
                    eprintln!("atty-guard: atom refresh failed — {e}");
                }
            }
            // Sleep until the next interval — interruptibly,
            // so a SIGTERM during a 6h sleep wakes the thread
            // within ~200ms instead of waiting out the full
            // interval (#276).
            crate::shutdown::sleep_interruptible(
                interval,
                std::time::Duration::from_millis(200),
            );
            if crate::shutdown::requested() {
                break;
            }
        }
    });
    if let Err(e) = spawn_result {
        eprintln!(
            "atty-guard: cron thread spawn failed — {e}; atoms will not refresh until restart"
        );
    }
}
