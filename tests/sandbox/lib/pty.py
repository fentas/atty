"""Non-blocking PTY-read helpers for sandbox scenarios.

`ptyprocess.PtyProcess.read()` uses blocking `os.read`, which hangs
when the child has nothing to emit — fine for streaming-output
tests (smoke's `echo` floods the pipe), broken for any flow that
asks "did the child produce X within budget?" The select-based
read below polls the PTY fd and exits cleanly on deadline.
"""
from __future__ import annotations

import json
import os
import select
import subprocess
import time

# rc bash reports for "found but couldn't exec" — the canonical
# EPERM-on-execve signature the LSM hook produces.
EXEC_DENIED_RC = 126


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


# ── eBPF-enforcement scenario helpers (51 / 55 / 56) ───────────────
# Spawn a bash under alice, mark a PID Critical via the daemon RPC, and
# run a command capturing its exit code — the pieces for asserting the
# LSM hook blocks (or allows) an execve under a given enforcement depth.
# Raise RuntimeError on internal failure; callers map that to SKIP/FAIL.


def spawn_alice_bash():
    """Spawn an interactive bash under alice. Returns (proc, pid).
    Raises RuntimeError if the shell's PID can't be captured.
    """
    import ptyprocess

    proc = ptyprocess.PtyProcess.spawn(
        ["runuser", "-u", "alice", "--", "bash", "--noprofile", "--norc"],
        env={**os.environ, "PS1": r"\$ ", "HOME": "/home/alice"},
        dimensions=(24, 80),
    )
    sink = bytearray()
    drain(proc, 2.0, sink)
    proc.write(b"echo PID=$$\r")
    deadline = time.time() + 3.0
    while time.time() < deadline:
        drain(proc, 0.1, sink)
        for line in bytes(sink).decode("utf-8", errors="replace").splitlines():
            if line.startswith("PID="):
                try:
                    return proc, int(line[4:].strip())
                except ValueError:
                    pass
        time.sleep(0.05)
    proc.kill(9)
    raise RuntimeError(f"couldn't capture alice's bash PID; output={bytes(sink)!r}")


def mark_critical_via_alice(pid: int) -> None:
    """Mark `pid` Critical via the daemon RPC, sent AS alice (SO_PEERCRED
    lets a user mark its own PIDs). Raises RuntimeError on RPC error.
    """
    res = subprocess.run(
        [
            "runuser", "-u", "alice", "--", "python3", "-c",
            "import json; from lib.uds import call; "
            f"print(json.dumps(call('set_threat_level', pid={pid}, level='critical')))",
        ],
        capture_output=True, timeout=10,
    )
    if res.returncode != 0:
        raise RuntimeError(f"set_threat_level RPC failed: stderr={res.stderr!r}")
    resp = json.loads(res.stdout)
    if resp.get("type") == "error":
        raise RuntimeError(f"set_threat_level rejected: {resp}")


def run_in_bash(proc, cmd: str, settle: float = 4.0):
    """Run `<cmd>; echo rc=$?` in the PTY bash; return (rc, raw output).
    rc = -1 if no `rc=` line surfaced within `settle` seconds.
    """
    sink = bytearray()
    proc.write(cmd.encode() + b"; echo rc=$?\r")
    deadline = time.time() + settle
    while time.time() < deadline:
        drain(proc, 0.1, sink)
        for line in bytes(sink).decode("utf-8", errors="replace").splitlines():
            if line.startswith("rc="):
                try:
                    return int(line[3:].strip()), bytes(sink).decode("utf-8", errors="replace")
                except ValueError:
                    pass
        time.sleep(0.05)
    return -1, bytes(sink).decode("utf-8", errors="replace")


def mark_and_run(mode_args, cmd: str):
    """Under a `--ebpf-mode block` daemon with `mode_args`, spawn a bash
    under alice, mark it Critical, run `cmd` in it, and return
    (rc, output). Raises RuntimeError if the daemon doesn't attach or the
    mark doesn't reach the BPF map. Imports are local to dodge a
    lib-package import cycle.
    """
    from lib.bpf import bpf_map_has_pid
    from lib.daemon import Daemon

    proc, alice_pid = spawn_alice_bash()
    try:
        with Daemon(extra_args=["--ebpf-mode", "block", *mode_args], verbosity=1) as d:
            time.sleep(1.0)
            if "eBPF attached" not in d.read_log():
                d.dump_log()
                raise RuntimeError("daemon didn't attach eBPF")
            mark_critical_via_alice(alice_pid)
            time.sleep(0.3)
            if not bpf_map_has_pid("threat_map", alice_pid):
                d.dump_log()
                raise RuntimeError(f"threat_map missing PID {alice_pid} after mark")
            return run_in_bash(proc, cmd)
    finally:
        try:
            proc.kill(9)
        except Exception:
            pass


def execve_blocked(rc: int, out: str) -> bool:
    """True when an execve was denied by the LSM hook. rc=126 is bash's
    "found but couldn't exec" code; the hook returns -EPERM ("Operation
    not permitted"), not EACCES ("Permission denied").
    """
    out_l = out.lower()
    return (
        rc == EXEC_DENIED_RC
        or "operation not permitted" in out_l
        or "permission denied" in out_l
    )
