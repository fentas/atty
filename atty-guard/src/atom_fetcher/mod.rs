// Type definitions (FetcherConfig, FetchError, …) live at the top of
// the module and are referenced by both the feature-on impl below
// AND the no-feature stub. With `--features atoms-fetch` they're
// fully alive; without the feature the daemon still compiles them
// for API stability but never constructs them — silence the
// dead-code lint for that build only.
#![cfg_attr(not(feature = "atoms-fetch"), allow(dead_code, unused_imports))]

//! V2-I daemon-internal atom fetcher.
//!
//! Pulls IOC corpora from configurable upstream sources, parses
//! them into atom strings, and writes the merged set to
//! `atoms.system.txt` in the daemon's state directory. The
//! daemon's TrustStore loads that file at startup + after each
//! refresh — see `trust_store::reload_system_fetched`.
//!
//! Two operating modes:
//!
//!   - **One-shot CLI**: `atty-guard --update-atoms-now
//!     [--atoms-sources <csv>]`. Fetches the configured sources
//!     synchronously, writes the merged atom set, exits without
//!     binding the UDS socket.
//!
//!   - **Cron**: `atty-guard --atoms-update-interval 6h` runs the
//!     daemon AND spawns a background thread that re-runs the
//!     fetch every interval. Failed fetches log + continue; the
//!     last good `atoms.system.txt` stays in place. After each
//!     successful fetch the spawn thread calls
//!     `trust_store.reload_system_fetched()` so the daemon's
//!     in-memory copy hot-reloads without a restart.
//!
//! Output location: `$STATE_DIRECTORY/atoms.system.txt` (set by
//! the systemd unit's `StateDirectory=atty-guard` directive to
//! `/var/lib/atty-guard/`, atty:atty owned 0750). The
//! TrustStore enforces a permission gate at load time: owner must
//! be the daemon's own UID, mode must not be group/world-writable.
//!
//! Source registry:
//!
//!   - **GTFOBins** — handcurated Linux LOLBAS corpus. ~50 binaries
//!     each with a YAML-fronted markdown manifest. We grab the
//!     repo tarball, walk `_gtfobins/<name>`, extract the
//!     `functions.shell` / `functions.bind-shell` / etc. command
//!     fragments. Small (~150 atoms), high signal.
//!   - **Sigma (Linux subset)** — SigmaHQ rule corpus. Walks
//!     `rules/linux/**/*.yml` and extracts `CommandLine|contains`
//!     substrings from every selector block. Several hundred
//!     atoms covering credential theft / privesc / lateral
//!     movement / persistence shapes.
//!
//! LOLBAS (Living-Off-the-Land Binaries) was a third source in
//! earlier revisions. It was dropped because its corpus is Windows-
//! native by definition — the project's whole reason for existing
//! is curating Microsoft-side LOLBins. Empirically ~423 atoms were
//! pulled from `yml/OS{Binaries,Scripts,Libraries}/`, and roughly
//! all of them were Windows shapes (`rundll32.exe shell32.dll,
//! Control_RunDLL {PATH_ABSOLUTE:.dll}`, `Pester.bat ;{PATH:.exe}`,
//! `wlrmdr.exe -s 3600 -f 0 -t _ -m _ ...`). None ever fire on a
//! Linux shell line, and the documented "wine + ssh-pivot via
//! Windows tools" rationale didn't survive contact with the real
//! atoms. If future Windows/WSL2 support lands, recover the
//! original fetcher + parser + tests with `git log --all -- .` on
//! this file to find the removal commit and cherry-pick from before
//! it.
//!
//! Feature-gated behind `atoms-fetch` so default builds don't
//! pull `flate2` + `tar` + `serde_yaml`.

use std::path::{Path, PathBuf};
use std::time::Duration;

mod cron;
mod extract;
mod fetch;
mod pins;

pub use fetch::{fetch_all, spawn_periodic_refresh};
#[allow(unused_imports)]
pub use pins::{load_pins, load_pins_with_owner};

/// Source ID for CLI selection + telemetry. New sources land
/// as additional variants here; the dispatch in `fetch_one` adds
/// a match arm with the source-specific parser.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceId {
    Gtfobins,
    /// SigmaHQ Linux rule corpus — extracts `CommandLine|contains`
    /// substrings from `rules/linux/**.yml`. Several hundred atoms
    /// covering credential theft, privilege escalation, lateral
    /// movement, persistence shapes. Placeholder atoms (Sigma rule
    /// authoring convention like `/path/to/output-file` or
    /// `{PATH:.exe}`) get filtered at extract time — see
    /// `is_placeholder_atom`.
    Sigma,
}

