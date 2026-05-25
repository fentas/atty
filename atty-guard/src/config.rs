//! TOML config loader for atty-guard. Loaded once at startup via
//! `--config <path>`. All fields are optional — CLI flags +
//! compiled-in defaults fill in anything the file doesn't set.
//!
//! Lives in its own module so callers (main.rs) get a typed view
//! of the config; the rest of the daemon never touches the raw
//! `toml` parser.

use serde::Deserialize;
use std::path::Path;

#[derive(Debug, Default, Clone, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub tier2: Tier2Config,
    /// V2-J Phase 2: accumulator tuning. Empty by default —
    /// every knob has a conservative compiled-in fallback.
    #[serde(default)]
    pub accumulator: AccumulatorConfig,
    /// Server-side resource caps. Defaults are documented on
    /// each field; the [server] table is optional in the file
    /// and falls back to safe values when omitted.
    #[serde(default)]
    pub server: ServerConfig,
}

/// Bounded-resources knobs for the UDS server. The socket is
/// group-accessible (atty group on system installs); without
/// these caps a buggy / hostile local process could exhaust
/// daemon resources by opening many idle connections.
#[derive(Debug, Clone, Deserialize)]
pub struct ServerConfig {
    /// Maximum concurrent connections accepted at one time.
    /// Reached → new connections are accepted-then-closed
    /// immediately so the client sees a fast EOF rather than
    /// queuing indefinitely. Default 64 — generous for typical
    /// single-user use (one shell × handful of classify calls
    /// in flight) and tight enough that a runaway client can't
    /// peg the daemon. Values above a few hundred meaningfully
    /// weaken the DoS bound; values of 0 are clamped to 1 at
    /// startup with a stderr warning.
    #[serde(default = "default_max_concurrent_connections")]
    pub max_concurrent_connections: usize,
    /// Per-connection read timeout in seconds. An idle client
    /// holding a connection without sending any bytes is
    /// disconnected after this many seconds. Default 30 —
    /// well past a healthy classify round-trip (sub-millisecond
    /// to single-digit milliseconds) and short enough that a
    /// silent client can't squat on a handler thread forever.
    /// Set to 0 to disable.
    #[serde(default = "default_idle_read_timeout_secs")]
    pub idle_read_timeout_secs: u64,
}

fn default_max_concurrent_connections() -> usize {
    64
}
fn default_idle_read_timeout_secs() -> u64 {
    30
}

impl Default for ServerConfig {
    fn default() -> Self {
        ServerConfig {
            max_concurrent_connections: default_max_concurrent_connections(),
            idle_read_timeout_secs: default_idle_read_timeout_secs(),
        }
    }
}

#[derive(Debug, Default, Clone, Deserialize)]
pub struct AccumulatorConfig {
    /// V2-J Phase 2: auto-`Block` threshold. When the combined
    /// confidence of multiple Tier-1 + Tier-2 signals reaches
    /// this value AND at least 2 distinct signals fired, the
    /// classifier escalates the verdict from `Warn` to `Block`.
    /// `Block` means atty refuses the command outright instead
    /// of prompting the user, so this is a load-bearing policy
    /// knob — default `None` keeps the conservative "always
    /// prompt" behaviour.
    ///
    /// Recommended values when opting in:
    /// - `0.95`: requires ≥ 5 atoms OR an atom + a high-conf
    ///   regex/SLM signal. Low false-positive risk; some legit
    ///   scripted runs may still trip and get refused.
    /// - `0.99`: practically needs 8+ atoms or multiple high-
    ///   confidence rules. Very low false-positive risk; only
    ///   the most signal-saturated commands auto-block.
    ///
    /// The minimum-hit-count guard (≥ 2 distinct signals) is
    /// non-configurable — a single regex hit at 1.0 confidence
    /// always stays a `Warn`, because we want users to retain
    /// the [y]/[t]/cancel choice for unambiguous-but-legitimate
    /// shapes like `curl … | sh` (the canonical install-script
    /// pattern).
    ///
    /// Validation happens at classifier construction, not here:
    /// `Classifier::with_block_threshold` accepts only
    /// `(WARN_THRESHOLD, 1.0]`, finite. Out-of-range values
    /// degrade to `None` with a stderr warning at daemon start
    /// — TOML deserialization itself only enforces "must be a
    /// number," so e.g. `block_threshold = 2.0` parses fine and
    /// is then rejected at runtime.
    #[serde(default)]
    pub block_threshold: Option<f32>,
}

