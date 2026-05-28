"""Non-blocking PTY-read helpers for sandbox scenarios.

`ptyprocess.PtyProcess.read()` uses blocking `os.read`, which hangs
when the child has nothing to emit — fine for streaming-output
tests (smoke's `echo` floods the pipe), broken for any flow that
asks "did the child produce X within budget?" The select-based
read below polls the PTY fd and exits cleanly on deadline.
"""
from __future__ import annotations

import os
import select
import time


def read_until(proc, marker: bytes, timeout: float,
               sink: bytearray) -> bool:
    """Read from `proc.fd` until `marker` appears in `sink` OR
    `timeout` seconds elapse. Returns True on match.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        remaining = max(deadline - time.time(), 0.05)
        r, _, _ = select.select([proc.fd], [], [], min(remaining, 0.1))
        if r:
            try:
                chunk = os.read(proc.fd, 4096)
            except OSError:
                return marker in bytes(sink)
            if not chunk:
                return marker in bytes(sink)
            sink.extend(chunk)
            if marker in bytes(sink):
                return True
    return marker in bytes(sink)


def drain(proc, timeout: float, sink: bytearray) -> None:
    """Drain whatever's pending up to `timeout` seconds. Doesn't
    fail if no data arrives — useful for `let the picture settle`
    pauses after sending a command.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        remaining = max(deadline - time.time(), 0.05)
        r, _, _ = select.select([proc.fd], [], [], min(remaining, 0.1))
        if not r:
            continue
        try:
            chunk = os.read(proc.fd, 4096)
        except OSError:
            return
        if not chunk:
            return
        sink.extend(chunk)
