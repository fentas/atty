# security guard — Tier-2 SLM

Where the ONNX classifier lives, what model files to drop in, and how the user-side TOML pins everything together. V2-C of the security-guard roadmap (see `security-guard-design.md` for the wider context).

## Supported models

| Model | Where it shines | Size (INT8) | Context | Source |
|-------|-----------------|------------:|--------:|--------|
| **SecureBERT 2.0** (default) | Domain-adapted cybersecurity + shell. ModernBERT base means the tokeniser **preserves shell metachars**, fixing the original SecureBERT's biggest weakness. | ~150 MB | 1024 tokens | Cisco AI — search `securebert` on Hugging Face. |
| **Qwen2.5-Coder-1.5B** (or 3B) | Code-native — better at multi-layer bash injections, Python `-c`, npm postinstall logic. Fine-tune with a 3-class classification head over `[safe, suspicious, harmful]`. | ~800 MB / ~1.7 GB | 32k tokens | Hugging Face `Qwen/Qwen2.5-Coder-1.5B-Instruct` + your fine-tune. |

Both export to ONNX via Hugging Face's `optimum`:

```sh
optimum-cli export onnx \
    --model Qwen/Qwen2.5-Coder-1.5B \
    --task text-classification \
    qwen-classifier-onnx/

# Quantise to INT8 for the inline budget.
python -m onnxruntime.quantization.quantize_dynamic \
    qwen-classifier-onnx/model.onnx \
    qwen-classifier-onnx/model-int8.onnx
```

The output directory carries the `tokenizer.json` you point `tokenizer_path` at.

## Config

```toml
# /etc/atty-guard.toml  (or anywhere — path passed via --config)

[tier2]
backend = "onnx"          # stub / heuristic / onnx

[tier2.onnx]
# SecureBERT 2.0 (default) — fast, small, syntax-preserving tokeniser.
model           = "securebert2"
model_path      = "/var/lib/atty-guard/models/securebert2-int8.onnx"
tokenizer_path  = "/var/lib/atty-guard/models/securebert2-tokenizer.json"
max_tokens      = 1024
warn_threshold  = 0.50
block_threshold = 0.85
```

Switch to Qwen2.5-Coder by changing `model`, the two paths, and `max_tokens`:

```toml
[tier2.onnx]
model           = "qwen-coder"
model_path      = "/var/lib/atty-guard/models/qwen-coder-int8.onnx"
tokenizer_path  = "/var/lib/atty-guard/models/qwen-coder-tokenizer.json"
max_tokens      = 4096
warn_threshold  = 0.55
block_threshold = 0.88
```

`atty-guard` reads the config once at startup. SIGHUP-reload is V2-F follow-up.

## CLI

```sh
atty-guard \
    --tier2 onnx \
    --config /etc/atty-guard.toml \
    -v 1
```

Without `--config`, the daemon starts with built-in defaults (Stub backend). With `--config <path>`, a load failure is a hard error — fix the config or omit `--config` to use defaults intentionally. When config + onnx are wired but OnnxBackend construction itself fails (model file missing, tokenizer parse error, etc.), the daemon logs a clear message and falls back to `StubBackend` — atty-guard still starts, just without SLM-grade Tier-2.

## Runtime: pure-Rust tract, no C deps

We use `tract-onnx` instead of `ort`. Reasoning:

- **No system dep on `libonnxruntime.so`.** `pacman -S onnxruntime` isn't always available; `ort`'s `load-dynamic` flow needs that lib at runtime.
- **No bindgen churn.** The `ort` 2.0 release candidates flip ABI assumptions almost weekly; we hit `unknown field SessionOptionsAppendExecutionProvider_VitisAI` building against the local Arch onnxruntime headers.
- **Pure Rust.** tract is in the `pyke-ai/tract` lineage from Sonos, MIT-licensed, designed for inference-only workloads exactly like ours.

Trade-off: tract is slightly slower than the C++ onnxruntime for the same model (~10-50 ms typical for SecureBERT-2.0-INT8 on a modern CPU vs ~5-15 ms for ort). Well inside our 50 ms UDS timeout budget; if it ever becomes the bottleneck we can swap to `ort` behind a new `tier2-onnx-ort` Cargo feature without touching the trait surface.

## Threshold calibration

The defaults (Warn = 0.50, Block = 0.85) work as a starting point for SecureBERT 2.0. Qwen2.5-Coder tends to give sharper probabilities — tune Warn down to 0.45 and Block up to 0.90 if your fine-tune has clean training data. **Always calibrate on a held-out benchmark before bumping Block past 0.80** — block-tier verdicts make atty-guard return `Verdict::Block` which atty surfaces as a hard refuse-and-Ctrl+U.

## ANSI sanitisation

Per Gemini's review note, the typed line is passed through `sanitize::sanitize_for_classification` before tokenisation — strips CSI escapes, OSC title-setters, BEL/BS/NUL controls. Unicode (CJK, emoji) survives untouched. Tests cover the alt-screen entry/exit case + the OSC `\x1b\\` terminator. See `atty-guard/src/sanitize.rs`.

## What this PR doesn't do

- **Pre-trained model bundles.** We don't ship a `securebert2-int8.onnx` because it's 150 MB and the licensing of a community fine-tune isn't our story to tell. README points at the upstream HF model + the `optimum` export command — users provision once.
- **Hot reload.** Restart the daemon to pick up a new model. SIGHUP-reload + the bundle update protocol from `security-guard-updates.md` close that gap in V2-F.
- **GPU acceleration.** tract is CPU-only by design. For a workload that fires per-Enter at human typing rates, CPU is the right answer — no GPU sharing semantics to argue with.
