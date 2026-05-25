// OnnxConfig / LoadError / OnnxBackend type definitions are
// referenced by both the feature-on impl + the no-feature stub.
// Without `tier2-onnx` they compile for API stability but never
// get constructed; silence the dead-code lint for that build only.
#![cfg_attr(not(feature = "tier2-onnx"), allow(dead_code, unused_imports))]

//! ONNX-runtime Tier-2 backend.
//!
//! Supports two model lineages via `OnnxConfig.model`:
//!   - `securebert2`  — SecureBERT 2.0 (Cisco AI, ModernBERT base,
//!                       1024-token context, ~150M params). Default.
//!                       Best fit when you want the smaller, faster
//!                       option and your training corpus is mostly
//!                       cybersecurity text + shell strings.
//!   - `qwen-coder`   — Qwen2.5-Coder-1.5B or -3B with a classification
//!                       head bolted on. Native code understanding for
//!                       Python / Node / multi-layer bash injections.
//!                       Larger memory footprint; better on weird
//!                       obfuscated shapes.
//!
//! Both export to ONNX with the SAME I/O shape after the
//! classification head:
//!   input_ids:      i64[1, seq]      — tokenised command
//!   attention_mask: i64[1, seq]      — 1 where token, 0 padding
//!   output (logits): f32[1, 3]       — [safe, suspicious, harmful]
//!
//! The atty-guard side doesn't care WHICH model — same code path
//! drives both. The config's `model` field is just naming for the
//! verdict reason + telemetry.
//!
//! Build path: `cargo build --release --features tier2-onnx`.
//! Runtime needs `libonnxruntime.so` on the loader path
//! (`pacman -S onnxruntime` / etc.).

#[cfg(feature = "tier2-onnx")]
use crate::classifier::Tier2Backend;
use crate::config::OnnxConfig;
use crate::protocol::{Category, ClassifyResult, Verdict};

#[derive(Debug)]
pub enum LoadError {
    /// Only constructed by the `#[cfg(not(feature = "tier2-onnx"))]`
    /// stub below. With the feature ON this variant is unreachable;
    /// `#[allow(dead_code)]` keeps the API uniform.
    #[allow(dead_code)]
    FeatureNotBuilt,
    ModelMissing(String),
    TokenizerMissing(String),
    InitFailed(String),
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LoadError::FeatureNotBuilt => write!(
                f,
                "atty-guard built without --features tier2-onnx — recompile with the feature on"
            ),
            LoadError::ModelMissing(p) => {
                // Empty path almost always means the operator wrote
                // `[tier2] backend = "onnx"` without a `[tier2.onnx]`
                // section; naming the missing key in the message
                // makes the fix obvious without consulting docs.
                if p.is_empty() {
                    write!(
                        f,
                        "[tier2.onnx] model_path is empty — set it (e.g. model_path = \"/var/lib/atty-guard/models/securebert2-int8.onnx\") or, under [tier2], pick a non-onnx backend (`backend = \"stub\"` or `backend = \"heuristic\"`)"
                    )
                } else {
                    write!(f, "model file not found: {p}")
                }
            }
            LoadError::TokenizerMissing(p) => {
                if p.is_empty() {
                    write!(
                        f,
                        "[tier2.onnx] tokenizer_path is empty — set it (e.g. tokenizer_path = \"/var/lib/atty-guard/models/securebert2-tokenizer.json\") or, under [tier2], pick a non-onnx backend (`backend = \"stub\"` or `backend = \"heuristic\"`)"
                    )
                } else {
                    write!(f, "tokenizer file not found: {p}")
                }
            }
            LoadError::InitFailed(d) => write!(f, "onnx init failed: {d}"),
        }
    }
}

impl std::error::Error for LoadError {}

#[cfg(not(feature = "tier2-onnx"))]
pub struct OnnxBackend;

#[cfg(not(feature = "tier2-onnx"))]
impl OnnxBackend {
    pub fn open(_cfg: &OnnxConfig) -> Result<Self, LoadError> {
        Err(LoadError::FeatureNotBuilt)
    }
}

// ===========================================================================
// Feature-on impl.

