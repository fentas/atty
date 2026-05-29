"""ONNX-model availability probe for sandbox scenarios.

Mirrors lib/bpf.py's posture: scenarios that need a real
SecureBERT bundle SKIP cleanly when the model file is absent
(the operator didn't set MODEL_URL when building Dockerfile.onnx)
and FAIL loudly when the model is present-but-broken.
"""
from __future__ import annotations

import sys
from pathlib import Path


MODEL_PATH = Path("/var/lib/atty-guard/models/securebert2-int8.onnx")
TOKENIZER_PATH = Path("/var/lib/atty-guard/models/securebert2-tokenizer.json")


def model_available() -> bool:
    """True iff both model + tokenizer are readable at the
    production paths the daemon's [tier2.onnx] expects."""
    try:
        return MODEL_PATH.is_file() and TOKENIZER_PATH.is_file()
    except OSError:
        return False


def skip_if_no_model(scenario_name: str) -> None:
    """Clean-skip with the provisioning hint when the model is
    absent. Same pattern as bpf.py's skip_if_no_bpf_lsm — exit 0
    so the suite stays green; the skip line shows in logs.
    """
    if not model_available():
        print(f"SKIP: {scenario_name} — SecureBERT model not "
              f"baked into image. Build Dockerfile.onnx with "
              "MODEL_URL / MODEL_SHA256 / TOKENIZER_URL / "
              "TOKENIZER_SHA256 build args pointing at your "
              "hosted bundle (or drop the files directly into "
              f"{MODEL_PATH.parent}/ for local dev).")
        sys.exit(0)
