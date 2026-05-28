#!/usr/bin/env python3
"""00-smoke — end-to-end sanity check.

Verifies the framework is wired correctly:
- atty-guard starts cleanly under the `atty` user.
- /run/atty-guard/atty-guard.sock exists + is reachable.
- An atty proxy run as `alice` connects to the daemon and runs a
  simple shell command.
- No daemon error lines in the captured stderr.

Catches nothing substantive on its own — that's #330's job. This
scenario's role is to fail loudly if the Dockerfile / runner.py /
binary-staging pipeline regresses.
"""
from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, "/sandbox")
from lib.daemon import Daemon  # noqa: E402

import ptyprocess  # noqa: E402


SENTINEL = "sandbox-smoke-ok-7f3c"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def drive_atty() -> str:
    """Spawn atty inside a PTY as alice, type a single command, exit."""
    # atty refuses non-TTY stdio (see src/main.zig), so subprocess.run
    # with pipes won't work — spawn under ptyprocess instead.
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
    deadline = time.time() + 8.0

    def read_until(marker: bytes, timeout: float) -> bool:
        while time.time() < timeout:
            try:
                chunk = proc.read(4096)
            except EOFError:
                return marker in bytes(captured)
            if chunk:
                captured.extend(chunk)
                if marker in bytes(captured):
                    return True
            else:
                time.sleep(0.05)
        return marker in bytes(captured)

    # Wait for the prompt to settle, then issue the command.
    read_until(b"$ ", deadline)
    proc.write(f"echo {SENTINEL}\r".encode())
    read_until(SENTINEL.encode(), deadline)
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
        if SENTINEL not in out:
            fail(f"atty did not propagate child output. captured={out!r}")

        if daemon.log_contains("error:") or daemon.log_contains("ERROR"):
            daemon._dump_log()
            fail("daemon logged an error during smoke run")

    print("PASS: 00-smoke")


if __name__ == "__main__":
    main()
