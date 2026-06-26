---
layout: default
title: Benchmarking
permalink: /benchmarking/
---

# atty — benchmarking

> **Status (2026-06): plan-of-record + in-progress.** Phase 1 (the
> `zig build bench` harness) is the first deliverable; the eBPF
> enforcement-depth modes (Phase 2) are measured by it.

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
tight loops over the hot paths and prints `ns/op` + bytes allocated
(via a counting allocator, to assert the zero-alloc claim):

| Benchmark | Measures | Asserts |
|---|---|---|
| `dispatch_input` | one keystroke through the module chain (`Dispatcher(modules).dispatchInput`) | ns/op, **0 allocs** |
| `ghost_text` | `provideGhostText` over a warm history ring (prefix match) | ns/op |
| `line_state` | `LineState.applyInput` for printable / CSI / paste bursts | ns/op, 0 allocs |
| `keymap_match` | CSI-u + legacy binding scan | ns/op |
| `output_throughput` | `onOutput` over a multi-KiB shell chunk (mouse-ring ingest, SGR strip) | MB/s |
| `atom_scan` (guard) | Aho-Corasick scan of a command line vs the atom corpus | ns/op |

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
under the existing eBPF sandbox (`make sandbox-ebpf`), not GitHub CI:

| Benchmark | Measures |
|---|---|
| `execve_block_<mode>` | added `execve` latency under each enforcement depth (fork+exec `/bin/true` ×N under a marked shell) |
| `fork_overhead` | added `fork` latency from the `sched_process_fork` hook (propagate mode only) |
| `map_pressure` | `threat_map` growth + lookup cost under a deep/wide descendant tree |
| `pty_roundtrip` | end-to-end keystroke→echo latency through the proxy |

These emit the same table/JSON shape as Tier A so results compose into
one report.

## eBPF enforcement depth — the configurable feature

Today the LSM block is **one level**: `threat_map[real_parent->tgid]`
is checked on each `execve` (`atty-guard/ebpf/atty_guard.bpf.c`). We add
two deeper modes and make the active mode runtime-selectable.

### The three modes

| Mode | Mechanism | Closes | Cost |
|---|---|---|---|
| `one_level` *(today)* | check immediate parent in `threat_map` | direct children of a marked PID | 1 map lookup / execve |
| `ancestry(N)` | walk `real_parent` up to N hops (verifier-safe unroll, runtime `break` at configured depth), block if any ancestor is Critical | deeper descendants **while the process chain is intact** | ≤ N map lookups + CO-RE reads / execve. Does **not** catch double-fork/daemonize (reparent to PID 1 severs the chain) |
| `propagate_on_fork` | `sched_process_fork` copies the parent's mark to the child; `sched_process_exit` GCs the entry; LSM checks the process's own (inherited) mark | **all** descendants incl. double-fork/daemonize (mark is copied before any reparenting) | per-fork map write + per-exit delete; map-pressure under fork bombs |

### Mechanism — one `.bpf.o`, runtime-switchable

A new config map drives the branch so we ship a single program, not
three builds:

```c
struct { __uint(type, BPF_MAP_TYPE_ARRAY); __uint(max_entries, 1);
         __type(key, __u32); __type(value, struct enforce_cfg);
} enforce_cfg_map SEC(".maps");
// struct enforce_cfg { __u8 mode; __u8 max_depth; }
```

- LSM hook reads `enforce_cfg`: `one_level` → current single lookup;
  `ancestry` → `#pragma unroll` to `MAX_ANCESTRY` (compile-time bound,
  e.g. 16) with `if (i >= cfg.max_depth) break;`; `propagate` → check
  own pid.
- `sched_process_fork` / `sched_process_exit` programs are always
  *attached* but early-return unless `mode == propagate` — so they cost
  ~nothing in the other modes (measured by `fork_overhead`).
- `threat_map` becomes `BPF_MAP_TYPE_LRU_HASH` for fork-bomb safety in
  propagate mode (eviction fails open — a missed descendant is a missed
  block, never a wrongful one). Confirm the LRU overhead is negligible
  for the other modes via `map_pressure`.

### Marking-model note (propagate mode)

`one_level` / `ancestry` mark the long-lived **shell** PID and gate its
(direct / ancestral) children — correct, because the mark is sticky only
between the flagged command and the next clean line
(`security_guard.zig`). `propagate` must instead mark the **command's**
PID, not the shell — propagating from the shell would tag its entire
future subtree. This is the one Zig-side change the deepest mode needs;
`one_level`/`ancestry` are kernel-only.

### Config surface

Daemon-side (`atty-guard`):

```toml
# /etc/atty-guard/config.toml
[enforcement]
depth = "one_level"   # "one_level" | "ancestry" | "propagate"
ancestry_max_depth = 8
```

Plumbed as a Rust `EnforcementDepth` enum → written to `enforce_cfg_map`
on startup and `--reload`. Surfaced by `atty-guard --print-features` and
`atty doctor` so the active mode is visible. Defaults to the
**benchmark-chosen** value once Phase 2 lands (provisionally
`one_level`, the zero-overhead floor).

## Decision framework

The suite produces a per-mode overhead table on representative kernels;
from it we publish a recommendation matrix, e.g.:

| Use-case | Suggested mode | Rationale (filled from measurements) |
|---|---|---|
| Latency-sensitive interactive shell | `one_level` | floor overhead; blocks the flagged command itself |
| Defense-in-depth dev box | `ancestry(8)` | catches deep descendants; bounded per-execve cost |
| High-security / CI runner | `propagate_on_fork` | full containment incl. detach; accepts fork-time cost |

The operator picks; atty ships the measured default.

## Phasing

1. **Phase 1 — harness.** `bench/` + `zig build bench` (Tier A), human
   table + `--json`. CI-safe; ships first. A committed baseline + a CI
   regression gate follow once a stable perf runner is picked (numbers
   are machine-specific, so a naive committed baseline would be noise).
2. **Phase 2 — eBPF modes + config.** `enforce_cfg` map, the three-mode
   branch, fork/exit hooks, LRU map, Rust `EnforcementDepth` plumbing,
   the Zig command-pid marking for propagate, doctor surfacing. Validated
   under `make sandbox-ebpf` (not CI).
3. **Phase 3 — Tier-B benches + the matrix.** Sandbox bench scenarios
   for per-mode `execve`/`fork` overhead, then fill the decision matrix
   and set the default.

## See also

- `docs/operator-workflow.md` — the eBPF Threat model & limitations (what one-level does/doesn't stop).
- `docs/security-guard-design.md` — the V2-* tier architecture.
- `atty-guard/ebpf/atty_guard.bpf.c` — the LSM hook this extends.
