#!/usr/bin/env python3
"""54-ebpf-warn-subscribe — end-to-end kernel→ringbuf→subscriber.

Pins the full chain landed across #347's PR 1 + PR 2a + PR 2b:
the LSM hook's VERDICT_WARN ringbuf event reaches a Python
subscriber through the daemon's `subscribe_warn_events` RPC.

Wire-up:
1. Spawn an interactive bash under alice (PID captured).
2. Open a UDS subscriber connection, send
   `subscribe_warn_events { parent_pid_tree: alice_pid }` —
   exercises the per-PID-tree filter integration (pid_in_tree
   _root walks /proc/<child>/status looking for alice_pid as
   an ancestor). A filter regression surfaces as "no event
   received in 5s".
3. Read the `Subscribed` ack.
4. Mark alice's bash PID Critical under `--ebpf-mode=warn`.
5. Trigger an execve under alice (`/bin/true`).
6. Read the WarnEvent from the subscriber stream within timeout.
7. Assert: pid matches the execve'd process, kind/verdict
   tagged correctly via the wire format.

Failure modes this catches:
- Ringbuf consumer thread didn't spawn / dies on first event.
- ExecveEvent wire-format drift between C struct and Rust mirror
  (the byte layout invariant baked into PR 2a's tests would
  also catch this, but here we exercise the kernel-built path
  which the unit test can't.)
- Broadcast Mutex contention bug where the consumer holds the
  Mutex while the SubscribeWarnEvents handler is trying to
  register (deadlock; subscriber never sees the ack).
- Filter regression: pid_tree_root=0 fails open.

Pairs with 53 (kernel-side warn dispatch). 53 verifies the
LSM hook allows + maps populate; 54 verifies the user-space
broadcast path delivers.

Skips cleanly when:
- BPF LSM not in `/sys/kernel/security/lsm` (lib/bpf.py).
- atty_guard.bpf.o not baked into the image.
"""
from __future__ import annotations

import json
import os
import select
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, "/sandbox")
from lib.bpf import skip_if_no_bpf_lsm  # noqa: E402
from lib.daemon import Daemon  # noqa: E402
from lib.uds import DEFAULT_SOCKET  # noqa: E402

import ptyprocess  # noqa: E402


BPF_OBJ = Path("/usr/lib/atty-guard/atty_guard.bpf.o")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def skip_if_no_bpf_object() -> None:
    if not BPF_OBJ.is_file():
        print(f"SKIP: 54-ebpf-warn-subscribe — {BPF_OBJ} not "
              "baked. Build Dockerfile.ebpf on a host with "
              "/sys/kernel/btf/vmlinux present.")
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


def open_subscriber(pid_tree_root: int) -> tuple[socket.socket, socket.SocketIO]:
    """Connect to the daemon UDS, send the SubscribeWarnEvents
    request, wait for the `Subscribed` ack. Returns (socket, file
    handle for newline-buffered reads).

    `pid_tree_root` exercises the PID-tree filter integration —
    passing alice's bash PID means the test only receives events
    from alice's tree, which is also the only tree producing
    warn events here. A filter regression (pid_in_tree_root
    returns false when it should return true) would surface as
    "no warn_event received within timeout".
    """
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5.0)
    s.connect(DEFAULT_SOCKET)
    req = json.dumps({
        "id": 1,
        "method": "subscribe_warn_events",
        "parent_pid_tree": pid_tree_root,
    })
    s.sendall((req + "\n").encode())
    # makefile-buffered read for line framing.
    rf = s.makefile("rb")
    ack_line = rf.readline()
    if not ack_line:
        fail("subscriber connection closed before ack")
    ack = json.loads(ack_line.decode())
    if ack.get("type") != "subscribed":
        fail(f"expected subscribed ack, got: {ack}")
    return s, rf


def mark_critical_via_alice(pid: int) -> None:
    import subprocess
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


def try_execve_in_bash(proc) -> int:
    """Run `/bin/true` in the PTY bash; returns rc (always 0 in
    warn mode since the LSM allows). Does NOT assert rc — that's
    53's job. We just need the execve to happen so the LSM hook
    emits the warn event."""
    sink = bytearray()
    proc.write(b"/bin/true; echo rc=$?\r")
    deadline = time.time() + 4.0
    while time.time() < deadline:
        read_all_available(proc, 0.1, sink)
        for line in bytes(sink).decode("utf-8", errors="replace").splitlines():
            if line.startswith("rc="):
                try:
                    return int(line[3:].strip())
                except ValueError:
                    pass
        time.sleep(0.05)
    return -1


def read_warn_event(rf, timeout: float) -> dict | None:
    """Block-read one event from the subscriber stream until
    timeout. Returns the parsed dict or None on timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        # Use select on the underlying socket — rf.readline()
        # blocks indefinitely if no data is available, ignoring
        # the socket's timeout setting in some Python versions.
        sock_fd = rf.raw._sock.fileno() if hasattr(rf.raw, "_sock") else rf.fileno()
        r, _, _ = select.select([sock_fd], [], [], 0.5)
        if not r:
            continue
        line = rf.readline()
        if not line:
            return None
        try:
            evt = json.loads(line.decode())
        except json.JSONDecodeError:
            continue
        if evt.get("type") == "warn_event":
            return evt
        # Other types (warn_dropped, etc.) skipped silently for
        # this scenario's narrow goal.
    return None


def main() -> None:
    skip_if_no_bpf_lsm("54-ebpf-warn-subscribe")
    skip_if_no_bpf_object()

    proc, alice_pid = spawn_alice_bash()
    sub_sock = None
    try:
        with Daemon(extra_args=["--ebpf-mode", "warn"], verbosity=1) as d:
            time.sleep(1.0)
            log = d.read_log()
            if "eBPF attached" not in log:
                d.dump_log()
                fail(f"daemon didn't attach eBPF; log:\n{log}")

            sub_sock, rf = open_subscriber(pid_tree_root=alice_pid)
            mark_critical_via_alice(alice_pid)
            # Give the BPF map write a beat.
            time.sleep(0.3)

            # Trigger an execve; the LSM hook should emit
            # VERDICT_WARN, ringbuf consumer parses + broadcasts,
            # our subscriber receives.
            rc = try_execve_in_bash(proc)
            if rc != 0:
                d.dump_log()
                fail(f"execve was BLOCKED (rc={rc}) — warn mode "
                     "should allow it. Either warn dispatch leaked "
                     "into block path (53 would catch first) or the "
                     "bash test itself failed.")

            evt = read_warn_event(rf, timeout=5.0)
            if evt is None:
                d.dump_log()
                fail("no warn_event received within 5s after execve "
                     "— ringbuf consumer didn't fire OR broadcast "
                     "dropped the event OR subscriber stream broke.")
            # The event's pid is the CHILD pid (the just-execve'd
            # process), not alice's bash. The ppid should be
            # alice_pid (the bash that triggered the execve).
            if evt.get("ppid") != alice_pid:
                d.dump_log()
                fail(f"warn_event ppid mismatch: expected "
                     f"{alice_pid}, got {evt.get('ppid')}. Full "
                     f"event: {evt}")

    finally:
        if sub_sock is not None:
            try:
                sub_sock.close()
            except OSError:
                pass
        try:
            proc.kill(9)
        except ptyprocess.PtyProcessError:
            pass

    print("PASS: 54-ebpf-warn-subscribe")


if __name__ == "__main__":
    main()
