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

import re
import subprocess
import sys
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


# Single anchored regex over the full error prefix. Loose
# substring matching (the original three-fragment check) would
# false-pass if `--config` parse rejection emitted the
# unrelated `--config /path rejected …` line (which contains
# "config" but not the structured tier2 prefix).
_FAIL_CLOSED_RE = re.compile(
    r"^atty-guard: tier2=onnx requested from (cli|config) "
    r"but backend load failed:",
    re.MULTILINE,
)


def assert_fail_closed(argv: list[str], request_source: str) -> None:
    """Run atty-guard with `argv`, assert it exits non-zero AND
    emits the structured fail-closed error with the expected
    source attribution.
    """
    proc = subprocess.run(
        ["runuser", "-u", "atty", "--", "/usr/local/bin/atty-guard",
         "--socket", SOCKET, "-v", "1", *argv],
        capture_output=True,
        timeout=10,
    )
    if proc.returncode == 0:
        fail(f"daemon started with explicit onnx + missing model "
             f"({request_source}); expected fail-closed exit.\n"
             f"stderr: {proc.stderr.decode()!r}")
    err = proc.stderr.decode()
    match = _FAIL_CLOSED_RE.search(err)
    if not match or match.group(1) != request_source:
        fail(f"missing fail-closed signature (from={request_source}). "
             f"stderr:\n{err}")


def main() -> None:
    write_bad_config()

    # Test 1: config-arm fail-closed.
    assert_fail_closed(["--config", str(BAD_CONFIG)], "config")

    # Test 2: cli-arm fail-closed. `--tier2 onnx` with no
    # `--config` uses the default OnnxConfig (empty model_path),
    # which fails backend construction. Catches a regression
    # where the CLI path silently degrades while the config path
    # stays strict (or vice versa).
    assert_fail_closed(["--tier2", "onnx"], "cli")

    # Test 3: default path (no operator request) keeps the
    # legacy degrade-to-stub fallback. wait_socket returning
    # True already implies the stderr log is flushed — the
    # eprintln + UDS bind are sequential in main.rs.
    with Daemon(verbosity=1) as d:
        log = d.read_log()
        if "source=default" not in log:
            fail(f"default path didn't log source=default:\n{log}")
        if "effective=stub" not in log:
            fail(f"default path didn't degrade to stub:\n{log}")

    print("PASS: 62-onnx-fallback")


if __name__ == "__main__":
    main()
