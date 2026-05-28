//! Process-wide graceful-shutdown flag (#276).
//!
//! systemd's `KillSignal=SIGTERM` then 90s grace works for the
//! UDS listen loop (the per-connection threads exit on EOF), but
//! the atoms-refresh cron sleeps non-interruptibly for the full
//! interval — a SIGTERM during a 6h sleep would wait 6h.
//!
//! This module exposes a single `AtomicBool` flag flipped by
//! SIGTERM / SIGINT / SIGHUP handlers. The cron loop polls it
//! between fetches via `sleep_interruptible`, so shutdown takes
//! at most one poll tick (~200 ms) rather than one interval.
//!
//! SIGHUP currently behaves like SIGTERM (graceful exit). A
//! future enhancement could differentiate it to trigger a config
//! reload — `config::load` is already idempotent — but for now
//! the simpler "any of the three asks us to leave" semantics
//! matches the stated goal of "clean shutdown" without
//! introducing new failure modes.

// `#![allow(dead_code)]` — `sleep_interruptible` / `requested` are
// only called from `atom_fetcher::spawn_periodic_refresh`, which is
// gated on `feature = "atoms-fetch"`. Without the feature the build
// would warn-as-error in CI for unused fns; the module's API is
// still useful when built with the feature off (e.g. `install()`
// remains a meaningful side effect for the listen-loop side).
#![allow(dead_code)]

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

static SHUTDOWN: AtomicBool = AtomicBool::new(false);

/// Install signal handlers for SIGTERM/SIGINT/SIGHUP. Idempotent —
/// safe to call once at startup. Subsequent calls re-install (the
/// kernel overwrites the prior handler).
///
/// Uses bare `libc::signal(2)` rather than `sigaction(2)` because
/// (a) the binding is one line of inline FFI vs. the larger sigaction
/// struct, (b) we don't need siginfo / sigmask, and (c) glibc
/// auto-upgrades to sigaction internally. The classic
/// "signal() handler can re-arm differently across BSD/SysV"
/// portability concern doesn't apply on Linux glibc/musl.
pub fn install() {
    // SAFETY: signal() takes a (signo, handler) pair. Handler is a
    // bare C function with no captured state — only touches the
    // static AtomicBool which is well-defined under async-signal
    // safety (atomic stores are signal-safe).
    unsafe {
        extern "C" {
            fn signal(
                signum: i32,
                handler: extern "C" fn(i32),
            ) -> extern "C" fn(i32);
        }
        // SIGTERM=15, SIGINT=2, SIGHUP=1 on every Linux ABI we
        // build for — hardcoding the integers avoids a libc-crate
        // dep just for the constants.
        let _ = signal(15, handle);
        let _ = signal(2, handle);
        let _ = signal(1, handle);
    }
}

extern "C" fn handle(_signo: i32) {
    SHUTDOWN.store(true, Ordering::Relaxed);
}

/// True once a SIGTERM/SIGINT/SIGHUP has been delivered.
pub fn requested() -> bool {
    SHUTDOWN.load(Ordering::Relaxed)
}

/// Sleep for `total`, polling the shutdown flag every `step`. Returns
/// early when the flag flips. The bounded poll cadence means a
/// shutdown signal during a long cron interval is acted on within
/// one `step` instead of waiting out the full sleep.
pub fn sleep_interruptible(total: Duration, step: Duration) {
    let start = std::time::Instant::now();
    while start.elapsed() < total {
        if requested() {
            return;
        }
        let remaining = total.saturating_sub(start.elapsed());
        std::thread::sleep(if remaining < step { remaining } else { step });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sleep_interruptible_returns_promptly_on_flag_flip() {
        // Test seam — reset state, flip flag from another thread,
        // verify the sleep returns before the requested duration.
        SHUTDOWN.store(false, Ordering::Relaxed);
        let start = std::time::Instant::now();
        let handle = std::thread::spawn(|| {
            std::thread::sleep(Duration::from_millis(50));
            SHUTDOWN.store(true, Ordering::Relaxed);
        });
        sleep_interruptible(Duration::from_secs(5), Duration::from_millis(20));
        handle.join().unwrap();
        let elapsed = start.elapsed();
        assert!(
            elapsed < Duration::from_millis(500),
            "expected early wake (<500ms), got {elapsed:?}"
        );
        // Reset so subsequent tests aren't poisoned.
        SHUTDOWN.store(false, Ordering::Relaxed);
    }
}
