#!/usr/bin/env python3
"""51-ebpf-threat-map-roundtrip — daemon→BPF map→LSM hook chain.

Pins the kernel-side enforcement: alice's bash gets marked
Critical via the daemon's set_threat_level RPC; the daemon
writes through to the threat_map BPF map; the LSM hook's
`bprm_check_security` reads the map and EPERMs subsequent
execve()s under that PID.

Two-stage assertion:
1. `bpftool map dump name threat_map` confirms the daemon
   landed the kernel-side write (independent of LSM hook
   behaviour).
2. A PTY-driven bash under alice runs `/bin/true` after the
   mark — the LSM hook intercepts and the shell reports
   "Permission denied" with non-zero rc.

If (1) passes but (2) fails: the regression is on the kernel-
side LSM hook (vs the daemon-side write). Two-stage check =
better diagnostics than a single end-to-end one.

The warn-mode equivalent (set_threat_level writes to warn_pids,
LSM hook allows the execve) is in `53-ebpf-warn-mode`.

Skips cleanly when:
- BPF LSM not in `/sys/kernel/security/lsm` (lib/bpf.py).
- atty_guard.bpf.o not baked into the image.
"""
from __future__ import annotations

import json
import os
import select
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, "/sandbox")
from lib.bpf import bpf_map_has_pid, skip_if_no_bpf_lsm  # noqa: E402
from lib.daemon import Daemon  # noqa: E402

import ptyprocess  # noqa: E402


BPF_OBJ = Path("/usr/lib/atty-guard/atty_guard.bpf.o")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def skip_if_no_bpf_object() -> None:
    if not BPF_OBJ.is_file():
        print(f"SKIP: 51-ebpf-threat-map-roundtrip — "
              f"{BPF_OBJ} not baked. Build Dockerfile.ebpf on a host "
              "with /sys/kernel/btf/vmlinux present.")
        sys.exit(0)


def read_all_available(proc, timeout: float, sink: bytearray) -> None:
    """Drain pending PTY output without blocking past `timeout`."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([proc.fd], [], [], 0.1)
        if not r:
            continue
        try:
            chunk = os.read(proc.fd, 4096)
            if chunk:
                sink.extend(chunk)
            else:
                return
        except OSError:
            return


def spawn_alice_bash() -> tuple["ptyprocess.PtyProcess", int]:
    """Spawn an interactive bash under alice. Returns (proc, pid)."""
    proc = ptyprocess.PtyProcess.spawn(
        ["runuser", "-u", "alice", "--", "bash",
         "--noprofile", "--norc"],
        env={**os.environ, "PS1": r"\$ ", "HOME": "/home/alice"},
        dimensions=(24, 80),
    )
    sink = bytearray()
    read_all_available(proc, 2.0, sink)
    proc.write(b"echo PID=$$\r")
    deadline = time.time() + 3.0
    while time.time() < deadline:
        read_all_available(proc, 0.1, sink)
        for line in bytes(sink).decode("utf-8", errors="replace").splitlines():
            if line.startswith("PID="):
                try:
                    return proc, int(line[4:].strip())
                except ValueError:
                    pass
        time.sleep(0.05)
    proc.kill(9)
    fail(f"couldn't capture alice's bash PID; output={bytes(sink)!r}")


def mark_critical_via_alice(pid: int) -> None:
    res = subprocess.run(
        ["runuser", "-u", "alice", "--", "python3", "-c",
         "import sys; sys.path.insert(0, '/sandbox'); "
         "import json; from lib.uds import call; "
         f"print(json.dumps(call('set_threat_level', "
         f"pid={pid}, level='critical')))"],
        capture_output=True, timeout=10,
    )
    if res.returncode != 0:
        fail(f"set_threat_level RPC failed: stderr={res.stderr!r}")
    resp = json.loads(res.stdout)
    if resp.get("type") == "error":
        fail(f"set_threat_level rejected: {resp}")


def try_execve_in_bash(proc) -> tuple[int, str]:
    """Run `/bin/true; echo rc=$?` in the PTY-attached bash.
    Returns (rc, raw output). rc = -1 if no rc= line surfaced."""
    sink = bytearray()
    proc.write(b"/bin/true; echo rc=$?\r")
    deadline = time.time() + 4.0
    while time.time() < deadline:
        read_all_available(proc, 0.1, sink)
        for line in bytes(sink).decode("utf-8", errors="replace").splitlines():
            if line.startswith("rc="):
                try:
                    return int(line[3:].strip()), bytes(sink).decode("utf-8", errors="replace")
                except ValueError:
                    pass
        time.sleep(0.05)
    return -1, bytes(sink).decode("utf-8", errors="replace")


def run_block_sub() -> None:
    proc, alice_pid = spawn_alice_bash()
    try:
        with Daemon(extra_args=["--ebpf-mode", "block"], verbosity=1) as d:
            time.sleep(1.0)
            log = d.read_log()
            if "eBPF attached" not in log:
                d.dump_log()
                fail(f"block sub: daemon didn't attach eBPF; log:\n{log}")
            mark_critical_via_alice(alice_pid)
            # Give the BPF map write a beat to land before the
            # next execve fires.
            time.sleep(0.3)
            # block sub: independently verify the daemon→kernel
            # map-write chain via bpftool BEFORE checking LSM.
            # If this assertion holds but the LSM check below
            # doesn't, the kernel-side hook is the regression
            # site (vs. the daemon-side write). Two-stage check
            # = better diagnostics than a single end-to-end one.
            if not bpf_map_has_pid("threat_map", alice_pid):
                d.dump_log()
                fail(f"block sub: threat_map missing PID {alice_pid} after "
                     "SetThreatLevel(Critical) — daemon→BPF map write "
                     "failed.")
            rc, out = try_execve_in_bash(proc)
            if rc == 0:
                fail(f"block sub: execve under alice's bash was ALLOWED "
                     f"despite threat_map entry — LSM EPERM didn't fire. "
                     "Map write landed but the kernel-side hook isn't "
                     f"reading it.\noutput: {out!r}")
            # The LSM hook returns -EPERM (errno 1 → "Operation not
            # permitted"), NOT EACCES ("Permission denied"). rc=126 is
            # bash's "found but couldn't exec" code — the canonical
            # EPERM-on-execve signature. Accept either signal.
            out_l = out.lower()
            if rc != 126 and "operation not permitted" not in out_l and "permission denied" not in out_l:
                fail(f"block sub: execve failed (rc={rc}) but without an "
                     f"EPERM signature — verify the denial came from the "
                     f"LSM hook, not some other failure.\noutput: {out!r}")
    finally:
        try:
            proc.kill(9)
        except ptyprocess.PtyProcessError:
            pass


def main() -> None:
    skip_if_no_bpf_lsm("51-ebpf-threat-map-roundtrip")
    skip_if_no_bpf_object()

    run_block_sub()

    print("PASS: 51-ebpf-threat-map-roundtrip")


if __name__ == "__main__":
    main()