impl SourceId {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "gtfobins" => Some(SourceId::Gtfobins),
            "sigma" => Some(SourceId::Sigma),
            _ => None,
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            SourceId::Gtfobins => "gtfobins",
            SourceId::Sigma => "sigma",
        }
    }

    /// All sources enabled by default. Used by the no-arg
    /// `atty-guard --update-atoms-now` form.
    pub fn default_enabled() -> &'static [SourceId] {
        &[SourceId::Gtfobins, SourceId::Sigma]
    }
}

/// Configuration knobs for the fetcher. Held by the daemon's
/// shared state; the cron thread reads it on each tick.
#[derive(Debug, Clone)]
pub struct FetcherConfig {
    /// Where the fetched atom set lands. Defaults to
    /// `$STATE_DIRECTORY/atoms.system.txt` (systemd-managed) or
    /// `/var/lib/atty-guard/atoms.system.txt` for non-systemd runs.
    pub output_path: PathBuf,
    /// Per-source HTTP timeout — tarballs are typically ~1-2 MB
    /// each, so a 30 s budget is comfortable on slow connections
    /// but bails fast on a wedged endpoint.
    pub timeout: Duration,
    /// User-agent string sent with every request. Identifies
    /// atty-guard cleanly in upstream logs (GTFOBins / SigmaHQ
    /// have requested polite UA strings in their READMEs).
    pub user_agent: String,
    /// Operator-set commit pins loaded from
    /// `/etc/atty-guard/atoms.pins.toml`. `None` = live tracking
    /// of `refs/heads/master` (the default). `Some(pins)` means
    /// each present source uses its pinned commit URL and the
    /// fetcher verifies the downloaded tarball's SHA-256 before
    /// parsing. A missing per-source pin under a present file
    /// falls back to live tracking for that source.
    pub pins: Option<AtomPins>,
}

impl Default for FetcherConfig {
    fn default() -> Self {
        Self {
            output_path: default_atoms_path(),
            timeout: Duration::from_secs(30),
            user_agent: format!(
                "atty-guard/{} (+https://github.com/fentas/atty)",
                env!("CARGO_PKG_VERSION")
            ),
            pins: None,
        }
    }
}

impl FetcherConfig {
    /// Constructor that loads operator pin overrides from
    /// `DEFAULT_PIN_FILE` (`/etc/atty-guard/atoms.pins.toml`). Use
    /// this from daemon startup paths. Absent file = `pins: None`
    /// (live tracking, the default). Malformed file is a HARD
    /// error: the operator wants pinning but typed something
    /// wrong; silently falling back to live tracking would defeat
    /// the whole point of opting in.
    ///
    /// The no-`atoms-fetch`-feature build keeps the symbol alive
    /// (returns default with `pins: None`) so call sites in main.rs
    /// can stay un-gated — the daemon's atom-fetch paths are
    /// already feature-gated upstream, so a default-build operator
    /// who passes `--update-atoms-now` hits the FeatureNotBuilt
    /// arm in `fetch_all`, not a missing-symbol link error here.
    pub fn default_with_pins() -> Result<Self, FetchError> {
        Self::default_with_pins_from(Path::new(DEFAULT_PIN_FILE))
    }

    /// Test seam — same as `default_with_pins` but with an
    /// explicit path so unit tests can point at a temp file.
    #[cfg(feature = "atoms-fetch")]
    pub fn default_with_pins_from(path: &Path) -> Result<Self, FetchError> {
        let pins = load_pins(path)?;
        Ok(Self {
            pins,
            ..Self::default()
        })
    }

    #[cfg(not(feature = "atoms-fetch"))]
    pub fn default_with_pins_from(_path: &Path) -> Result<Self, FetchError> {
        Ok(Self::default())
    }
}

