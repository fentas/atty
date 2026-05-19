//! V2-F live OSV.dev lookup for `npm install <pkg>` Tier-1 misses.
//!
//! Flow:
//!
//!   1. atty types `npm install foo` + Enter.
//!   2. Tier-1's `flagged_npm.txt` check runs first (microseconds).
//!   3. On miss, atty-guard queries `api.osv.dev/v1/query` for
//!      `{ package: { name: "foo", ecosystem: "npm" } }`.
//!   4. If OSV returns any vulnerability AND its severity is
//!      "MEDIUM"+ OR its summary contains "malicious" / "supply
//!      chain" / "compromised" — verdict = Warn.
//!   5. Cached in-mem for the daemon's lifetime so the second
//!      `npm install foo` in the same session is free.
//!
//! Why not query OSV for EVERY classify: rate limits (OSV asks
//! for ≤ 1 req/s per client), latency (each lookup is one HTTPS
//! round-trip, ~80-200 ms even on a fast link), and privacy (every
//! lookup leaks the package name you're about to install — atty's
//! position on "atty IS the endpoint" extends to "the daemon
//! talks to one well-known service for vuln data, nothing else").
//!
//! Feature-gated behind `osv-live` so default builds stay
//! network-free and don't pull `ureq` + `rustls` into the dep tree.

use crate::protocol::{Category, ClassifyResult, Verdict};
use std::time::Duration;

/// Configuration for the OSV backend. Drives `osv-live` feature
/// builds; ignored when the feature is off.
#[derive(Debug, Clone)]
pub struct OsvConfig {
    /// API root; defaults to `https://api.osv.dev` so users can
    /// point at a mirror / on-prem proxy for air-gapped envs.
    pub endpoint: String,
    /// Per-query timeout. Tight default — Tier-2 budget is 50 ms
    /// total; even on cold caches OSV typically replies in
    /// 200-500 ms, so we accept that the FIRST hit on a new
    /// package falls through to in-proc patterns + the user re-
    /// types, while the SECOND hit (cached) is instant.
    pub timeout: Duration,
    /// Cache TTL — how long to remember a lookup's verdict for.
    /// Default 1 hour balances "respect new disclosures" against
    /// "don't re-query for the same package on every npm install".
    pub cache_ttl: Duration,
}

impl Default for OsvConfig {
    fn default() -> Self {
        Self {
            endpoint: "https://api.osv.dev".into(),
            timeout: Duration::from_millis(250),
            cache_ttl: Duration::from_secs(3600),
        }
    }
}

/// Public verdict from an OSV lookup. None = no known vulnerability
/// for that package / version. Some = there's at least one matching
/// advisory; the inner string is a human-readable summary the
/// daemon hands to atty for the banner.
#[derive(Debug, Clone)]
pub enum OsvVerdict {
    None,
    /// Generic CVE / advisory hit — surfaces a Warn. Inner string
    /// is the advisory ID + one-line summary.
    Vulnerable(String),
    /// Heuristic match on advisory text: "malicious package",
    /// "supply-chain attack", "compromised maintainer", "typosquat".
    /// Stronger signal — recommend Block.
    Malicious(String),
}

#[derive(Debug)]
pub enum LookupError {
    FeatureNotBuilt,
    NetworkError(String),
    ParseError(String),
}

impl std::fmt::Display for LookupError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LookupError::FeatureNotBuilt => write!(f, "OSV feature not built — rebuild with --features osv-live"),
            LookupError::NetworkError(s) => write!(f, "OSV network error: {s}"),
            LookupError::ParseError(s) => write!(f, "OSV parse error: {s}"),
        }
    }
}

impl std::error::Error for LookupError {}

