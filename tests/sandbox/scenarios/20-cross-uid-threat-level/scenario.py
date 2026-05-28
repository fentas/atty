#!/usr/bin/env python3
"""20-cross-uid-threat-level — cross-UID set + read both rejected.

Pins the two gates that landed for issues #275 / #271: alice's
PID is opaque to bob. bob can neither MARK alice's PID High
(`set_threat_level`, gated since #271) nor PROBE its current
level (`get_threat_level`, gated since #275). Without these gates
a same-group local attacker could DoS another tenant's shell
into auto-Block territory, or info-leak by probing.
"""
from __future__ import annotations

import signal
import subprocess
import sys
import time

sys.path.insert(0, "/sandbox")
from lib.daemon import Daemon  # noqa: E402
from lib.uds import call  # noqa: E402


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    # `runuser` stays at uid=0 as the parent and forks/execs the
    # target as the requested user — so subprocess.Popen.pid points
    # at uid 0, not alice. Print alice's actual PID from inside the
    # bash that has already setuid'd, then exec sleep to keep that
    # PID alive.
    victim = subprocess.Popen(
        ["runuser", "-u", "alice", "--", "bash", "-c",
         "echo $$; exec sleep 30"],
        stdout=subprocess.PIPE,
    )
    try:
        alice_pid = int(victim.stdout.readline().strip())
        time.sleep(0.1)
        # Verify the daemon's view: /proc/<pid>/status Uid field
        # really resolves to alice (1001). If this is wrong all
        # downstream assertions are meaningless.
        with open(f"/proc/{alice_pid}/status") as f:
            uid_line = next((l for l in f if l.startswith("Uid:")), "")
        if "\t1001\t" not in uid_line:
            fail(f"alice victim PID {alice_pid} not owned by 1001: "
                 f"{uid_line!r}")

        with Daemon():
            # bob → set_threat_level on alice's PID must reject.
            resp = subprocess.run(
                [
                    "runuser", "-u", "bob", "--",
                    "python3", "-c",
                    f"import sys; sys.path.insert(0, '/sandbox'); "
                    f"from lib.uds import call; "
                    f"import json; "
                    f"print(json.dumps(call('set_threat_level', "
                    f"pid={alice_pid}, level='high')))",
                ],
                capture_output=True,
                timeout=10,
            )
            if resp.returncode != 0:
                fail(f"bob set RPC subprocess failed: {resp.stderr!r}")
            import json
            set_resp = json.loads(resp.stdout)
            if set_resp.get("type") != "error":
                fail(f"set_threat_level cross-UID NOT rejected: {set_resp}")
            if "cannot set" not in set_resp.get("message", ""):
                fail(f"set_threat_level error message unexpected: {set_resp}")

            # bob → get_threat_level on alice's PID must also reject.
            resp = subprocess.run(
                [
                    "runuser", "-u", "bob", "--",
                    "python3", "-c",
                    f"import sys; sys.path.insert(0, '/sandbox'); "
                    f"from lib.uds import call; "
                    f"import json; "
                    f"print(json.dumps(call('get_threat_level', "
                    f"pid={alice_pid})))",
                ],
                capture_output=True,
                timeout=10,
            )
            if resp.returncode != 0:
                fail(f"bob get RPC subprocess failed: {resp.stderr!r}")
            get_resp = json.loads(resp.stdout)
            if get_resp.get("type") != "error":
                fail(f"get_threat_level cross-UID NOT rejected: {get_resp}")
            if "cannot read" not in get_resp.get("message", ""):
                fail(f"get_threat_level error message unexpected: {get_resp}")

            # Sanity: alice CAN read her own PID's level (default Low).
            resp = subprocess.run(
                [
                    "runuser", "-u", "alice", "--",
                    "python3", "-c",
                    f"import sys; sys.path.insert(0, '/sandbox'); "
                    f"from lib.uds import call; "
                    f"import json; "
                    f"print(json.dumps(call('get_threat_level', "
                    f"pid={alice_pid})))",
                ],
                capture_output=True,
                timeout=10,
            )
            if resp.returncode != 0:
                fail(f"alice get RPC subprocess failed: {resp.stderr!r}")
            self_resp = json.loads(resp.stdout)
            if self_resp.get("type") != "threat_level":
                fail(f"alice self-read NOT allowed: {self_resp}")
            if self_resp.get("level") != "low":
                fail(f"alice's PID is not Low: {self_resp}")

    finally:
        try:
            victim.send_signal(signal.SIGTERM)
            victim.wait(timeout=3)
        except (subprocess.TimeoutExpired, ProcessLookupError):
            pass

    print("PASS: 20-cross-uid-threat-level")


if __name__ == "__main__":
    main()