/// Operator-set commit pins. Loaded from a TOML file with shape:
///
/// ```toml
/// [gtfobins]
/// commit = "7382261ef936e35896ba70e7a6b833352ffb9a22"
/// sha256 = "3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca"
///
/// [sigma]
/// commit = "994da16651194500b607a3007186c29779e1f961"
/// sha256 = "cfbf8b6adae659af15dc147e6d8497c10d48e87dafd584efcfd729f7f9f8d505"
/// ```
///
/// Off-by-default. Operators copy `atoms.pins.toml.example` and
/// edit. Removed/missing keys revert that source to live tracking.
///
/// `deny_unknown_fields`: a typo'd section header (`[gtfobin]`
/// instead of `[gtfobins]`) would otherwise parse silently into
/// `AtomPins{None, None}` — operator opted in, got opt-out
/// behaviour, no warning. Hard error matches the stated posture
/// for the rest of pin-file parsing.
#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AtomPins {
    pub gtfobins: Option<PinEntry>,
    pub sigma: Option<PinEntry>,
}

/// Per-source pin. `commit` is the git SHA the operator has
/// reviewed; `sha256` is the SHA-256 of the codeload tarball at
/// that commit. Both are validated case-insensitively as hex.
///
/// `deny_unknown_fields`: typo'd key (`comit = "..."`) would
/// otherwise drop the operator's pin silently.
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PinEntry {
    pub commit: String,
    pub sha256: String,
}

impl PinEntry {
    /// Codeload URL for `<owner>/<repo>` at this pinned commit.
    pub fn tarball_url(&self, owner_repo: &str) -> String {
        format!(
            "https://codeload.github.com/{owner_repo}/tar.gz/{}",
            self.commit
        )
    }
}

/// Where the daemon looks for the operator pin file.
pub const DEFAULT_PIN_FILE: &str = "/etc/atty-guard/atoms.pins.toml";

/// Resolve where the fetcher writes its output. The daemon's
/// classify hot path reads this file from
/// `<state_root>/atoms.system.txt` (see
/// `TrustStore::reload_system_fetched`), so write order matters:
///
/// 1. `STATE_DIRECTORY/atoms.system.txt` — set by systemd when the
///    unit has `StateDirectory=atty-guard`. This is the canonical
///    post-#140 / post-#150 path: `/var/lib/atty-guard/atoms.system.txt`,
///    atty:atty owned, daemon-writable, daemon-readable.
/// 2. `/var/lib/atty-guard/atoms.system.txt` — non-systemd installs
///    or local dev runs as the atty user.
///
/// XDG_DATA_HOME is NOT used anymore: the daemon (running as atty
/// user with `ProtectHome=yes`) can't see $USER's home, AND the
/// classify hot path doesn't read from there. The old path was
/// a write-only dead-drop and led to the "atom-fetcher writes a
/// file the daemon ignores" bug fixed in #150.
pub fn default_atoms_path() -> PathBuf {
    if let Ok(state_dir) = std::env::var("STATE_DIRECTORY") {
        if let Some(first) = state_dir.split(':').next() {
            if !first.is_empty() {
                return PathBuf::from(first).join("atoms.system.txt");
            }
        }
    }
    PathBuf::from("/var/lib/atty-guard/atoms.system.txt")
}

/// Public alias for the placeholder-atom check used by both
/// atom_fetcher's feature-gated extractor and the trust_store's
/// `atoms add` validator. Lifted out of `mod imp` so it's
/// always available regardless of feature flags — the predicate
/// itself has zero dependencies (pure string ops).
pub fn is_placeholder_atom_public(atom: &str) -> bool {
    // Sigma directory-path placeholder convention.
    if atom.contains("/path/to/") {
        return true;
    }
    // LOLBAS-style `{PATH:.ext}` / `{PATH_ABSOLUTE:.ext}` templates.
    if atom.contains("{PATH:") || atom.contains("{PATH_ABSOLUTE:") {
        return true;
    }
    // Angle-bracket placeholders — `<hostname>`, `<user>`, `<ip>`.
    if let Some(lt) = atom.find('<') {
        let after_lt = &atom[lt + 1..];
        if let Some(gt_off) = after_lt.find('>') {
            let inner = &after_lt[..gt_off];
            if !inner.is_empty()
                && inner
                    .chars()
                    .all(|c| c.is_alphanumeric() || c == '_' || c == '-')
            {
                return true;
            }
        }
    }
    false
}