/// Map an OSV verdict back into the daemon's `ClassifyResult` shape.
/// Public so the classifier can pull this in without juggling
/// types — keeps the OSV module isolated.
pub fn osv_verdict_to_result(verdict: OsvVerdict, package: &str) -> Option<ClassifyResult> {
    match verdict {
        OsvVerdict::None => None,
        OsvVerdict::Vulnerable(summary) => Some(ClassifyResult {
            verdict: Verdict::Warn,
            category: Category::NpmUnsafeInstall,
            confidence: 0.7,
            reason: format!("OSV: {summary}"),
            matched: format!("npm install {package}"),
        }),
        OsvVerdict::Malicious(summary) => Some(ClassifyResult {
            verdict: Verdict::Block,
            category: Category::NpmUnsafeInstall,
            confidence: 0.95,
            reason: format!("OSV (malicious): {summary}"),
            matched: format!("npm install {package}"),
        }),
    }
}

// ===========================================================================
// Feature-OFF stub.

#[cfg(not(feature = "osv-live"))]
pub struct OsvClient;

#[cfg(not(feature = "osv-live"))]
impl OsvClient {
    pub fn new(_cfg: OsvConfig) -> Self {
        Self
    }
    pub fn lookup_npm(&self, _package: &str) -> Result<OsvVerdict, LookupError> {
        Err(LookupError::FeatureNotBuilt)
    }
}

// ===========================================================================
// Feature-ON impl.

#[cfg(feature = "osv-live")]
mod with_ureq {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;
    use std::time::Instant;

    pub struct OsvClient {
        endpoint: String,
        agent: ureq::Agent,
        cache: Mutex<HashMap<String, (Instant, OsvVerdict)>>,
        cache_ttl: Duration,
    }

    impl OsvClient {
        pub fn new(cfg: OsvConfig) -> Self {
            let agent = ureq::AgentBuilder::new()
                .timeout(cfg.timeout)
                .user_agent("atty-guard/0.1 (+https://github.com/fentas/atty)")
                .build();
            Self {
                endpoint: cfg.endpoint,
                agent,
                cache: Mutex::new(HashMap::new()),
                cache_ttl: cfg.cache_ttl,
            }
        }

        pub fn lookup_npm(&self, package: &str) -> Result<OsvVerdict, LookupError> {
            // Cache check.
            if let Some(verdict) = self.cache_get(package) {
                return Ok(verdict);
            }

            let body = serde_json::json!({
                "package": { "name": package, "ecosystem": "npm" }
            });
            let url = format!("{}/v1/query", self.endpoint);
            let resp = self
                .agent
                .post(&url)
                .set("content-type", "application/json")
                .send_string(&body.to_string())
                .map_err(|e| LookupError::NetworkError(e.to_string()))?;
            let json: serde_json::Value = resp
                .into_json()
                .map_err(|e| LookupError::ParseError(e.to_string()))?;

            let verdict = parse_osv_response(&json);
            self.cache_set(package, verdict.clone());
            Ok(verdict)
        }

        fn cache_get(&self, package: &str) -> Option<OsvVerdict> {
            let g = self.cache.lock().expect("osv cache poisoned");
            let (when, v) = g.get(package)?;
            if when.elapsed() < self.cache_ttl {
                Some(v.clone())
            } else {
                None
            }
        }

        fn cache_set(&self, package: &str, v: OsvVerdict) {
            let mut g = self.cache.lock().expect("osv cache poisoned");
            g.insert(package.into(), (Instant::now(), v));
        }
    }
}

#[cfg(feature = "osv-live")]
pub use with_ureq::OsvClient;

