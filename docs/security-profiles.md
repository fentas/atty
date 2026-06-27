---
layout: default
title: Security profiles
permalink: /security-profiles/
---

# atty-guard — security profiles

> **Status (2026-06): design of record + Phases 1–2 landed.** The profile
> taxonomy, the routing policy (`smart`), and the primitive analysis
> below are settled. Phase 1 = the decision core (`profile.rs`) + config;
> Phase 2 = the WATCH scope + `audit`/`session` effectors (kernel +
> daemon). `strict` / `lockdown` / `smart`-dispatch are later phases (see
> Phasing). Don't re-derive the primitive trade-offs — they're here.

## The problem this solves

atty-guard's detection is **proxy-only**: the daemon learns a command is
dangerous when the atty prompt sends the *typed* command for
classification. A chain that **bypasses the prompt** — a compromised
dependency at runtime spawning `python → node → exploit` the user never
typed — is invisible. The kernel *sees* every exec but does not classify
them (the every-execve `trace_execve` log program was unconsumed and was
removed; see git log + `benchmarking.md`). This gap is pinned by
`tests/sandbox/scenarios/58-ebpf-detection-gap`.

Closing it means picking a *mechanism* to detect/act on non-proxy execs.
No single mechanism is best for every case — so we make the posture a
**user-chosen profile**, and add a `smart` profile that picks per-exec.

## The primitive matrix (why no single mechanism wins)

To *prevent* a malicious exec you must decide **before** it runs. The
candidates and what each can and can't do:

| Primitive | Sync (prevents)? | Argv-aware? | TOCTOU-safe? | Rich (Tier-2/SLM) classify? | Cost |
|---|:---:|:---:|:---:|:---:|---|
| LSM `check_execve` (today) | ✅ | ✅ (`bprm`) | ✅ | ❌ in-kernel only | ~free |
| LSM → ringbuf → kill | ❌ async/reactive | ✅ | ✅ | ✅ | low (scoped) |
| `seccomp-notify` | ✅ | ✅ | **❌ TOCTOU** | ✅ | med |
| `fanotify EXEC_PERM` | ✅ | **❌ binary only** | ✅ | ✅ (binary) | high (global) |
| LSM Tier-1 in-kernel | ✅ | ✅ (`bprm` match) | ✅ | ❌ Tier-1 only | low |
| **`SIGSTOP` post-exec** | ✅ | ✅ | ✅ | ✅ | operational risk |

Two findings drive the design:

- **`seccomp-notify` is TOCTOU-unsafe for execve.** It traps at syscall
  *entry*, before the kernel copies the args, so the supervisor reads the
  child's still-mutable userspace memory; a sibling thread can overwrite
  `innocent.js`→`malware.js` between check and use. The kernel docs say
  `USER_NOTIF_FLAG_CONTINUE` must not be a security control for
  pointer-arg syscalls. So seccomp-notify can gate *boolean* syscalls
  (ptrace, bpf) but **not** argv-dependent execve. Out for this purpose.

- **`SIGSTOP` post-exec is the *only* row that is sync + argv-aware +
  TOCTOU-safe + rich-classify** — because `execve` **collapses the
  thread group** (all sibling threads die on a successful exec). Freezing
  *after* the exec completes but *before* the entry point runs leaves a
  single-threaded process with **committed, immutable args** and **zero
  instructions executed**. `SIGSTOP` is unmaskable, so the payload can't
  dodge it. The daemon reads the real `/proc/<pid>/cmdline`, runs full
  Tier-1+Tier-2, then `SIGCONT` or `SIGKILL` before a single instruction.
  Its only cost is *operational* (process state), **not** a security
  hole — see `lockdown` below.

## The profile ladder

A profile is a **preset over real knobs** (`scope`, `timing`, `response`,
enforcement `depth`) — the same pattern as `defaults.zig`. Each rung is
labeled by the guarantee it *actually* gives (detection vs prevention),
never oversold.

