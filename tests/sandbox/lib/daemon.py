"""Daemon lifecycle helper for sandbox scenarios.

Starts atty-guard under the `atty` user (matching production —
the daemon refuses to load atom files that aren't atty-owned, so
running as root would silently skip a real gate).
"""
from __future__ import annotations

import os
import re
import shutil
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
        # Per-instance log so restart-style scenarios can compare
        # pre/post output without clobbering.
        fd, log_path = tempfile.mkstemp(prefix="atty-guard.", suffix=".log")
        os.close(fd)
        self.stderr_log = Path(log_path)
        self._log_fd = None

    def __enter__(self) -> "Daemon":
        # eBPF runs need the daemon — running as the unprivileged `atty`
        # user — to hold CAP_BPF/CAP_PERFMON/CAP_SYS_ADMIN to load the
        # programs. In production the systemd unit grants these via
        # AmbientCapabilities; `runuser` drops process caps, so instead
        # grant them as FILE capabilities on the binary (applied on exec,
        # so the atty user gets them). Only for --ebpf-mode runs: the
        # non-eBPF scenarios run in a non-privileged container where
        # these caps aren't available to grant. `setcap` (libcap2-bin)
        # knows cap_bpf; the image's `setpriv` cap table is too old to.
        # Only file-cap the binary when setcap exists. The eBPF image
        # ships libcap2-bin; the base image — where graceful-fallback
        # scenarios like 50-ebpf-loader run a --ebpf-mode daemon WITHOUT
        # the ebpf feature — does not, and there the daemon should just
        # fall back to FeatureNotBuilt, so skipping setcap is correct.
        wants_bpf = (
            "--ebpf-mode" in self.extra_args
            and "disabled" not in self.extra_args
            and shutil.which("setcap") is not None
        )
        if wants_bpf:
            # cap_bpf/perfmon/mac_admin mirror the production unit's
            # AmbientCapabilities (CAP_BPF CAP_PERFMON CAP_MAC_ADMIN) —
            # mac_admin is what makes a BPF-LSM hook *enforcing* (its
            # deny is ignored without it). cap_dac_read_search is a
            # SANDBOX-ONLY add: this host hardens tracefs to 0700 root, so
            # the atty daemon can't read the tracepoint IDs libbpf needs
            # to attach trace_execve / trace_fork / etc. Production hosts
            # ship a readable tracefs, so the unit doesn't (and shouldn't)
            # grant DAC override.
            subprocess.run(
                [
                    "setcap",
                    "cap_bpf,cap_perfmon,cap_mac_admin,cap_dac_read_search+eip",
                    "/usr/local/bin/atty-guard",
                ],
                check=True,
            )
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
        self._log_fd = open(self.stderr_log, "w")
        self.proc = subprocess.Popen(
            cmd,
            stdout=self._log_fd,
            stderr=subprocess.STDOUT,
            env=run_env,
            preexec_fn=os.setsid,
        )
        if not self.wait_socket(timeout=5.0):
            self.dump_log()
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
        if self._log_fd is not None:
            try:
                self._log_fd.close()
            except OSError:
                pass
            self._log_fd = None

    def wait_socket(self, timeout: float = 5.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if os.path.exists(self.socket):
                return True
            time.sleep(0.05)
        return False

    def socket_ready(self) -> bool:
        return os.path.exists(self.socket)

    def read_log(self) -> str:
        try:
            return self.stderr_log.read_text()
        except FileNotFoundError:
            return ""

    def log_matches(self, pattern: str | re.Pattern[str]) -> bool:
        """Regex search over captured daemon stderr. Pass MULTILINE
        + line-anchored patterns for failure-signature checks —
        substring search has too many false positives for words
        like 'error' / 'failed'."""
        rx = pattern if isinstance(pattern, re.Pattern) else re.compile(pattern, re.MULTILINE)
        return rx.search(self.read_log()) is not None

    def dump_log(self) -> None:
        print("---- atty-guard log ----")
        print(self.read_log())
        print("---- end log ----")
