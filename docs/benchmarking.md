---
layout: default
title: Benchmarking
permalink: /benchmarking/
---

# atty — benchmarking

> **Status (2026-06): all three phases landed.** Phase 1 (the
> `zig build bench` harness), Phase 2 (the three configurable eBPF
> enforcement-depth modes), and Phase 3 (the per-mode overhead
> measurement + decision matrix). The measured default is `one_level`.

## Why

Two forces drive a benchmark suite:

1. **Defend the claims.** atty advertises a *zero-allocation hot path*
   and microsecond keystroke dispatch. That should be a number we can
   reproduce and regression-gate, not a vibe.
2. **Decide perf/latency tradeoffs with data.** The motivating case is
   kernel-side block enforcement depth (below): one-level vs a bounded
   ancestry walk vs propagate-on-fork trade *coverage* against
   *per-execve / per-fork compute*. The only honest way to pick a
   default — and to advise operators per use-case — is to measure all
   three on real kernels. We implement all three, make the depth
   **configurable**, and let the numbers pick the default.

## The suite — `zig build bench`

Two tiers, because not everything can run in CI:

### Tier A — in-process microbenchmarks (CI-safe)

A standalone `ReleaseFast` executable (`bench/main.zig`) that times
tight loops over the hot paths and prints `ns/op` + the per-op
**allocation count** (via a counting allocator, to assert the
zero-alloc claim). The first three rows are implemented today; the rest
are the planned target set:

| Benchmark | Status | Measures | Asserts |
|---|---|---|---|
| `dispatch_input` | ✅ | one keystroke through the module chain (`Dispatcher(modules).dispatchInput`) | ns/op, **0 allocs** |
| `line_state_apply` | ✅ | `LineState.applyInput` for printable / CSI bytes | ns/op, 0 allocs |
| `ghost_text` | ✅ | `gatherGhostText` over a seeded history ring (prefix match + trailing copy) | ns/op, 0 allocs |
| `keymap_match` | planned | CSI-u + legacy binding scan | ns/op |
| `output_throughput` | planned | `onOutput` over a multi-KiB shell chunk (mouse-ring ingest, SGR strip) | MB/s |
| `atom_scan` (guard) | planned | Aho-Corasick scan of a command line vs the atom corpus | ns/op |