#[derive(Debug, Default, Clone, Deserialize)]
pub struct Tier2Config {
    /// `stub` / `heuristic` / `onnx`. CLI `--tier2` wins when set;
    /// otherwise this field is honored; otherwise the default is
    /// `stub`. Validated at startup — an invalid value here fails
    /// the daemon load (matches the explicit-config posture from
    /// `--config`).
    #[serde(default)]
    pub backend: Option<String>,

    /// Sub-table populated only when backend = "onnx". Keeping
    /// the ONNX-specific knobs nested keeps `[tier2]` tidy for
    /// future backends (`[tier2.transformer]`, `[tier2.tract]`
    /// etc.).
    #[serde(default)]
    pub onnx: OnnxConfig,
}

#[derive(Debug, Clone, Deserialize)]
#[cfg_attr(not(feature = "tier2-onnx"), allow(dead_code))]
pub struct OnnxConfig {
    /// Model selector — defaults to `securebert2` because it's
    /// the smaller, faster option for the same Tier-2 verdict
    /// quality (per Gemini's review). `qwen-coder` swaps to the
    /// code-native classifier when the user has already curated
    /// a Qwen2.5-Coder-INT8 fine-tune.
    #[serde(default = "default_model")]
    pub model: String,

    /// Absolute path to the ONNX file. Empty = backend reports
    /// "model not configured" at attach time; daemon falls back
    /// to Heuristic + warns.
    #[serde(default)]
    pub model_path: String,

    /// Absolute path to the HuggingFace `tokenizer.json`.
    #[serde(default)]
    pub tokenizer_path: String,

    /// Max input tokens. SecureBERT 2.0 (ModernBERT base) handles
    /// 1024 natively; Qwen2.5-Coder handles 4096+. Longer
    /// commands are truncated at the LEFT (the right side is
    /// typically the payload).
    #[serde(default = "default_max_tokens")]
    pub max_tokens: usize,

    /// Softmax threshold above which we issue a Warn verdict.
    /// Tier-2 reports Safe when below this; Warn between this
    /// and `block_threshold`; Block above. Tune per model
    /// calibration.
    #[serde(default = "default_warn_threshold")]
    pub warn_threshold: f32,

    /// Softmax threshold for Block. Should be ≥ warn_threshold.
    #[serde(default = "default_block_threshold")]
    pub block_threshold: f32,
}

impl Default for OnnxConfig {
    fn default() -> Self {
        Self {
            model: default_model(),
            model_path: String::new(),
            tokenizer_path: String::new(),
            max_tokens: default_max_tokens(),
            warn_threshold: default_warn_threshold(),
            block_threshold: default_block_threshold(),
        }
    }
}

fn default_model() -> String {
    "securebert2".into()
}
fn default_max_tokens() -> usize {
    1024
}
fn default_warn_threshold() -> f32 {
    0.5
}
fn default_block_threshold() -> f32 {
    0.85
}

#[derive(Debug)]
#[cfg_attr(not(feature = "tier2-onnx"), allow(dead_code))]
pub enum LoadError {
    Io(std::io::Error),
    Parse(String),
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LoadError::Io(e) => write!(f, "config read failed: {e}"),
            LoadError::Parse(e) => write!(f, "config parse failed: {e}"),
        }
    }
}

