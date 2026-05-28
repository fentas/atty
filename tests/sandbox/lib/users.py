"""User-switching helpers for sandbox scenarios.

`runuser` is the canonical no-PAM-tty user switch; mirrors what the
production install does (atty is a SUID-free system and never needs
to elevate). UIDs match the base image (Dockerfile.base).
"""
from __future__ import annotations

import subprocess
from typing import Sequence


UID_ALICE = 1001
UID_BOB = 1002


def as_user(user: str, argv: Sequence[str], *, capture: bool = True,
            check: bool = False, timeout: float = 30.0,
            input: bytes | None = None) -> subprocess.CompletedProcess:
    """Run `argv` as `user` via runuser. Returns CompletedProcess.

    `capture=True` is the default since most assertions look at
    stdout/stderr; flip to False for fire-and-forget background work.
    """
    cmd = ["runuser", "-u", user, "--", *argv]
    return subprocess.run(
        cmd,
        capture_output=capture,
        check=check,
        timeout=timeout,
        input=input,
    )