| Profile | Mechanism | Guarantee | Cost / risk |
|---|---|---|---|
| **`prompt`** *(default)* | proxy pre-Enter only | typed-command **tripwire** | none |
| **`audit`** | WATCH-scoped async classify → log/warn | **detection** only, zero intervention | low; safe first rollout |
| **`session`** | WATCH-scoped async classify → **fast-kill** | **detect + rapid response** (reactive — kills *after* the exec started) | low; circuit-breaks to permissive under load |
| **`strict`** | **in-kernel** LSM Tier-1 match on `bprm` → `EPERM` | **sync prevention of known shapes**, no wedge | low; misses novel / SLM-only payloads |
| **`lockdown`** | WATCH-scoped `SIGSTOP` post-exec → full Tier-1+2 → `CONT`/`KILL`, **fail-closed** | **sync prevention, full classification, TOCTOU-safe** | **freezes/kills legit processes; fail-closed by design** |
| **`smart`** | per-exec routing (below) | the lightest sufficient guarantee per context | adaptive; degrades under load |

### Config

```toml
# /etc/atty-guard/config.toml
[profile]
mode = "smart"               # prompt | audit | session | strict | lockdown | smart
smart_allow_lockdown = false # let `smart` escalate to lockdown-grade freeze
```

Defaults: `mode = "prompt"`, `smart_allow_lockdown = false`. Every
non-`prompt` profile **fast-paths the certain cases** — clearly-safe
execs are allowed and Tier-1 known-bad is blocked in-kernel; only the
*ambiguous* execs pay the profile's heavier mechanism (`lockdown` freezes
*only* those, never every exec). The config knob `smart_allow_lockdown`
maps to the policy's `smart_can_freeze` ceiling.

**Capability note:** `session` (and `lockdown`) SIGKILL watched processes
that may belong to *other* users (the daemon runs as `atty`), which needs
**`CAP_KILL`** to bypass the same-uid signal check. Grant it via the
systemd unit (or a drop-in) when enabling those profiles — `audit` /
`prompt` don't need it (least privilege). Without it the kill is a no-op
and the daemon logs `session SIGKILL pid N failed … (need CAP_KILL?)`.

### Scope: the WATCH mark (reuses `propagate_on_fork`)

All non-`prompt` profiles bound their cost to the **atty-session
subtree** — the processes the terminal launched, where the user's actual
risk lives, and *not* system-wide `gcc`/`ld` from other contexts. The
mechanism reuses the `sched_process_fork` hook built for
`propagate_on_fork`: atty marks the shell `WATCH` (a non-blocking level
alongside `Critical`); the fork hook copies it to every descendant; the
kernel only emits classify-events / applies heavier mechanisms for
`WATCH`-marked PIDs. propagate's fork-propagation isn't just an
enforcement hammer — it's the scoping laser.

### `lockdown` is sound where generic "stop-and-frisk" is not

The classic objection to `SIGSTOP`-frisk (orphaned freezes on daemon
death, `waitpid` timeouts) is real — *and it is exactly the failure mode
`lockdown` wants*. "I'd rather a wedged process than a leak": a frozen
process is **not executing → not exfiltrating → no breach.** Daemon
down = subtree frozen = secure-but-wedged = **fail-closed**. The
property that disqualifies `SIGSTOP` as a *default* is the property that
qualifies it as an *opt-in maximum*. Guardrails make it deliberate:

- **WATCH-scoped** — only the opted-in session's subtree can freeze.
- **Fast-path Tier-1 first** — the 99% of execs clear in microseconds;
  only genuinely-suspicious ones pay the long Tier-2 freeze.
- **Fail-closed timeout + reconciliation watchdog** — a stop with no
  verdict in N ms → `KILL` (not `CONT`); on daemon restart, sweep the
  subtree's `T`-state processes and apply the policy.
- **Accuracy is the dial** — `lockdown`'s livability is a direct function
  of the classifier's false-positive rate. Ship Tier-1-conservative
  first (few wrongful kills); escalate to Tier-2 as accuracy proves out.

### Honest limit (every rung)

These gate **`execve`**. A compromised process that does damage
*in-process* (opens a socket, exfiltrates, no child exec) is invisible to
any exec-based rung — that needs syscall gating (seccomp on
`connect`/writes), a separate future axis. `lockdown` is the strongest
exec-based prevention, not omniscience.