The alloc counter sees allocations made through `ctx.allocator` /
`ctx.scratch` — the path the hot loop is supposed to use. A module that
captured a *different* allocator at `attach` (e.g. atuin's worker
thread) and allocated through that in `onInput` would be invisible to
the counter; the figure is "zero alloc on the dispatched path," which is
the property that matters for the keystroke loop. The
`per-keystroke dispatch makes zero heap allocations` test (in
`bench/main.zig`, run by `zig build test`) gates this so a regression
fails CI. (The Enter/commit branch — `onLineCommit` → history record —
is allowed to allocate and isn't the hot path.)

Output is a stable table (and a `--json` mode) so CI can diff against a
committed baseline and fail a PR that regresses the hot path past a
threshold. Run:

```sh
zig build bench                 # human table
zig build bench -- --json       # machine-readable, for CI baselines
zig build bench -- --filter dispatch
```

### Tier B — system / kernel benchmarks (sandbox, not CI)

eBPF and full PTY round-trips need a real kernel and a PTY, so they run
under the existing eBPF sandbox, not GitHub CI:

| Benchmark | Status | Measures |
|---|---|---|
| `57-ebpf-overhead` | ✅ | per-mode ns **per BPF-program invocation** (`trace_fork` / `check_execve` / `trace_execve` / `trace_exit`) via the kernel's `bpf_stats_enabled` run-time accounting |
| `map_pressure` | planned | `threat_map` growth + lookup cost under a deep/wide descendant tree |
| `pty_roundtrip` | planned | end-to-end keystroke→echo latency through the proxy |

Run it: `python3 tests/sandbox/runner.py --no-build 57-ebpf-overhead`
(it's a measurement, not a gate, so it's out of the `make sandbox-ebpf`
pass/fail target).

**Why kernel stats, not userspace timing.** A fork+execve+wait is
hundreds of µs of process creation; the hook cost is sub-µs, so a
userspace before/after delta drowns in container noise. With
`bpf_stats_enabled` the kernel records each program's cumulative
`run_time_ns` / `run_cnt`, so `Δrun_time_ns / Δrun_cnt` over a fixed
fork+exec workload is the precise mean ns *per program invocation* — the
actual quantity we care about.

#### Results (Phase 3, x86_64, fork+execve ×4000/mode, median of 3)

ns **per BPF-program invocation** (kernel `run_time_ns/run_cnt`). A
fork+execve+exit fires four of our programs once each, so `sum/cmd` is
the eBPF cost added per command:

| mode | `trace_fork` | `check_execve` | `trace_execve` | `trace_exit` | sum/cmd |
|---|---|---|---|---|---|
| `one_level` | 80 | 328 | 2596 | 327 | **3331 ns** |
| `ancestry(8)` | 83 | 439 *(+111)* | 2613 | 343 | **3478 ns** |
| `propagate_on_fork` | 129 *(+49)* | 333 | 2610 | 258 | **3330 ns** |

Measured baseline: one Python `fork+execve(/bin/true)+wait` with eBPF
off ≈ **1.13 ms/op** on this (loaded) box → sum/cmd is ≈ **0.3 %**.

What the numbers say (lead with the absolute ns — the percentage's
denominator is a Python fork on one loaded host; a C/shell exec is
faster, so treat ~0.3 % as order-of-magnitude, the per-program ns as the
portable figure):

- **The enforcement-depth choice is not a perf differentiator.** The
  only depth-dependent program is `check_execve`: 328 ns (one_level) →
  439 ns (`ancestry(8)`, **+111 ns** for the 8-hop walk) → 333 ns
  (propagate, an own-PID lookup ≈ a parent lookup). `propagate` adds
  **+49 ns/fork** in `trace_fork`. Single-digit-to-low-hundreds of
  nanoseconds — negligible against any real command's process creation.
  So the **"cost of a full tree-shake" that motivated making this
  configurable is, empirically, nothing to worry about.**
- **The dominant eBPF cost is `trace_execve` (~2600 ns/execve), and it's
  identical across modes** — the existing execve-argument-capture
  tracepoint that feeds the Tier-1/2 classifier, unrelated to the depth
  feature. ~78 % of sum/cmd. If per-execve eBPF cost ever matters, *that*
  is the program to optimize, not the enforcement-depth branch.
- `propagate`'s +49 ns is the per-fork `threat_map` **gating lookup**
  paid by every fork in propagate mode — not the mark-*copy*, which
  only runs for descendants of a flagged command (rare, and strictly
  costlier; out of scope for this always-paid measurement).
- `trace_exit` (~300 ns) runs the GC `map_delete` on every process exit
  in every mode (the leak-safe, mode-independent reclaim from Phase 2).
  Aggregate ~0.03 % CPU even at thousands of exits/s — the leak-safety
  is the right trade.

Numbers are kernel/host-specific; a committed baseline + CI gate needs a
pinned runner first (same caveat as Tier A).

## eBPF enforcement depth — the configurable feature

Today the LSM block is **one level**: `threat_map[real_parent->tgid]`
is checked on each `execve` (`atty-guard/ebpf/atty_guard.bpf.c`). We add
two deeper modes and make the active mode runtime-selectable.

### The three modes

| Mode | Mechanism | Closes | Cost |
|---|---|---|---|
| `one_level` *(default)* | check immediate parent in `threat_map` | direct children of a marked PID | `check_execve` ~328 ns/execve (measured) |
| `ancestry(N)` | walk `real_parent` up to N hops (bounded loop, runtime `break` at configured depth), block if any ancestor is Critical | deeper descendants **while the process chain is intact** | the walk adds **~+111 ns/execve at N=8** (measured). Does **not** catch double-fork/daemonize (reparent to PID 1 severs the chain) |
| `propagate_on_fork` | `sched_process_fork` copies the parent's mark to the child; `sched_process_exit` GCs the entry; LSM checks the process's own (inherited) mark | **all** descendants incl. double-fork/daemonize (mark is copied before any reparenting) | per-fork `threat_map` gating lookup adds **~+49 ns/fork** (measured; the mark-copy itself runs only under an active mark); map-pressure under fork bombs |

### Mechanism — one `.bpf.o`, runtime-switchable

A new config map drives the branch so we ship a single program, not
three builds:

```c
struct { __uint(type, BPF_MAP_TYPE_ARRAY); __uint(max_entries, 1);
         __type(key, __u32); __type(value, struct enforce_cfg);
} enforce_cfg_map SEC(".maps");
// struct enforce_cfg { __u8 mode; __u8 max_depth; }
```

- LSM hook reads `enforce_cfg`: `one_level` → single parent lookup;
  `ancestry` → bounded walk to `MAX_ANCESTRY` (16) with a runtime
  `if (i >= depth) break;`; `propagate` → check own pid. (Implemented as
  a plain bounded loop — clang wouldn't fully unroll the pointer-chasing
  walk, but each `bpf_core_read` is a safe probe, so the verifier accepts
  the bounded form.)
- `sched_process_fork` / `sched_process_exit` programs are always
  *attached* but early-return unless `mode == propagate` — so they cost
  ~nothing in the other modes (confirmed: `trace_fork` early-returns at
  ~80 ns vs ~129 ns in propagate — see the Phase-3 results).
- **Map type (decided by measurement, not up front).** Phase 2 keeps
  `threat_map` as a plain `BPF_MAP_TYPE_HASH`. Under a fork bomb in
  propagate mode it fails open *at the cap* (new descendants past 16 384
  entries simply aren't marked — never a wrongful block). Switching to
  `BPF_MAP_TYPE_LRU_HASH` (evict-oldest) trades that for evicting the
  *root* mark instead; which is better is a Phase-3 `map_pressure`
  question, so we don't commit blind — consistent with the whole point
  of this suite.

### Marking-model note (propagate mode)

`one_level` / `ancestry` mark the long-lived **shell** PID and gate its
(direct / ancestral) children — correct, because the mark is sticky only
between the flagged command and the next clean line
(`security_guard.zig`). `propagate` ideally marks the **command's** PID
instead — propagating from the shell tags its entire future subtree for
the sticky window. **Phase 2 ships the kernel mechanism + config and
benchmarks all three depths; it does not yet change the Zig proxy's
shell-marking.** That's deliberate: per-mode *overhead* (the Phase-3
measurement that picks the default) is independent of which PID is
marked, and propagate's proxy-side semantics (mark the command, clear on
its exit) is a focused follow-up tracked separately. Until then,
propagate is opt-in and labelled experimental.

