"""Daemon lifecycle helper for sandbox scenarios.

Starts atty-guard under the `atty` user (matching production —
the daemon refuses to load atom files that aren't atty-owned, so
running as root would silently skip a real gate).
"""
from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path


DEFAULT_SOCKET = "/run/atty-guard/atty-guard.sock"


class Daemon:
    """Context manager wrapping a backgrounded atty-guard process.

    Usage:
        with Daemon() as d:
            assert d.socket_ready()
            # … scenario body …

    Per-scenario customisation:
        with Daemon(config_path=Path("/sandbox/fixtures/strict.toml"),
                    env={"ATTY_GUARD_BLOCK_THRESHOLD": "3"},
                    extra_args=["--max-cmd-bytes", "4096"]) as d: …
    """

    def __init__(
        self,
        socket: str = DEFAULT_SOCKET,
        verbosity: int = 1,
        extra_args: list[str] | None = None,
        config_path: Path | None = None,
        env: dict[str, str] | None = None,
    ) -> None:
        self.socket = socket
        self.verbosity = verbosity
        self.extra_args = list(extra_args or [])
        if config_path is not None:
            self.extra_args.extend(["--config", str(config_path)])
        self.env = env
        self.proc: subprocess.Popen | None = None
        # Each Daemon instance gets its own log so restart-style
        # scenarios can compare pre/post output without clobbering.
        fd, log_path = tempfile.mkstemp(prefix="atty-guard.", suffix=".log")
        os.close(fd)
        self.stderr_log = Path(log_path)

    def __enter__(self) -> "Daemon":
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
        run_env = {**os.environ, **(self.env or {})}
        log_fd = open(self.stderr_log, "w")
        self.proc = subprocess.Popen(
            cmd,
            stdout=log_fd,
            stderr=subprocess.STDOUT,
            env=run_env,
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
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if os.path.exists(self.socket):
                return True
            time.sleep(0.05)
        return False

    def socket_ready(self) -> bool:
        return os.path.exists(self.socket)

    def log_contains(self, needle: str) -> bool:
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
