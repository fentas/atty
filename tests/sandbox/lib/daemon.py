"""Daemon lifecycle helper for sandbox scenarios.

Starts atty-guard as a background process under the `atty` user
(matching production posture — the daemon owns its own state-dir
permissions). Tears down via the context-manager protocol so a
scenario that throws still leaves a clean container.
"""
from __future__ import annotations

import os
import signal
import subprocess
import time
from pathlib import Path


DEFAULT_SOCKET = "/run/atty-guard/atty-guard.sock"


class Daemon:
    """Context manager wrapping a backgrounded atty-guard process.

    Usage:
        with Daemon() as d:
            assert d.socket_ready()
            # … scenario body …
    """

    def __init__(
        self,
        socket: str = DEFAULT_SOCKET,
        verbosity: int = 1,
        extra_args: list[str] | None = None,
    ) -> None:
        self.socket = socket
        self.verbosity = verbosity
        self.extra_args = extra_args or []
        self.proc: subprocess.Popen | None = None
        # Capture daemon stderr so scenarios can grep it for the
        # journald-style lines the daemon emits.
        self.stderr_log = Path("/tmp/atty-guard.stderr.log")

    def __enter__(self) -> "Daemon":
        # Run as the `atty` user via `runuser`. The daemon refuses
        # to load atom files that aren't atty-owned (production
        # posture); running as root would skip that gate and let
        # the sandbox drift from real behaviour.
        cmd = [
            "runuser",
            "-u",
            "atty",
            "--",
            "/usr/local/bin/atty-guard",
            "--socket",
            self.socket,
            "-v",
            str(self.verbosity),
            *self.extra_args,
        ]
        log_fd = open(self.stderr_log, "w")
        self.proc = subprocess.Popen(
            cmd,
            stdout=log_fd,
            stderr=subprocess.STDOUT,
            preexec_fn=os.setsid,
        )
        if not self.wait_socket(timeout=5.0):
            self._dump_log()
            raise RuntimeError(f"daemon socket {self.socket} not ready within 5s")
        return self

    def __exit__(self, *exc) -> None:
        if self.proc is not None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
                self.proc.wait(timeout=3.0)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def wait_socket(self, timeout: float = 5.0) -> bool:
        """Spin until the UDS exists + is readable, or timeout."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if os.path.exists(self.socket):
                return True
            time.sleep(0.05)
        return False

    def socket_ready(self) -> bool:
        return os.path.exists(self.socket)

    def log_contains(self, needle: str) -> bool:
        """Substring search over captured daemon stderr."""
        try:
            return needle in self.stderr_log.read_text()
        except FileNotFoundError:
            return False

    def _dump_log(self) -> None:
        try:
            print("---- atty-guard log ----")
            print(self.stderr_log.read_text())
            print("---- end log ----")
        except FileNotFoundError:
            pass
