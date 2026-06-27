use super::{FetchError, FetchReport, FetcherConfig, SourceId};

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
    _interval: std::time::Duration,
    _trust_store: std::sync::Arc<crate::trust_store::TrustStore>,
) {
    // No-op in builds without the feature. main.rs logs the
    // FeatureNotBuilt and continues with the bundled atoms.
}

#[cfg(feature = "atoms-fetch")]
pub use super::cron::spawn_periodic_refresh;

// ===========================================================================
// Feature-ON impl.

#[cfg(feature = "atoms-fetch")]
use super::extract::{
    extract_gtfobins_atoms, extract_sigma_atoms, is_gtfobins_entry_file, is_sigma_linux_rule,
    walk_tarball_atoms, write_atoms,
};

#[cfg(feature = "atoms-fetch")]
use sha2::{Digest, Sha256};
#[cfg(feature = "atoms-fetch")]
use std::collections::BTreeSet;
#[cfg(feature = "atoms-fetch")]
use std::io::Read;

/// Defense-in-depth cap on the merged-corpus size after parsing.
/// Sigma + GTFOBins together produce ~600-800 atoms today; 10k
/// is ~12x headroom for upstream growth without being so loose
/// that a parser bug (or compromised upstream that slips a huge
/// junk corpus through both the SHA pin AND our parsers — yes,
/// it's belt+braces) can balloon the in-memory AtomMatcher.
/// Hit means we refuse to write and keep the last-good file.
#[cfg(feature = "atoms-fetch")]
pub(super) const MAX_ATOMS_TOTAL: usize = 10_000;

/// Defense-in-depth atom cap. Refuse to overwrite
/// `atoms.system.txt` if the parsed corpus exceeds the cap —
/// a parser bug or compromised upstream that somehow slipped
/// a wildly inflated corpus past every other gate keeps the
/// last-good file in place. Lifted into its own function so
/// the behavioral test can hit the error path without going
/// through fetch_all's network step.
#[cfg(feature = "atoms-fetch")]
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
#[cfg(feature = "atoms-fetch")]
pub(super) fn enforce_tarball_size_cap(url: &str, len: usize) -> Result<(), FetchError> {
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
#[cfg(feature = "atoms-fetch")]
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
#[cfg(feature = "atoms-fetch")]
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

#[cfg(feature = "atoms-fetch")]
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
#[cfg(feature = "atoms-fetch")]
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

#[cfg(feature = "atoms-fetch")]
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
#[cfg(feature = "atoms-fetch")]
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
#[cfg(feature = "atoms-fetch")]
pub(super) fn verify_digest(url: &str, bytes: &[u8], expected_hex: &str) -> Result<(), FetchError> {
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

#[cfg(feature = "atoms-fetch")]
fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

#[cfg(all(test, feature = "atoms-fetch"))]
mod tests {
    use super::*;

    #[test]
    fn fetch_all_refuses_to_overwrite_when_all_sources_fail() {
        // No sources requested → no atoms collected →
        // fetch_all returns an error and DOES NOT call
        // write_atoms. Belt-and-braces against silently
        // wiping the last-good corpus.
        let dir =
            std::env::temp_dir().join(format!("atty-guard-fetcher-empty-{}", std::process::id()));
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
}
