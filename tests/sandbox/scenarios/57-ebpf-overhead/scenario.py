#!/usr/bin/env python3
"""57-ebpf-overhead — Tier-B per-mode eBPF program overhead.

MEASUREMENT scenario (not a pass/fail gate).

Two quantities, each measured (nothing assumed):

1. **Denominator** — the eBPF-off cost of one fork + execve(/bin/true) +
   wait, timed in userspace with no daemon attached. This is what the
   hook overhead is a fraction *of*.

2. **Numerators** — with `bpf_stats_enabled`, the kernel records each BPF
   program's cumulative `run_time_ns` / `run_cnt`, so
   `Δrun_time_ns / Δrun_cnt` over a fixed fork+exec workload is the
   precise mean ns *per invocation*. A fork+execve+exit fires four of
   our programs once each — trace_fork (fork), check_execve +
   trace_execve (execve), trace_exit (exit) — so their sum is the eBPF
   cost added per command, and `sum / denominator` is the honest
   percentage overhead.

The benchmarked process is UNMARKED, so these are the *always-paid*
costs on normal processes (the common case). The mark-copy path
(`trace_fork`'s `bpf_map_update_elem`, and `check_execve`'s block +
ringbuf submit) only runs for descendants of a flagged command and is
strictly costlier — out of scope here, which targets the overhead
enabling a mode imposes on everything else.

Feeds the decision matrix in docs/benchmarking.md. Not in the
`make sandbox-ebpf` target (measurement, not a gate):
`python3 tests/sandbox/runner.py --no-build 57-ebpf-overhead`
or `make sandbox-ebpf-bench`.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, "/sandbox")
from lib.bpf import skip_if_no_bpf_lsm, skip_if_no_bpf_object  # noqa: E402
from lib.daemon import Daemon  # noqa: E402

NAME = "57-ebpf-overhead"
STATS_SYSCTL = Path("/proc/sys/kernel/bpf_stats_enabled")

WORKLOAD = 4000  # fork+exec iterations driving the hooks per rep
REPS = 3
# Programs that fire once per fork+execve+exit, in firing order.
PROGS = ("trace_fork", "check_execve", "trace_execve", "trace_exit")


def read_stats_sysctl() -> str | None:
    try:
        return STATS_SYSCTL.read_text().strip()
    except OSError:
        return None


def set_bpf_stats(value: str) -> bool:
    try:
        STATS_SYSCTL.write_text(value)
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


def median(xs: list[float]) -> float:
    s = sorted(xs)
    return s[len(s) // 2]


def baseline_ns(iters: int, reps: int) -> float:
    """Median ns per fork+execve+wait with NO daemon (eBPF off)."""
    samples = []
    for _ in range(reps):
        fork_exec_workload(200)  # warm caches
        t0 = time.perf_counter_ns()
        fork_exec_workload(iters)
        samples.append((time.perf_counter_ns() - t0) / iters)
    return median(samples)


def prog_stats() -> dict[tuple[str, int], tuple[int, int]]:
    """(name, prog_id) → (run_time_ns, run_cnt) for our programs, via
    bpftool. Keyed by id too: bpftool can list several programs with the
    same name (a stale instance from a prior load, or an unrelated host
    program), so the delta step picks the id whose count actually grew
    rather than letting a same-name entry shadow the live one."""
    res = subprocess.run(
        ["bpftool", "prog", "show", "--json"],
        capture_output=True, timeout=10,
    )
    out: dict[tuple[str, int], tuple[int, int]] = {}
    if res.returncode != 0:
        return out
    try:
        progs = json.loads(res.stdout)
    except json.JSONDecodeError:
        return out
    for p in progs:
        name = p.get("name", "")
        if name in PROGS:
            key = (name, int(p.get("id", 0)))
            out[key] = (int(p.get("run_time_ns", 0)), int(p.get("run_cnt", 0)))
    return out


def measure_mode(idx: int, extra: list[str]) -> dict[str, float]:
    """Median ns/call per program for one mode over REPS workloads inside
    a single daemon lifetime."""
    # Unique socket per mode: a prior daemon's socket file can linger
    # after SIGTERM and cause a false-positive readiness / bind clash.
    sock = f"/run/atty-guard/bench-{idx}.sock"
    per_call: dict[str, list[float]] = {name: [] for name in PROGS}
    with Daemon(socket=sock, extra_args=["--ebpf-mode", "block", *extra], verbosity=1) as d:
        time.sleep(1.5)
        if "eBPF attached" not in d.read_log():
            d.dump_log()
            raise RuntimeError("daemon didn't attach eBPF")
        for _ in range(REPS):
            before = prog_stats()
            fork_exec_workload(WORKLOAD)
            after = prog_stats()
            for name in PROGS:
                # Among all programs sharing this name, take the instance
                # whose run_cnt grew most over the workload — that's the
                # live one driving our forks (ignores stale dups).
                best_dc, best_drt = 0, 0
                for (n, pid), (rt1, c1) in after.items():
                    if n != name:
                        continue
                    rt0, c0 = before.get((n, pid), (0, 0))
                    dc = c1 - c0
                    if dc > best_dc:
                        best_dc, best_drt = dc, rt1 - rt0
                if best_dc > 0:
                    per_call[name].append(best_drt / best_dc)
    return {name: (median(v) if v else float("nan")) for name, v in per_call.items()}


def main() -> None:
    skip_if_no_bpf_lsm(NAME)
    skip_if_no_bpf_object(NAME)

    prior = read_stats_sysctl()
    if not set_bpf_stats("1"):
        print(f"SKIP: {NAME} — can't enable {STATS_SYSCTL} (need a "
              "privileged container to write the global sysctl).")
        sys.exit(0)

    modes = [
        ("one_level", ["--enforcement-depth", "one_level"]),
        ("ancestry(8)", ["--enforcement-depth", "ancestry", "--ancestry-max-depth", "8"]),
        ("propagate_on_fork", ["--enforcement-depth", "propagate_on_fork"]),
    ]
    try:
        base = baseline_ns(WORKLOAD, REPS)
        results = []
        for idx, (label, extra) in enumerate(modes):
            try:
                results.append((label, measure_mode(idx, extra)))
            except RuntimeError as e:
                print(f"FAIL: {NAME}: {label}: {e}", file=sys.stderr)
                sys.exit(1)
            time.sleep(1.0)  # let the kernel reclaim BPF before the next mode
    finally:
        # Restore the prior value, not a blind "0" — don't clobber a
        # concurrent profiler that left it enabled.
        set_bpf_stats(prior if prior is not None else "0")

    # A wholly failed measurement (no bpftool, no stats) must not read green.
    if not any(v == v for _, pc in results for v in pc.values()):  # all NaN
        print(f"FAIL: {NAME}: every program measured n/a — bpftool / stats "
              "unavailable; the run produced no numbers.", file=sys.stderr)
        sys.exit(1)

    print()
    print(f"  {NAME} — kernel BPF run-time stats, fork+execve x{WORKLOAD}/mode, median of {REPS}")
    print(f"  baseline fork+execve+wait (eBPF off): {base:.0f} ns/op")
    print()
    hdr = f"  {'mode':<18}" + "".join(f"{p:>13}" for p in PROGS) + f"{'sum/cmd':>10}{'% base':>9}"
    print(hdr)
    print(f"  {'-' * 18}" + "".join(f"{'-' * 13:>13}" for _ in PROGS) + f"{'-' * 10:>10}{'-' * 9:>9}")
    for label, pc in results:
        cells = ""
        total = 0.0
        for name in PROGS:
            v = pc.get(name, float("nan"))
            cells += ("n/a" if v != v else f"{v:.0f}").rjust(13)
            if v == v:
                total += v
        pct = (total / base * 100.0) if base else 0.0
        print(f"  {label:<18}{cells}{('%.0f' % total):>10}{('%.2f%%' % pct):>9}")
    print()
    print(f"PASS: {NAME}")


if __name__ == "__main__":
    main()
