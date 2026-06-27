#!/usr/bin/env python3
"""61-ebpf-profile-strict — the `strict` profile BLOCKS a deny-listed
binary SYNCHRONOUSLY, before it runs (where `session`/60 kills it AFTER).

Phase 3 "A": `[profile] mode = "strict"` + `deny_binaries` populates the
kernel `deny_bins` map; `check_execve` reads the exec'd binary's full
path (`bprm->filename`), finds it in `deny_bins` for a watched task, and
returns -EPERM — true prevention. The exec never runs (bash reports rc
126), so the binary's side effect never happens. Contrast 60: there the
flagged command runs and is reactively SIGKILLed (rc 137) — it executed
first. (A matches the full path; basename/substring matching is the A+
layer, which needs an in-kernel scan the verifier only accepts via
bpf_loop.)

Flow: daemon `--ebpf-mode observe` (attaches the LSM) + a config with
`[profile] mode="strict"` and `deny_binaries=["/tmp/denied-payload"]`;
drop a real ELF (`cp /bin/echo`) at that path; spawn a bash under alice;
`set_watch` it; run the deny-listed binary in the watched bash → assert rc
126 AND the kernel EPERM message ("Operation not permitted"), which proves
the LSM denied the execve before it loaded the image (it never ran).

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

NAME = "61-ebpf-profile-strict"

DENY_BASENAME = "denied-payload"
DENY_PATH = f"/tmp/{DENY_BASENAME}"
EPERM_RC = 126  # bash: execve failed (cannot execute)
# The LSM returns -EPERM specifically (errno 1 → "Operation not permitted"),
# distinct from a missing binary (127) or EACCES ("Permission denied"). Its
# presence proves OUR deny fired AND that execve never loaded the image —
# i.e. the binary provably did not run. (A side-effect marker can't be used:
# the PTY echoes the typed command, so any argument shows up in the output
# regardless of whether the binary ran.)
EPERM_MSG = "Operation not permitted"


def fail(msg: str) -> None:
    print(f"FAIL: {NAME}: {msg}", file=sys.stderr)
    sys.exit(1)


def strict_config() -> Path:
    # A matches the full path (exact); basename matching is the A+ layer.
    fd, path = tempfile.mkstemp(prefix="atty-profile-strict.", suffix=".toml")
    os.write(fd, b'[profile]\nmode = "strict"\ndeny_binaries = ["%s"]\n'
             % DENY_PATH.encode())
    os.close(fd)
    return Path(path)


def main() -> None:
    skip_if_no_bpf_lsm(NAME)
    skip_if_no_bpf_object(NAME)

    # A real ELF (not a shebang script — keeps bprm->filename = our path,
    # one bprm_check) that echoes the marker if it ever runs.
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
                fail("strict profile didn't load the deny-rule (expected "
                     "'1 binary deny-rule(s) loaded')")

            resp = call("set_watch", pid=alice_pid)
            if resp.get("type") == "error":
                fail(f"set_watch rejected: {resp}")
            time.sleep(0.3)  # let the watch_pids write land

            rc, out = run_in_bash(proc, DENY_PATH, settle=6.0)
            if rc != EPERM_RC:
                d.dump_log()
                fail(f"deny-listed binary NOT blocked pre-exec (rc={rc}, "
                     f"expected {EPERM_RC}=EPERM). strict should -EPERM it in "
                     f"check_execve BEFORE it runs.\noutput: {out!r}")
            if EPERM_MSG not in out:
                d.dump_log()
                fail(f"rc {rc} without the LSM EPERM ({EPERM_MSG!r}) isn't a "
                     f"confirmed strict block (could be EACCES/missing).\n"
                     f"output: {out!r}")
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

    print(f"PASS: {NAME} (strict blocked the deny-listed binary before it ran)")


if __name__ == "__main__":
    main()
