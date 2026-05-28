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
    # printf wraps the echo with BEGIN/END markers so we can grep
    # for the *executed* output, not the PTY's echo of the typed
    # command (which would pass for the wrong reason).
    cmd = f"printf '%s %s\\n' {BEGIN} {END}"
    proc = ptyprocess.PtyProcess.spawn(
        [
            "runuser",
            "-u",
            "alice",
            "--",
            "/usr/local/bin/atty",
            "bash",
            "--noprofile",
            "--norc",
        ],
        env={
            **os.environ,
            "PS1": r"\$ ",
            "TERM": "xterm-256color",
            "HOME": "/home/alice",
        },
        dimensions=(24, 80),
    )

    captured = bytearray()
    read_until(proc, b"$ ", timeout=4.0, sink=captured)
    proc.write(f"{cmd}\r".encode())
    if not read_until(proc, f"{BEGIN} {END}".encode(), timeout=4.0, sink=captured):
        proc.write(b"exit\r")
        return bytes(captured).decode("utf-8", errors="replace")
    proc.write(b"exit\r")

    try:
        proc.wait()
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


def main() -> None:
    with Daemon() as daemon:
        if not daemon.socket_ready():
            fail("daemon socket missing after startup")

        out = drive_atty()
        if f"{BEGIN} {END}" not in out:
            fail(f"atty did not propagate child output. captured={out!r}")

        # Daemon emits `atty-guard: <level> — <reason>` style lines;
        # `error:` / `failed` / `rejected` cover the real failure
        # signatures in atty-guard/src/main.rs and server.rs.
        for needle in ("error:", "failed", "rejected"):
            if daemon.log_contains(needle):
                daemon._dump_log()
                fail(f"daemon logged {needle!r} during smoke run")

    print("PASS: 00-smoke")


if __name__ == "__main__":
    main()
