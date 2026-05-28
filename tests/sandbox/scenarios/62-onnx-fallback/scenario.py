#!/usr/bin/env python3
"""62-onnx-fallback — explicit Tier-2 ONNX fail-closed posture.

Pins the production behaviour PR #316 / issue #026 codified:

  - An EXPLICIT operator request (CLI `--tier2 onnx` or config
    `[tier2] backend = "onnx"`) with a missing/broken model file
    MUST refuse to start. Silent degradation to stub would hide
    a misconfiguration and let the daemon answer classify
    requests with a weaker classifier than the operator
    intended.

  - The DEFAULT path (no operator request) keeps the best-effort
    fallback — fresh installs shouldn't refuse to start because
    a model file isn't there yet.

Failure modes this catches:
  - Daemon silently degrades on explicit + missing model (the
    #026 regression we keep guarding against).
  - Daemon refuses to start with NO config (over-eager
    fail-closed leaking into the default path).
  - Error message no longer includes the requested backend +
    source (`tier2=onnx requested from config but backend load
    failed`) so operators can't tell *what* broke.
"""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, "/sandbox")
from lib.daemon import Daemon  # noqa: E402


CONFIG_DIR = Path("/etc/atty-guard")
BAD_CONFIG = CONFIG_DIR / "onnx-bad.toml"
SOCKET = "/run/atty-guard/atty-guard.sock"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def write_bad_config() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    BAD_CONFIG.write_text(
        "[tier2]\n"
        'backend = "onnx"\n'
        "[tier2.onnx]\n"
        'model = "securebert-2.0"\n'
        'model_path = "/nonexistent/securebert.onnx"\n'
        'tokenizer_path = "/nonexistent/tokenizer.json"\n'
    )


def main() -> None:
    write_bad_config()

    # Test 1: explicit `backend = "onnx"` + missing model →
    # daemon must REFUSE to start. We can't use the Daemon
    # helper here (it asserts the socket comes up); spawn raw
    # and check the exit code + stderr.
    proc = subprocess.run(
        ["runuser", "-u", "atty", "--", "/usr/local/bin/atty-guard",
         "--socket", SOCKET, "--config", str(BAD_CONFIG), "-v", "1"],
        capture_output=True,
        timeout=10,
    )
    if proc.returncode == 0:
        fail("daemon started with explicit onnx + missing model — "
             "expected fail-closed exit.\n"
             f"stderr: {proc.stderr.decode()!r}")
    err = proc.stderr.decode()
    # Both the backend name AND the source ("config") must be in
    # the error message so operators can tell what they configured
    # vs what failed.
    if "tier2=onnx" not in err or "backend load failed" not in err:
        fail("error message missing the structured "
             f"'tier2=onnx ... backend load failed' shape:\n{err}")
    if "config" not in err:
        fail(f"error message doesn't name the source (config):\n{err}")

    # Test 2: default path (no --config) → daemon starts fine
    # with stub backend. The fail-closed posture must NOT bleed
    # into the no-operator-request case.
    with Daemon(verbosity=1) as d:
        # Daemon emits `tier2=stub effective=stub (source=default)`
        # before opening the UDS — by the time __enter__ returns
        # the log line is on disk.
        time.sleep(0.2)  # cushion for stderr flush
        log = d.read_log()
        if "source=default" not in log:
            fail(f"default path didn't log source=default:\n{log}")
        if "effective=stub" not in log:
            fail(f"default path didn't degrade to stub:\n{log}")

    print("PASS: 62-onnx-fallback")


if __name__ == "__main__":
    main()