## The `smart` profile — routing policy

`smart` picks the **lightest sufficient mechanism per exec** from the
classification verdict × context × load budget:

```
RoutingPolicy::decide(ctx) -> Mechanism:
  if not ctx.in_watch_scope:        Allow          # out of session scope
  match ctx.tier1:
    KnownBad   ->                   BlockInKernel   # sync, free, TOCTOU-safe
    Safe       ->                   Allow           # cheapest
    Suspicious | Unknown ->                         # ambiguous — escalate
      if not (ctx.is_interpreter and not ctx.parent_is_interactive_shell):
                                    Allow           # low-risk shape, don't pay
      else match ctx.load:
        High   ->                   WarnAsync       # back off: observe only
        Normal ->                   ClassifyAsyncThenKill   # or FreezeAndFrisk
                                                            # if lockdown-grade
```

Principles: known-bad is blocked *for free* in-kernel; the SLM/freeze
cost is paid *only* for the genuinely-ambiguous (interpreter spawned by a
non-shell parent); load pressure degrades gracefully (the circuit breaker
is a routing input). `smart` never silently *upgrades* past the operator's
ceiling — a `smart` daemon configured without `lockdown` consent won't
freeze; it tops out at `ClassifyAsyncThenKill`.

The routing is a pure function (`atty-guard/src/profile.rs::RoutingPolicy::decide`),
branch-only, allocation-free, called per in-scope exec — unit-tested over
the use-case matrix below.

## Phasing

1. ✅ **Phase 1 — decision core + config + docs (this).** `SecurityProfile`
   / `Mechanism` / `ExecContext` + `RoutingPolicy::decide` + config plumbing +
   exhaustive routing unit tests (the use-cases). No kernel effectors yet
   — `decide` returns the mechanism; dispatch is phased.
2. ✅ **Phase 2 — WATCH scope + `audit`/`session` effectors.** `watch_pids`
   map carries WATCH (propagated on every fork); `check_execve` emits a
   scoped, `bprm->filename`-read `VERDICT_CLASSIFY` event for WATCH'd
   execs only (not the deleted system-wide firehose); the daemon's
   ringbuf consumer fans out to `/proc/<pid>/cmdline`, classifies, and
   routes via `RoutingPolicy::decide` — `audit` surfaces a warn event,
   `session` reactively SIGKILLs. Marked via the `SetWatch` RPC
   (SO_PEERCRED-gated). Profiles need eBPF attached, so run the daemon
   with `--ebpf-mode observe` (or warn/block) + `[profile]`. Sandbox: `58`
   (gap, `prompt`) vs `59` (audit detects) vs `60` (session kills) on the
   same non-proxy chain.
3. **Phase 3 — `strict`.** Curated Tier-1 atom match in `check_execve` →
   sync `EPERM`. Sandbox + bench.
4. **Phase 4 — `lockdown`.** `bpf_send_signal(SIGSTOP)` post-exec for
   WATCH'd ambiguous execs + the fail-closed watchdog + reconciliation.
   Sandbox (incl. daemon-death-leaves-frozen) + bench (freeze latency).
5. **Phase 5 — `smart` dispatch + comparison.** Wire `decide` to the
   effectors; a sandbox matrix scenario + bench comparing all profiles on
   the same workload (the use-case comparison).

## Open questions

- WATCH scope via the fork-hook mark vs a per-session cgroup (delegation
  cost). Start with the mark (no new infra).
- `lockdown` watchdog: in-daemon timer + restart-sweep, or a separate
  minimal supervisor that survives daemon restarts?
- `smart` load signal source: classify-queue depth, run-queue, or a
  configured budget? (Decide by Phase-5 measurement.)
- Whether `smart` should learn (ML) the routing or stay a heuristic policy
  (start heuristic — predictable + testable).

## See also

- `docs/operator-workflow.md` — threat model + the enforcement-depth bullet.
- `docs/benchmarking.md` — the per-mode overhead numbers + the `trace_execve` removal.
- `atty-guard/ebpf/atty_guard.bpf.c` — the LSM hook + the fork/exit + AF_ALG tracepoints.