#[cfg(feature = "tier2-onnx")]
mod with_tract {
    use super::*;
    use crate::sanitize::sanitize_for_classification;
    use std::path::Path;
    use std::sync::Mutex;
    use tokenizers::Tokenizer;
    use tract_onnx::prelude::*;

    type TractModel = SimplePlan<TypedFact, Box<dyn TypedOp>, Graph<TypedFact, Box<dyn TypedOp>>>;

    /// Loaded ONNX model + tokenizer + thresholds. `Mutex<TractModel>`
    /// because tract's plan runs aren't `Sync`; the `Arc<State>`
    /// model in `server.rs` requires Sync. Lock cost is per-classify
    /// and inference dominates (~5-50 ms with tract, well within
    /// our 50 ms timeout budget atty's UDS client uses).
    pub struct OnnxBackend {
        model: Mutex<TractModel>,
        tokenizer: Tokenizer,
        max_tokens: usize,
        warn_threshold: f32,
        block_threshold: f32,
        model_name: &'static str,
    }

    impl OnnxBackend {
        pub fn open(cfg: &OnnxConfig) -> Result<Self, LoadError> {
            if cfg.model_path.is_empty() || !Path::new(&cfg.model_path).exists() {
                return Err(LoadError::ModelMissing(cfg.model_path.clone()));
            }
            if cfg.tokenizer_path.is_empty() || !Path::new(&cfg.tokenizer_path).exists() {
                return Err(LoadError::TokenizerMissing(cfg.tokenizer_path.clone()));
            }
            let tokenizer = Tokenizer::from_file(&cfg.tokenizer_path)
                .map_err(|e| LoadError::InitFailed(format!("tokenizer: {e}")))?;

            let model = tract_onnx::onnx()
                .model_for_path(&cfg.model_path)
                .map_err(|e| LoadError::InitFailed(format!("parse onnx: {e}")))?
                .into_optimized()
                .map_err(|e| LoadError::InitFailed(format!("optimize: {e}")))?
                .into_runnable()
                .map_err(|e| LoadError::InitFailed(format!("plan: {e}")))?;

            let model_name: &'static str = match cfg.model.as_str() {
                "qwen-coder" => "qwen-coder",
                _ => "securebert2",
            };

            Ok(Self {
                model: Mutex::new(model),
                tokenizer,
                max_tokens: cfg.max_tokens,
                warn_threshold: cfg.warn_threshold,
                block_threshold: cfg.block_threshold,
                model_name,
            })
        }

