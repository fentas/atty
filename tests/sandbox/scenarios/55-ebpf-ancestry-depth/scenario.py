#!/usr/bin/env python3
"""55-ebpf-ancestry-depth — `ancestry` mode blocks a grandchild that
`one_level` allows.

The grandchild's direct parent is an (unmarked) subshell, not the
marked bash:

    M (marked bash) ─fork→ subshell ─fork+exec→ /bin/true

- `--enforcement-depth=one_level`: the LSM hook only checks the execve's
  direct parent (the subshell, unmarked) → the grandchild is ALLOWED.
  This is the gap the deeper modes close.
- `--enforcement-depth=ancestry`: the hook walks up to the marked bash →
  BLOCKED (-EPERM).

Running both proves ancestry catches what one_level misses. Skips
cleanly when BPF LSM / the baked .bpf.o aren't available.
"""
from __future__ import annotations

import sys

sys.path.insert(0, "/sandbox")
from lib.bpf import skip_if_no_bpf_lsm, skip_if_no_bpf_object  # noqa: E402
from lib.pty import execve_blocked, mark_and_run  # noqa: E402

NAME = "55-ebpf-ancestry-depth"

# Grandchild of the marked bash: `( )` forks a subshell (no exec), then
# `/bin/true &` forks+execs /bin/true as a child of the SUBSHELL. `wait`
# makes the subshell's exit status (captured by run_in_bash's
# `echo rc=$?`) reflect /bin/true's — 0 if allowed, 126 if the LSM
# EPERM'd its execve.
GRANDCHILD = "( /bin/true & wait )"


def fail(msg: str) -> None:
    print(f"FAIL: {NAME}: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    skip_if_no_bpf_lsm(NAME)
    skip_if_no_bpf_object(NAME)

    # Baseline: one_level must NOT block the grandchild (it only gates
    # direct children) — this is the gap ancestry exists to close.
    try:
        rc, out = mark_and_run(["--enforcement-depth", "one_level"], GRANDCHILD)
    except RuntimeError as e:
        fail(f"one_level: {e}")
    if execve_blocked(rc, out):
        fail(f"one_level unexpectedly BLOCKED the grandchild (rc={rc}) — "
             f"it should only gate direct children.\noutput: {out!r}")

    # ancestry MUST block it by walking up to the marked bash.
    try:
        rc, out = mark_and_run(["--enforcement-depth", "ancestry"], GRANDCHILD)
    except RuntimeError as e:
        fail(f"ancestry: {e}")
    if not execve_blocked(rc, out):
        fail(f"ancestry ALLOWED the grandchild (rc={rc}) — the ancestry "
             f"walk didn't reach the marked bash.\noutput: {out!r}")

    print(f"PASS: {NAME}")


if __name__ == "__main__":
    main()
