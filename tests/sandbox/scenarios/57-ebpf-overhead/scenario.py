#!/usr/bin/env python3
"""57-ebpf-overhead — Tier-B per-mode eBPF program overhead.

MEASUREMENT scenario (not a pass/fail gate). Instead of timing
fork+exec from userspace — where the sub-µs hook cost drowns in the
hundreds-of-µs of process creation plus container noise — it uses the
kernel's own per-program accounting: with `bpf_stats_enabled`, the
kernel records each BPF program's cumulative `run_time_ns` and
`run_cnt`, so `Δrun_time_ns / Δrun_cnt` over a fixed fork+exec workload
is the precise average ns *per invocation* of each program.

For each enforcement depth we report ns/call of:
  - check_execve   — the LSM hook (one_level: 1 lookup; ancestry(N):
                     bounded walk; propagate: own-PID lookup)
  - trace_fork     — sched_process_fork (early-returns unless propagate;
                     this is propagate's per-fork cost)
  - trace_exit     — sched_process_exit GC (runs every mode now)

This isolates exactly what each mode adds, and where. Feeds the decision
matrix in docs/benchmarking.md.

Not in the `make sandbox-ebpf` target (measurement, not a gate) — run:
`python3 tests/sandbox/runner.py --no-build 57-ebpf-overhead`.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, "/sandbox")
from lib.bpf import skip_if_no_bpf_lsm  # noqa: E402
from lib.daemon import Daemon  # noqa: E402

NAME = "57-ebpf-overhead"
BPF_OBJ = Path("/usr/lib/atty-guard/atty_guard.bpf.o")
STATS_SYSCTL = Path("/proc/sys/kernel/bpf_stats_enabled")

WORKLOAD = 4000  # fork+exec iterations driving the hooks per mode
PROGS = ("check_execve", "trace_fork", "trace_exit")


def skip_if_no_bpf_object() -> None:
    if not BPF_OBJ.is_file():
        print(f"SKIP: {NAME} — {BPF_OBJ} not baked.")
        sys.exit(0)


def set_bpf_stats(on: bool) -> bool:
    try:
        STATS_SYSCTL.write_text("1" if on else "0")
        return True
    except OSError:
        return False


def fork_exec_workload(n: int) -> None:
    argv = ["/bin/true"]
    env: dict[str, str] = {}
    for _ in range(n):
        pid = os.fork()
        if pid == 0:
            try:
                os.execve("/bin/true", argv, env)
            except OSError:
                os._exit(127)
        os.waitpid(pid, 0)


def prog_stats() -> dict[str, tuple[int, int]]:
    """name → (run_time_ns, run_cnt) for our programs, via bpftool."""
    res = subprocess.run(
        ["bpftool", "prog", "show", "--json"],
        capture_output=True, timeout=10,
    )
    out: dict[str, tuple[int, int]] = {}
    if res.returncode != 0:
        return out
    try:
        progs = json.loads(res.stdout)
    except json.JSONDecodeError:
        return out
    for p in progs:
        name = p.get("name", "")
        if name in PROGS:
            out[name] = (int(p.get("run_time_ns", 0)), int(p.get("run_cnt", 0)))
    return out


def measure_mode(idx: int, extra: list[str]) -> dict[str, float]:
    """ns/call per program for one enforcement mode, as a before/after
    delta around the workload (excludes the daemon's startup execs)."""
    # Unique socket per mode: a prior daemon's socket file can linger
    # after SIGTERM and cause a false-positive readiness / bind clash.
    sock = f"/run/atty-guard/bench-{idx}.sock"
    with Daemon(socket=sock, extra_args=["--ebpf-mode", "block", *extra], verbosity=1) as d:
        time.sleep(1.5)
        if "eBPF attached" not in d.read_log():
            d.dump_log()
            raise RuntimeError("daemon didn't attach eBPF")
        before = prog_stats()
        fork_exec_workload(WORKLOAD)
        after = prog_stats()
    per_call: dict[str, float] = {}
    for name in PROGS:
        rt0, c0 = before.get(name, (0, 0))
        rt1, c1 = after.get(name, (0, 0))
        dc = c1 - c0
        per_call[name] = (rt1 - rt0) / dc if dc > 0 else float("nan")
    return per_call


def main() -> None:
    skip_if_no_bpf_lsm(NAME)
    skip_if_no_bpf_object()
    if not set_bpf_stats(True):
        print(f"SKIP: {NAME} — can't enable {STATS_SYSCTL} (need a "
              "privileged container to write the global sysctl).")
        sys.exit(0)

    modes = [
        ("one_level", ["--enforcement-depth", "one_level"]),
        ("ancestry(8)", ["--enforcement-depth", "ancestry", "--ancestry-max-depth", "8"]),
        ("propagate_on_fork", ["--enforcement-depth", "propagate_on_fork"]),
    ]
    try:
        results = []
        for idx, (label, extra) in enumerate(modes):
            try:
                results.append((label, measure_mode(idx, extra)))
            except RuntimeError as e:
                print(f"FAIL: {NAME}: {label}: {e}", file=sys.stderr)
                sys.exit(1)
            time.sleep(1.0)  # let the kernel reclaim BPF before the next mode
    finally:
        set_bpf_stats(False)

    print()
    print(f"  {NAME} — kernel BPF run-time stats, fork+execve x{WORKLOAD}/mode (ns per program invocation)")
    print(f"  {'mode':<20} {'check_execve':>13} {'trace_fork':>12} {'trace_exit':>12}")
    print(f"  {'-' * 20} {'-' * 13} {'-' * 12} {'-' * 12}")
    for label, pc in results:
        cells = []
        for name in PROGS:
            v = pc.get(name, float("nan"))
            cells.append("n/a" if v != v else f"{v:.0f}")
        print(f"  {label:<20} {cells[0]:>13} {cells[1]:>12} {cells[2]:>12}")
    print()
    print(f"PASS: {NAME}")


if __name__ == "__main__":
    main()