#[derive(Debug)]
pub enum FetchError {
    /// Only constructed by the `#[cfg(not(feature = "atoms-fetch"))]`
    /// stub `fetch_all` below — emitted when the daemon was built
    /// without the feature but the operator still passes
    /// `--update-atoms-now`. With the feature ON this variant is
    /// dead code; the `#[allow(dead_code)]` keeps the API surface
    /// uniform across feature combinations so callers don't have
    /// to cfg-gate their match arms.
    #[allow(dead_code)]
    FeatureNotBuilt,
    NetworkError(String),
    DecompressError(String),
    ParseError(String),
    WriteError(String),
    /// Operator-pinned commit SHA + expected SHA-256 of the
    /// tarball didn't match what we downloaded. Could be:
    /// upstream force-pushed the pinned commit (unlikely on
    /// GitHub), the operator's pin in
    /// `/etc/atty-guard/atoms.pins.toml` is for a commit whose
    /// tarball codeload now serves differently (rare — codeload
    /// is byte-stable per commit), or a MITM tampered with the
    /// download (rare with HTTPS+rustls but the digest is the
    /// actual proof). Either way: refuse to use the tarball;
    /// keep the existing atoms.system.txt intact. Resolve by
    /// re-running the pin-bump procedure in
    /// `atoms.pins.toml.example`.
    DigestMismatch {
        url: String,
        expected: String,
        actual: String,
    },
}

impl std::fmt::Display for FetchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FetchError::FeatureNotBuilt => write!(
                f,
                "atoms-fetch feature not built — rebuild with `cargo build --features atoms-fetch`"
            ),
            FetchError::NetworkError(s) => write!(f, "network error: {s}"),
            FetchError::DecompressError(s) => write!(f, "decompress error: {s}"),
            FetchError::ParseError(s) => write!(f, "parse error: {s}"),
            FetchError::WriteError(s) => write!(f, "write error: {s}"),
            FetchError::DigestMismatch {
                url,
                expected,
                actual,
            } => write!(
                f,
                "digest mismatch for {url}: expected sha256={expected}, got sha256={actual} — refusing to overwrite atoms.system.txt; check the pinned commit + sha256 in /etc/atty-guard/atoms.pins.toml (bump per the refresh procedure in atoms.pins.toml.example if the pin is intentionally behind)"
            ),
        }
    }
}

impl std::error::Error for FetchError {}

/// Summary of one fetch pass — what was tried, what landed, how
/// many atoms surfaced per source. Returned from `fetch_all` so
/// the daemon's log can show a one-line "refreshed N atoms from
/// M sources" message.
#[derive(Debug, Clone, Default)]
pub struct FetchReport {
    pub atoms_total: usize,
    pub per_source: Vec<(SourceId, Result<usize, String>)>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_id_parse() {
        assert_eq!(SourceId::parse("gtfobins"), Some(SourceId::Gtfobins));
        assert_eq!(SourceId::parse("sigma"), Some(SourceId::Sigma));
        // `lolbas` was removed — see module docs for the rationale.
        assert_eq!(SourceId::parse("lolbas"), None);
        assert_eq!(SourceId::parse("unknown"), None);
        assert_eq!(SourceId::parse(""), None);
    }

    #[test]
    fn default_enabled_includes_both_linux_sources() {
        let defaults = SourceId::default_enabled();
        assert!(defaults.contains(&SourceId::Gtfobins));
        assert!(defaults.contains(&SourceId::Sigma));
        assert_eq!(defaults.len(), 2);
    }

    #[test]
    fn source_id_name_round_trip() {
        for sid in SourceId::default_enabled() {
            assert!(SourceId::parse(sid.name()).is_some());
        }
    }

    #[test]
    fn default_atoms_path_under_state_or_var_lib() {
        let p = default_atoms_path();
        // Post-#150: the fetcher writes to atoms.system.txt at the
        // state-root (so the daemon's TrustStore reads it).
        assert!(p.ends_with("atoms.system.txt"));
        assert!(p.to_string_lossy().contains("atty-guard"));
    }

    #[test]
    fn fetch_error_display_includes_hint() {
        let e = FetchError::FeatureNotBuilt;
        let s = format!("{e}");
        assert!(s.contains("atoms-fetch"));
    }

    #[cfg(not(feature = "atoms-fetch"))]
    #[test]
    fn fetch_without_feature_errors_cleanly() {
        match fetch_all(&FetcherConfig::default(), &[SourceId::Gtfobins]) {
            Err(FetchError::FeatureNotBuilt) => {}
            Ok(_) => panic!("expected FeatureNotBuilt on default build"),
            Err(other) => panic!("expected FeatureNotBuilt, got {other}"),
        }
    }
}
