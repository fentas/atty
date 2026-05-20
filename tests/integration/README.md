# atty integration tests

Comprehensive end-to-end coverage across the three layers:

```
atty (Zig PTY proxy)
   │  UDS / JSON-line protocol
   ▼
atty-guard (Rust sidecar)
   │
   ├── Tier-1 regex / atom classifier
   ├── Tier-2 backend: stub | heuristic | onnx (BERT) | ollama (SLM)
   ├── atom-fetcher (GTFOBins / Sigma / LOLBAS sources)
   └── eBPF LSM hooks (V2-B, behind `--features ebpf`)
```

The `zig build test` / `cargo test` suites cover each module in isolation;
this directory plugs them together and tests the FULL pipeline with a real
running daemon, real model weights (when present), and real network calls
(when allowed).

## Running

### Quick

```sh
tests/integration/run.sh quick
```

Runs the scenarios that need NO external dependencies — `stub` /
`heuristic` backends, all Tier-1 paths, V2-J accumulator math, V2-J-2
auto-Block escalation. Takes ~30 s. Always safe to run in CI.

### Full

```sh
tests/integration/run.sh full
```

Runs everything `quick` runs PLUS:

- **ONNX BERT** (`--tier2 onnx`) — needs `model.onnx` + `tokenizer.json`
  at `$ATTY_ONNX_MODEL_DIR` (default `~/.cache/atty/onnx-securebert2/`).
- **Ollama SLM** for the LLM module's dialog flow — needs `ollama serve`
  reachable at `$OLLAMA_HOST` (default `http://localhost:11434`) and a
  pulled model named `$ATTY_OLLAMA_MODEL` (default `qwen2.5-coder:1.5b`).
- **atom-fetcher network downloads** — pulls GTFOBins / SigmaHQ / LOLBAS
  tarballs from upstream. Requires outbound HTTPS.

Each section auto-detects its dependency and SKIPs cleanly when missing.

### Single scenario

```sh
tests/integration/run.sh scenario tier1_curl_pipe_sh
```

Each scenario is a self-contained bash script under `scenarios/`.

## What's covered

| Layer / feature | Scenario | External deps |
|---|---|---|
| Tier-1 curl|sh classifier | `tier1_curl_pipe_sh` | none |
| Tier-1 npm flagged-list | `tier1_npm_flagged` | none |
| Tier-1 bash -c base64 | `tier1_bash_c_base64` | none |
| Tier-1 atom matcher (V2-G) | `tier1_atom_matcher` | none |
| Tier-2 stub (Safe always) | `tier2_stub_passes_through` | none |
| Tier-2 heuristic regex | `tier2_heuristic_proc_subst` | none |
| Tier-2 ONNX BERT | `tier2_onnx_bert` | model + tokenizer files |
| Tier-2 with Ollama dialog | `llm_ollama_dialog_roundtrip` | `ollama serve` + pulled model |
| V2-J accumulator (multi-hit) | `v2j_accumulator_3_atoms` | none |
| V2-J accumulator + SLM hit | `v2j_accumulator_slm_plus_atom` | none |
| V2-J-2 auto-Block escalation | `v2j2_autoblock_threshold` | none |
| V2-J-2 single-hit guard | `v2j2_single_hit_stays_warn` | none |
| V2-J-2 range guard | `v2j2_range_guard` | none |
| **copy.fail (CVE-2026-31431) PoC shapes** | `exploit_copy_fail_shapes` | none |
| **Shai-Hulud worm attack-stage shapes** | `exploit_shai_hulud_shapes` | none |
| atty side honors `Block` | `atty_block_refuses_outright` | atty + atty-guard run together |
| atty side honors `Warn` | `atty_warn_arms_banner` | atty + atty-guard run together |
| atom-fetcher GTFOBins source | `atom_fetcher_gtfobins` | outbound HTTPS |
| atom-fetcher Sigma source | `atom_fetcher_sigma` | outbound HTTPS |
| atom-fetcher LOLBAS source | `atom_fetcher_lolbas` | outbound HTTPS |
| trust-cache survives Block | `atty_trust_cache_shortcircuit` | atty + atty-guard |

Each scenario exits non-zero on failure with a clear `FAIL:` line; pass
prints `PASS:`. The top-level runner aggregates and prints a summary.

## Adding a scenario

1. Drop a bash script into `scenarios/your_thing.sh`.
2. Source `lib/common.sh` for `start_guard`, `classify`, `expect_verdict`, etc.
3. Use `pass`/`fail` to report; return non-zero on failure.
4. Add a row to the matrix above.

The runner discovers scenarios by glob; no registration needed.

## Why a shell framework

The `zig build e2e` harness exercises atty against a faux LLM via fixture
responses. It can't easily orchestrate a real `atty-guard` daemon, talk to
Ollama, or hit upstream rule-set repos. A shell framework is the simplest
glue for that. Where unit tests can pin a behaviour they should — these
tests fill the cracks BETWEEN modules.