impl std::error::Error for LoadError {}

#[cfg(feature = "tier2-onnx")]
pub fn load(path: &Path) -> Result<Config, LoadError> {
    let text = std::fs::read_to_string(path).map_err(LoadError::Io)?;
    toml::from_str(&text).map_err(|e| LoadError::Parse(e.to_string()))
}

/// Stub for builds without the `tier2-onnx` feature.
///
/// TOML parsing is gated behind `tier2-onnx`; this stub deliberately
/// does NOT parse the file even when the `toml` crate is in the dep
/// tree via another feature (e.g. `atoms-fetch`) — keeping the
/// parsing surface tied to a single feature flag.
///
/// The stub still performs the file read so the I/O failure posture
/// is identical to the feature-on build: an unreadable `--config
/// <path>` is a hard error in both flavors. A readable file always
/// returns `Config::default()` regardless of contents.
#[cfg(not(feature = "tier2-onnx"))]
pub fn load(path: &Path) -> Result<Config, LoadError> {
    std::fs::read_to_string(path).map_err(LoadError::Io)?;
    Ok(Config::default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(feature = "tier2-onnx")]
    #[test]
    fn parses_complete_tier2_onnx_block() {
        let src = r#"
[tier2]
backend = "onnx"

[tier2.onnx]
model = "qwen-coder"
model_path = "/var/lib/atty-guard/qwen.onnx"
tokenizer_path = "/var/lib/atty-guard/qwen-tokenizer.json"
max_tokens = 4096
warn_threshold = 0.45
block_threshold = 0.9
"#;
        let cfg: Config = toml::from_str(src).unwrap();
        assert_eq!(cfg.tier2.backend.as_deref(), Some("onnx"));
        assert_eq!(cfg.tier2.onnx.model, "qwen-coder");
        assert_eq!(cfg.tier2.onnx.max_tokens, 4096);
        assert!((cfg.tier2.onnx.block_threshold - 0.9).abs() < 1e-6);
    }

    #[cfg(feature = "tier2-onnx")]
    #[test]
    fn empty_config_yields_defaults() {
        let cfg: Config = toml::from_str("").unwrap();
        assert_eq!(cfg.tier2.onnx.model, "securebert2");
        assert_eq!(cfg.tier2.onnx.max_tokens, 1024);
    }

    #[cfg(feature = "tier2-onnx")]
    #[test]
    fn missing_onnx_subtable_keeps_defaults() {
        let cfg: Config = toml::from_str("[tier2]\nbackend = \"heuristic\"").unwrap();
        assert_eq!(cfg.tier2.backend.as_deref(), Some("heuristic"));
        assert_eq!(cfg.tier2.onnx.model, "securebert2");
    }

    #[cfg(not(feature = "tier2-onnx"))]
    #[test]
    fn no_feature_load_readable_file_returns_defaults() {
        // Stub builds still perform the I/O so the failure posture
        // matches the feature-on path; on a readable file the
        // result is always `Config::default()` since the stub
        // ignores TOML content (no parser wired through this path
        // even when `toml` is present via another feature like
        // `atoms-fetch`).
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        use std::io::Write as _;
        tmp.write_all(b"anything = \"ignored\"").unwrap();
        let cfg = load(tmp.path()).expect("readable file should succeed");
        assert_eq!(cfg.tier2.onnx.model, "securebert2");
    }

    #[cfg(not(feature = "tier2-onnx"))]
    #[test]
    fn no_feature_load_missing_file_errors() {
        // Stub I/O failure parity: missing path → LoadError::Io,
        // same as the feature-on build. Without this the explicit-
        // --config fail-closed posture only applied to tier2-onnx
        // builds, defeating it on default builds.
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("does-not-exist.toml");
        assert!(!missing.exists());
        let cfg = load(&missing);
        assert!(cfg.is_err(), "missing path should not succeed");
    }
}
