#!/usr/bin/env python3
"""62-ebpf-profile-strict-basename — `strict` A+ blocks a denied BASENAME
at ANY path, closing the exact-path evasion that A (61) can't catch.

A (61) matches the full exec path, so a binary copied to / symlinked from a
different path evades. A+ adds `deny_basenames`: the kernel extracts the
basename of `bprm->filename` via `bpf_loop` and looks it up, so the deny
rule catches the target wherever it lives.

Flow: daemon `--ebpf-mode observe` + `[profile] mode="strict"` with
`deny_basenames=["evilcmd"]` and an EMPTY `deny_binaries` (so the block can
ONLY come from the basename match); drop a real ELF at a NON-standard path
/tmp/evilcmd (basename `evilcmd`, a path that is NOT in any deny list);
spawn a bash under alice; `set_watch` it; run /tmp/evilcmd in the watched
bash → assert rc 126 + EPERM (blocked pre-exec via the basename). Negative
control: a non-denied /bin/true still runs (rc 0).

Skips cleanly without BPF LSM / the baked .bpf.o.
"""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, "/sandbox")
from lib.bpf import skip_if_no_bpf_lsm, skip_if_no_bpf_object  # noqa: E402
from lib.daemon import Daemon  # noqa: E402
from lib.pty import run_in_bash, spawn_alice_bash  # noqa: E402
from lib.uds import call  # noqa: E402

NAME = "62-ebpf-profile-strict-basename"

DENY_BASENAME = "evilcmd"
# A NON-standard path NOT listed in any deny_binaries — only the basename
# is denied, so a block here proves basename (not full-path) matching.
DENY_PATH = f"/tmp/{DENY_BASENAME}"
EPERM_RC = 126
EPERM_MSG = "Operation not permitted"


def fail(msg: str) -> None:
    print(f"FAIL: {NAME}: {msg}", file=sys.stderr)
    sys.exit(1)


def strict_config() -> Path:
    fd, path = tempfile.mkstemp(prefix="atty-profile-strict-bn.", suffix=".toml")
    os.write(fd, b'[profile]\nmode = "strict"\ndeny_basenames = ["%s"]\n'
             % DENY_BASENAME.encode())
    os.close(fd)
    return Path(path)


def main() -> None:
    skip_if_no_bpf_lsm(NAME)
    skip_if_no_bpf_object(NAME)

    shutil.copy("/bin/echo", DENY_PATH)
    os.chmod(DENY_PATH, 0o755)

    cfg = strict_config()
    proc, alice_pid = spawn_alice_bash()
    try:
        with Daemon(extra_args=["--ebpf-mode", "observe"], config_path=cfg, verbosity=1) as d:
            time.sleep(1.0)
            log = d.read_log()
            if "eBPF attached" not in log:
                d.dump_log()
                fail("daemon didn't attach eBPF")
            if "1 binary deny-rule(s) loaded" not in log:
                d.dump_log()
                fail("strict profile didn't load the basename deny-rule "
                     "(expected '1 binary deny-rule(s) loaded')")

            resp = call("set_watch", pid=alice_pid)
            if resp.get("type") == "error":
                fail(f"set_watch rejected: {resp}")
            time.sleep(0.3)

            rc, out = run_in_bash(proc, DENY_PATH, settle=6.0)
            if rc != EPERM_RC or EPERM_MSG not in out:
                d.dump_log()
                fail(f"denied BASENAME at {DENY_PATH} NOT blocked pre-exec "
                     f"(rc={rc}, expected {EPERM_RC}+EPERM). A+ basename match "
                     f"should -EPERM it even though the path isn't in "
                     f"deny_binaries.\noutput: {out!r}")

            # Negative control: a non-denied binary still runs.
            rc_ok, out_ok = run_in_bash(proc, "/bin/true", settle=6.0)
            if rc_ok != 0:
                d.dump_log()
                fail(f"non-denied /bin/true did NOT run (rc={rc_ok}) — strict "
                     f"is over-blocking.\noutput: {out_ok!r}")
    finally:
        try:
            proc.kill(9)
        except Exception:
            pass
        cfg.unlink(missing_ok=True)
        try:
            os.unlink(DENY_PATH)
        except FileNotFoundError:
            pass

    print(f"PASS: {NAME} (strict blocked the denied basename at a non-listed path)")


if __name__ == "__main__":
    main()
