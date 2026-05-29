#!/usr/bin/env python3
"""53-ebpf-warn-mode — `--ebpf-mode=warn` allows execve + warn_pids write.

Mirror of 51-ebpf-threat-map-roundtrip but for the warn-mode path
landed in #347's PR 1: when an operator picks warn over block, a
Critical-verdict `set_threat_level` writes the PID to the
`warn_pids` BPF map (NOT `threat_map`), and the LSM hook ALLOWS
the subsequent execve rather than EPERMing it.

Three-stage assertion:
1. `warn_pids` contains the PID after the daemon write — verifies
   the mode dispatch landed.
2. `threat_map` does NOT contain the PID — confirms warn-mode
   dispatch didn't fall through to the block path.
3. A PTY-driven `/bin/true` under the marked PID returns rc=0 —
   confirms the LSM hook respects the warn/allow path.

If (1) fails but (3) succeeds: dispatch is broken (still writing
to threat_map maybe? but block dispatch would have EPERMed → 3
would fail too). If (1) passes but (3) fails: the LSM hook is
EPERMing on warn_pids entries that should only emit + allow.

Pairs with 51 to cover the full mode matrix kernel-side.
Subscribe-RPC + atty banner rendering land in subsequent PRs;
that path's sandbox coverage will be `54-ebpf-warn-atty-render`.

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
        print(f"SKIP: 53-ebpf-warn-mode — "
              f"{BPF_OBJ} not baked. Build Dockerfile.ebpf on a host "
              "with /sys/kernel/btf/vmlinux present.")
        sys.exit(0)


def read_all_available(proc, timeout: float, sink: bytearray) -> None:
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


def main() -> None:
    skip_if_no_bpf_lsm("53-ebpf-warn-mode")
    skip_if_no_bpf_object()

    proc, alice_pid = spawn_alice_bash()
    try:
        with Daemon(extra_args=["--ebpf-mode", "warn"], verbosity=1) as d:
            time.sleep(1.0)
            log = d.read_log()
            if "eBPF attached" not in log:
                d.dump_log()
                fail(f"daemon didn't attach eBPF; log:\n{log}")
            mark_critical_via_alice(alice_pid)
            time.sleep(0.3)

            if not bpf_map_has_pid("warn_pids", alice_pid):
                d.dump_log()
                fail(f"warn_pids missing PID {alice_pid} after "
                     "SetThreatLevel(Critical) under --ebpf-mode=warn "
                     "— mode dispatch didn't route to the warn map.")
            if bpf_map_has_pid("threat_map", alice_pid):
                d.dump_log()
                fail(f"threat_map unexpectedly has PID {alice_pid} "
                     "under --ebpf-mode=warn — mode dispatch fell "
                     "through to the block path. Critical verdicts in "
                     "warn-mode should write warn_pids ONLY.")

            rc, out = try_execve_in_bash(proc)
            if rc != 0:
                fail(f"execve under alice's bash returned rc={rc} "
                     "(expected 0). LSM hook is EPERMing warn_pids "
                     "entries — warn-mode should allow the execve "
                     f"and only emit a ringbuf event.\noutput: {out!r}")
    finally:
        try:
            proc.kill(9)
        except ptyprocess.PtyProcessError:
            pass

    print("PASS: 53-ebpf-warn-mode")


if __name__ == "__main__":
    main()
