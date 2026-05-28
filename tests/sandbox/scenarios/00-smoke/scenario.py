#!/usr/bin/env python3
"""00-smoke — framework liveness check.

Daemon boots under atty user; UDS appears; alice can drive an atty
proxy through a shell command via a printed-marker idiom. Fails
loudly if the Dockerfile / runner.py / binary-staging pipeline
regresses — that's its only job. Real behaviour coverage lives in
#330+.
"""
from __future__ import annotations

import os
import re
import sys
import time

sys.path.insert(0, "/sandbox")
from lib.daemon import Daemon  # noqa: E402
from lib.pty import read_until  # noqa: E402

import ptyprocess  # noqa: E402


BEGIN = "BEGIN-sandbox-smoke-7f3c"
END = "END-sandbox-smoke-7f3c"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def drive_atty() -> str:
    # runuser resets the env of the target user, so PS1/TERM/HOME
    # in subprocess env= would never reach atty. Stage them via
    # `bash -c 'export …; exec atty …'` inside the user shell so
    # they survive the user switch.
    inner = (
        "export PS1='\\$ ' TERM=xterm-256color HOME=/home/alice; "
        "exec /usr/local/bin/atty bash --noprofile --norc"
    )
    cmd = f"printf '%s %s\\n' {BEGIN} {END}"
    proc = ptyprocess.PtyProcess.spawn(
        ["runuser", "-u", "alice", "--", "bash", "-c", inner],
        dimensions=(24, 80),
    )

    captured = bytearray()
    read_until(proc, b"$ ", timeout=4.0, sink=captured)
    proc.write(f"{cmd}\r".encode())
    if not read_until(proc, f"{BEGIN} {END}".encode(), timeout=4.0,
                      sink=captured):
        try:
            proc.kill(9)
        except ptyprocess.PtyProcessError:
            pass
        return bytes(captured).decode("utf-8", errors="replace")
    proc.write(b"exit\r")

    # Bounded drain so a hung exit surfaces as a scenario failure
    # rather than tripping the runner's 120s container timeout.
    from lib.pty import drain
    drain(proc, timeout=3.0, sink=captured)
    if proc.isalive():
        try:
            proc.kill(9)
        except ptyprocess.PtyProcessError:
            pass

    return bytes(captured).decode("utf-8", errors="replace")


# atty-guard prefixes every line with `atty-guard:`; failure lines
# also carry `error:`, `failed`, or `rejected` (per main.rs eprintln
# sites). Anchoring to line start rules out substring false-positives
# in benign messages that mention these words mid-line. The panic
# branch catches catastrophic Rust runtime aborts (no daemon prefix).
_DAEMON_FAIL_RE = re.compile(
    r"^(?:atty-guard:.*(?:error:|failed|rejected)|thread .*panicked|panic:|fatal:)",
    re.MULTILINE,
)


def main() -> None:
    with Daemon() as daemon:
        if not daemon.socket_ready():
            fail("daemon socket missing after startup")

        out = drive_atty()
        if f"{BEGIN} {END}" not in out:
            fail(f"atty did not propagate child output. captured={out!r}")

        log_text = daemon.read_log()
        match = _DAEMON_FAIL_RE.search(log_text)
        if match:
            daemon.dump_log()
            fail(f"daemon logged failure signature: {match.group(0)!r}")

    print("PASS: 00-smoke")


if __name__ == "__main__":
    main()