### Config surface

Daemon-side (`atty-guard`):

```toml
# /etc/atty-guard/config.toml
[enforcement]
depth = "one_level"   # "one_level" | "ancestry" | "propagate_on_fork"
ancestry_max_depth = 8
```

Plumbed as a Rust config (`[enforcement] depth` / `--enforcement-depth`)
→ written to `enforce_cfg` on startup. Default is `one_level` — the
**benchmark-confirmed** choice (Phase 3 showed the deeper modes are
near-free, so the default is picked on coverage/precision, not speed; see
the decision framework). `atty doctor` surfacing of the active mode is a
tracked follow-up.

## Decision framework

Filled from the Phase-3 measurements above. The headline: **per-mode
overhead is not a performance differentiator** (every mode is <0.5% of a
real fork+execve), so the choice is about *coverage vs. blast-radius*,
not speed.

| Use-case | Suggested mode | Rationale (from measurements) |
|---|---|---|
| Latency-sensitive / default | `one_level` | floor (`check_execve` ~328 ns/execve); blocks the flagged command itself (a direct child of the marked shell); precise — won't sweep in the shell's unrelated descendants during the sticky window |
| Defense-in-depth dev box | `ancestry(8)` | +~111 ns/execve — negligible — to also catch the flagged command's descendants while the chain is intact |
| High-security / CI runner | `propagate_on_fork` | +~49 ns/fork; full containment incl. double-fork/daemonize. Opt-in/experimental until the proxy marks the command PID (see the marking-model note) |

**Measured default: `one_level`.** Not because the deeper modes are
costly — they aren't — but because it's the zero-overhead floor, it's
backward-compatible, and it's the *precise* match for the current
shell-marking model (block exactly the flagged commands, not their whole
subtree while the mark is sticky). The data's real contribution is
removing *performance* as a reason to avoid `ancestry`/`propagate`: they
are near-free coverage upgrades an operator can opt into. The operator
picks; atty ships `one_level`.

There's a second, non-cost reason a shallow default is sound: **detection
is per-execve, not per-tree.** The `sys_enter_execve` tracepoint reports
*every* execve to the daemon, which classifies each link and may mark it;
the LSM then gates that link's direct child. So a *linear* deep chain
(`npm → node → sh`) is caught at whichever link trips a verdict —
`one_level` only ever needs to reach one hop. The case a tree-walk
genuinely adds is **detachment** (double-fork / daemonize reparents the
payload to PID 1 before its execve, severing the parent link) — that's
what `propagate_on_fork` closes. See the enforcement-depth bullet in
[`operator-workflow.md`](operator-workflow.md) (Threat model) for the
full reasoning.

## Phasing

1. ✅ **Phase 1 — harness.** `bench/` + `zig build bench` (Tier A),
   human table + `--json`. CI-safe. A committed baseline + a CI
   regression gate follow once a stable perf runner is picked (numbers
   are machine-specific, so a naive committed baseline would be noise).
2. ✅ **Phase 2 — eBPF modes + config.** `enforce_cfg` map, the
   three-mode LSM branch, `sched_process_fork`/`_exit` hooks, Rust
   `[enforcement]` config + `--enforcement-depth` CLI → the map. All
   three modes are behavior-validated under `make sandbox-ebpf` (not
   CI): `51` (one_level blocks a direct child), `55` (one_level allows a
   grandchild, ancestry blocks it), `56` (ancestry(2) allows a 4-deep
   descendant, propagate_on_fork blocks it). Deferred to follow-ups:
   the Zig command-pid marking for propagate (see the marking-model
   note), the LRU-vs-HASH map decision (Phase-3 `map_pressure`), and
   `atty doctor` surfacing of the active depth.
3. ✅ **Phase 3 — Tier-B benches + the matrix.** `57-ebpf-overhead`
   measures per-mode ns/invocation via the kernel's BPF run-time stats;
   the decision matrix + default are filled from it (one_level, confirmed
   by data). Still planned: `map_pressure` (which drives the LRU-vs-HASH
   call) and `pty_roundtrip`.

## See also

- `docs/operator-workflow.md` — the eBPF Threat model & limitations (what one-level does/doesn't stop).
- `docs/security-guard-design.md` — the V2-* tier architecture.
- `atty-guard/ebpf/atty_guard.bpf.c` — the LSM hook this extends.