        fn infer_with_hint(
            &self,
            command: &str,
            hint_offset: Option<usize>,
        ) -> Result<[f32; 3], String> {
            // V2-H sliding-context-window. When an upstream Tier-1
            // matcher (AtomMatcher / regex / flagged-URL) reported
            // a localised hit, we slice [-64, +256] BYTES around the
            // start-of-match offset and tokenise ONLY that window.
            // The window is asymmetric (more after than before) on
            // purpose: payload typically follows the matched atom
            // (e.g. `nc -e <ip> <port>`, `curl -fsSL <url> | sh`).
            // Drops 3-5× tokens on long pipeline-stuffed commands;
            // the SLM still gets enough surrounding context to
            // disambiguate.
            //
            // No hint = tokenise the whole command (current
            // behaviour). Used when the Tier-2 backend is called
            // as a fallback after Tier-1 missed entirely.
            let target = if let Some(offset) = hint_offset {
                crate::sanitize::slice_context_window(command, offset, 64, 256)
            } else {
                command
            };
            let cleaned = sanitize_for_classification(target);
            let enc = self
                .tokenizer
                .encode(cleaned, true)
                .map_err(|e| format!("tokenize: {e}"))?;
            let ids = enc.get_ids();
            let mask = enc.get_attention_mask();

            // Left-truncate if too long — the right side is the
            // payload (`base64 ...`, `eval ...`); the left is
            // shell chrome.
            let start = ids.len().saturating_sub(self.max_tokens);
            let id_slice = &ids[start..];
            let mask_slice = &mask[start..];
            let seq = id_slice.len();

            let ids_i64: Vec<i64> = id_slice.iter().map(|&u| u as i64).collect();
            let mask_i64: Vec<i64> = mask_slice.iter().map(|&u| u as i64).collect();

            let input_ids = tract_ndarray::Array2::from_shape_vec((1, seq), ids_i64)
                .map_err(|e| format!("input_ids shape: {e}"))?;
            let attention_mask = tract_ndarray::Array2::from_shape_vec((1, seq), mask_i64)
                .map_err(|e| format!("attention_mask shape: {e}"))?;

            let plan = self.model.lock().expect("onnx model poisoned");
            let outputs = plan
                .run(tvec!(input_ids.into_tvalue(), attention_mask.into_tvalue()))
                .map_err(|e| format!("run: {e}"))?;

            let logits_tensor = outputs
                .into_iter()
                .next()
                .ok_or_else(|| "model returned no outputs".to_owned())?;
            let logits = logits_tensor
                .to_array_view::<f32>()
                .map_err(|e| format!("extract logits: {e}"))?;
            if logits.len() < 3 {
                return Err(format!("unexpected logits len {}", logits.len()));
            }
            // Softmax over the 3 class logits.
            let raw: [f32; 3] = [logits[0], logits[1], logits[2]];
            let max = raw.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
            let exp: [f32; 3] = [
                (raw[0] - max).exp(),
                (raw[1] - max).exp(),
                (raw[2] - max).exp(),
            ];
            let sum = exp[0] + exp[1] + exp[2];
            Ok([exp[0] / sum, exp[1] / sum, exp[2] / sum])
        }
    }

    impl Tier2Backend for OnnxBackend {
        fn name(&self) -> &'static str {
            self.model_name
        }

        fn classify(&self, command: &str, hint_offset: Option<usize>) -> Option<ClassifyResult> {
            let probs = self.infer_with_hint(command, hint_offset).ok()?;
            let p_harmful = probs[2];
            let verdict = if p_harmful >= self.block_threshold {
                Verdict::Block
            } else if p_harmful >= self.warn_threshold {
                Verdict::Warn
            } else {
                return None; // below warn → fall-through to Safe.
            };
            Some(ClassifyResult {
                verdict,
                // The ONNX backend doesn't map to a Tier-1 category;
                // surface CurlPipeSh as the "generic encoder-SLM
                // flagged something" placeholder. Future schema-2
                // could split this into a dedicated `EncoderSlm`
                // category if the trust-cache UX needs it.
                category: Category::CurlPipeSh,
                confidence: p_harmful,
                reason: format!(
                    "Tier-2 {} flagged this command (P(harmful) = {:.2})",
                    self.model_name, p_harmful
                ),
                matched: command.to_owned(),
            })
        }
    }
}

#[cfg(feature = "tier2-onnx")]
pub use with_tract::OnnxBackend;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_error_display() {
        assert!(
            format!("{}", LoadError::FeatureNotBuilt).contains("tier2-onnx"),
            "feature-not-built message must mention the flag"
        );
        assert!(format!("{}", LoadError::ModelMissing("/x.onnx".into())).contains("/x.onnx"));
        assert!(format!("{}", LoadError::TokenizerMissing("/t.json".into())).contains("/t.json"));
    }

    #[cfg(not(feature = "tier2-onnx"))]
    #[test]
    fn open_without_feature_errors_cleanly() {
        let cfg = OnnxConfig::default();
        // Avoid printing the Ok variant in the panic message (would
        // require Debug on OnnxBackend — the feature-on impl owns
        // an ort::Session which doesn't impl Debug, so we'd be
        // dancing around the type system for a never-taken branch).
        match OnnxBackend::open(&cfg) {
            Ok(_) => panic!("expected FeatureNotBuilt, got Ok"),
            Err(LoadError::FeatureNotBuilt) => {}
            Err(other) => panic!("expected FeatureNotBuilt, got {other}"),
        }
    }

    #[cfg(feature = "tier2-onnx")]
    #[test]
    fn open_with_missing_model_errors() {
        let cfg = OnnxConfig {
            model_path: "/nonexistent.onnx".into(),
            tokenizer_path: "/nonexistent.json".into(),
            ..OnnxConfig::default()
        };
        match OnnxBackend::open(&cfg) {
            Ok(_) => panic!("expected ModelMissing, got Ok"),
            Err(LoadError::ModelMissing(_)) => {}
            Err(other) => panic!("expected ModelMissing, got {other}"),
        }
    }
}
