#!/usr/bin/env python3
"""56-ebpf-propagate-fork — `propagate_on_fork` blocks a deep descendant
that a bounded `ancestry` walk misses.

A descendant four fork-levels below the marked bash, via nested
subshells:

    M (marked) ─fork→ s1 ─fork→ s2 ─fork→ s3 ─fork+exec→ /bin/true

- `--enforcement-depth=ancestry --ancestry-max-depth=2`: the LSM walk
  stops two hops up (at s2) without reaching the marked bash → ALLOWED.
- `--enforcement-depth=propagate_on_fork`: the `sched_process_fork` hook
  copies the mark onto every fork child (M→s1→s2→s3→/bin/true), so
  /bin/true's OWN pid is marked → BLOCKED, independent of depth (and of
  any later reparenting a double-fork would do).

Running both proves propagate covers descendants the bounded walk can't.
Skips cleanly when BPF LSM / the baked .bpf.o aren't available.
"""
from __future__ import annotations

import sys

sys.path.insert(0, "/sandbox")
from lib.bpf import skip_if_no_bpf_lsm, skip_if_no_bpf_object  # noqa: E402
from lib.pty import execve_blocked, mark_and_run  # noqa: E402

NAME = "56-ebpf-propagate-fork"

# /bin/true four fork-levels below the marked bash. Each `( : ; ( … ) )`
# has two statements so bash can't collapse / exec-in-place — it forks a
# real subshell. `& wait` at the bottom propagates /bin/true's exit
# status back up so run_in_bash's `echo rc=$?` captures it.
DEEP = "( : ; ( : ; ( /bin/true & wait ) ) )"


def fail(msg: str) -> None:
    print(f"FAIL: {NAME}: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    skip_if_no_bpf_lsm(NAME)
    skip_if_no_bpf_object(NAME)

    # Baseline: a depth-2 ancestry walk can't reach the marked bash
    # (it's four hops up) → the deep descendant runs.
    try:
        rc, out = mark_and_run(
            ["--enforcement-depth", "ancestry", "--ancestry-max-depth", "2"],
            DEEP,
        )
    except RuntimeError as e:
        fail(f"ancestry(2): {e}")
    if execve_blocked(rc, out):
        fail(f"ancestry(2) BLOCKED a 4-deep descendant (rc={rc}) — the walk "
             f"shouldn't reach the marked bash within 2 hops.\noutput: {out!r}")

    # propagate marks every fork child, so the deep descendant's own pid
    # carries the mark → blocked regardless of depth.
    try:
        rc, out = mark_and_run(["--enforcement-depth", "propagate_on_fork"], DEEP)
    except RuntimeError as e:
        fail(f"propagate: {e}")
    if not execve_blocked(rc, out):
        fail(f"propagate ALLOWED the deep descendant (rc={rc}) — the fork "
             f"hook didn't propagate the mark.\noutput: {out!r}")

    print(f"PASS: {NAME}")


if __name__ == "__main__":
    main()
