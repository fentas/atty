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
    /// `stub` / `heuristic` / `onnx`. CLI `--tier2` flag wins
    /// when both are set so the operator can override the file
    /// without editing it — that override path is the reason main.rs
    /// doesn't consume this field directly. `#[allow(dead_code)]`
    /// because the file-defaults path is queued for a follow-up:
    /// clap currently supplies a default (`"stub"`) so main.rs
    /// can't distinguish "CLI omitted, use file" vs "CLI explicitly
    /// passed stub" without switching to `value_source()`. Until
    /// that lands, this field stays inert.
    #[allow(dead_code)]
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

/// Stub for builds without the `tier2-onnx` feature: no TOML
/// parser is in the dep tree, so we accept the `--config` flag
/// but return the defaults. Lets the daemon stay launchable from
/// a systemd unit that hardcodes `--config /etc/atty-guard.toml`
/// regardless of which feature set the operator built with.
#[cfg(not(feature = "tier2-onnx"))]
pub fn load(_path: &Path) -> Result<Config, LoadError> {
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

    #[test]
    fn no_feature_load_returns_defaults() {
        // On builds without `tier2-onnx`, `load` is a no-op that
        // returns defaults. Pass any path; nothing is read.
        let cfg = load(Path::new("/nonexistent.toml"));
        #[cfg(not(feature = "tier2-onnx"))]
        {
            assert!(cfg.is_ok());
            let c = cfg.unwrap();
            assert_eq!(c.tier2.onnx.model, "securebert2");
        }
        // On feature builds, /nonexistent → IO error. Drop the
        // result to keep the test trivially passing in both modes.
        let _ = cfg;
    }
}
