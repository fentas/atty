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

import ptyprocess  # noqa: E402


BEGIN = "BEGIN-sandbox-smoke-7f3c"
END = "END-sandbox-smoke-7f3c"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def read_until(proc: "ptyprocess.PtyProcess", marker: bytes, timeout: float,
               sink: bytearray) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            chunk = proc.read(4096)
        except EOFError:
            return marker in bytes(sink)
        if chunk:
            sink.extend(chunk)
            if marker in bytes(sink):
                return True
        else:
            time.sleep(0.05)
    return marker in bytes(sink)


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
    if not read_until(proc, f"{BEGIN} {END}".encode(), timeout=4.0, sink=captured):
        try:
            proc.kill(9)
        except ptyprocess.PtyProcessError:
            pass
        return bytes(captured).decode("utf-8", errors="replace")
    proc.write(b"exit\r")

    # Bounded wait so a hung exit surfaces as a scenario failure
    # rather than tripping the runner's 120s container timeout.
    drain_deadline = time.time() + 3.0
    while time.time() < drain_deadline:
        if not proc.isalive():
            break
        try:
            chunk = proc.read(4096)
        except EOFError:
            break
        if chunk:
            captured.extend(chunk)
        else:
            time.sleep(0.05)
    if proc.isalive():
        try:
            proc.kill(9)
        except ptyprocess.PtyProcessError:
            pass
    try:
        while True:
            chunk = proc.read(4096)
            if not chunk:
                break
            captured.extend(chunk)
    except EOFError:
        pass

    return bytes(captured).decode("utf-8", errors="replace")


# Daemon log lines look like `<ts> <level> atty-guard: <message>`;
# line-anchored regex avoids substring false positives like
# "no error:" or "ERROR_NONE" in a future message.
_DAEMON_FAIL_RE = re.compile(
    r"^.*(?:error:|failed|rejected|ERROR\b)", re.MULTILINE | re.IGNORECASE
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