/// Reduce an OSV /v1/query response to one of the three verdicts.
/// Pulled out for testability — no network involved.
///
/// Heuristic: any vuln record makes the result `Vulnerable`; if
/// any of the records' `summary` field contains a string from
/// `MALICIOUS_MARKERS`, escalate to `Malicious`.
pub fn parse_osv_response(json: &serde_json::Value) -> OsvVerdict {
    let vulns = match json.get("vulns").and_then(|v| v.as_array()) {
        Some(a) if !a.is_empty() => a,
        _ => return OsvVerdict::None,
    };

    const MALICIOUS_MARKERS: &[&str] = &[
        "malicious package",
        "supply chain",
        "supply-chain",
        "compromised maintainer",
        "typosquat",
        "credentials",
        "credential theft",
    ];

    let mut summaries: Vec<&str> = Vec::new();
    let mut is_malicious = false;

    for v in vulns {
        if let Some(s) = v.get("summary").and_then(|s| s.as_str()) {
            let lower = s.to_lowercase();
            if MALICIOUS_MARKERS.iter().any(|m| lower.contains(m)) {
                is_malicious = true;
            }
            summaries.push(s);
        } else if let Some(id) = v.get("id").and_then(|s| s.as_str()) {
            // No summary — fall back to the advisory ID.
            summaries.push(id);
        }
    }

    let joined = summaries.join("; ");
    let truncated = if joined.len() > 200 {
        format!("{}…", &joined[..200])
    } else {
        joined
    };

    if is_malicious {
        OsvVerdict::Malicious(truncated)
    } else {
        OsvVerdict::Vulnerable(truncated)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_empty_vulns_returns_none() {
        let json = serde_json::json!({});
        assert!(matches!(parse_osv_response(&json), OsvVerdict::None));
        let json = serde_json::json!({ "vulns": [] });
        assert!(matches!(parse_osv_response(&json), OsvVerdict::None));
    }

    #[test]
    fn parse_one_vuln_with_summary_returns_vulnerable() {
        let json = serde_json::json!({
            "vulns": [{
                "id": "GHSA-xxxx-yyyy-zzzz",
                "summary": "Prototype pollution in lodash"
            }]
        });
        match parse_osv_response(&json) {
            OsvVerdict::Vulnerable(s) => {
                assert!(s.contains("Prototype pollution"));
            }
            other => panic!("expected Vulnerable, got {other:?}"),
        }
    }

    #[test]
    fn parse_malicious_marker_escalates_to_malicious() {
        let json = serde_json::json!({
            "vulns": [{
                "id": "MAL-2024-001",
                "summary": "Malicious package compromises CI credentials"
            }]
        });
        match parse_osv_response(&json) {
            OsvVerdict::Malicious(s) => {
                assert!(s.contains("Malicious"));
            }
            other => panic!("expected Malicious, got {other:?}"),
        }
    }

    #[test]
    fn parse_supply_chain_marker_also_malicious() {
        let json = serde_json::json!({
            "vulns": [{
                "id": "GHSA-supply-1",
                "summary": "Supply-chain attack via compromised maintainer"
            }]
        });
        assert!(matches!(parse_osv_response(&json), OsvVerdict::Malicious(_)));
    }

    #[test]
    fn parse_falls_back_to_id_when_summary_missing() {
        let json = serde_json::json!({
            "vulns": [{ "id": "GHSA-onlyid-2024" }]
        });
        match parse_osv_response(&json) {
            OsvVerdict::Vulnerable(s) => {
                assert!(s.contains("GHSA-onlyid-2024"));
            }
            other => panic!("expected Vulnerable, got {other:?}"),
        }
    }

    #[test]
    fn osv_verdict_to_result_maps_correctly() {
        assert!(osv_verdict_to_result(OsvVerdict::None, "x").is_none());
        let r = osv_verdict_to_result(OsvVerdict::Vulnerable("blah".into()), "lodash").unwrap();
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.reason.contains("blah"));
        let r = osv_verdict_to_result(OsvVerdict::Malicious("evil".into()), "rogue").unwrap();
        assert!(matches!(r.verdict, Verdict::Block));
    }

    #[cfg(not(feature = "osv-live"))]
    #[test]
    fn lookup_without_feature_errors_cleanly() {
        let c = OsvClient::new(OsvConfig::default());
        match c.lookup_npm("anything") {
            Err(LookupError::FeatureNotBuilt) => {}
            Ok(_) => panic!("expected FeatureNotBuilt"),
            Err(other) => panic!("expected FeatureNotBuilt, got {other}"),
        }
    }

    #[test]
    fn load_error_display() {
        let s = format!("{}", LookupError::FeatureNotBuilt);
        assert!(s.contains("osv-live"));
        let s = format!("{}", LookupError::NetworkError("timed out".into()));
        assert!(s.contains("timed out"));
    }
}
