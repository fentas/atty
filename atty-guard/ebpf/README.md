# eBPF programs (V2-B)

Status: **shipped, opt-in.** Build the daemon with `--features ebpf` (or `make install-guard GUARD_FEATURES=…,ebpf`) and launch with `--enable-ebpf` to load these programs. The kernel-side source lives here; the userspace loader is in [`atty-guard/src/ebpf.rs`](../src/ebpf.rs).

## What this does

BPF programs cooperating with the userspace daemon over its maps:

- `lsm/bprm_check_security` — sync execve gating against the threat map; also emits the Warn/Block events the daemon consumes.
- `tracepoint:syscalls:sys_enter_socket` — **AF_ALG socket() detector**, kernel-side signal for copy.fail-class LPEs (CVE-2026-31431 + adjacent algif_aead misuse). Interactive shells essentially never open AF_ALG sockets; any hit is worth surfacing.
- `tracepoint:sched:sched_process_fork` / `sched_process_exit` — propagate-on-fork mark maintenance (copy a Critical mark onto children; GC on exit) for the `propagate` enforcement depth.

(A former every-execve `sys_enter_execve` log program was removed — its per-execve events were unconsumed; see git log.)

```
                  ┌─────────────────────────────────────┐
                  │  atty-guard (userspace, this crate) │
                  │                                     │
                  │   classify(...) │ set_threat_level  │
                  └────────┬────────┴─────────┬─────────┘
                           │                  │ writes
                           │                  ▼
                           │       ┌────────────────────┐
              ringbuf read │       │   threat_map       │
                           │       │   PID → ThreatLevel │
                           ▼       │   (BPF_MAP_TYPE_HASH)│
                  ┌─────────────────────────────────────┐
                  │  KERNEL — eBPF programs              │
                  │                                     │
                  │  lsm/bprm_check_security             │
                  │     ↳ read threat_map[parent_pid]    │
                  │     ↳ if Critical: return -EPERM     │
                  │     ↳ emit blocked event on ringbuf  │
                  │                                     │
                  │  tracepoint: AF_ALG socket + sched   │
                  │     ↳ fork: copy mark; exit: GC      │
                  └─────────────────────────────────────┘
```

The LSM hook is the **sync** path: the kernel blocks the execve() syscall and waits for our verdict, and the hook emits the Warn/Block events the daemon's ringbuf consumer reads. The sched fork/exit tracepoints maintain the propagate-on-fork mark; the AF_ALG tracepoint is a standalone detector. (A former every-execve `sys_enter_execve` log program was removed — its events were unconsumed.)

## Why eBPF / why an LSM hook

The PTY proxy sees commands the user types into atty. It does NOT see:

- Postinstall scripts forked off `npm install` (the script's parent is `npm`, not atty's shell).
- Reverse shells started over a socket that never went through a PTY.
- Anything dropped via `at` / `cron` after the user logs out.

The eBPF LSM hook closes that gap: it fires on _every_ execve and checks the execve'ing task's **direct parent** against the threat map. atty marks `npm`'s PID as `Critical`, the hook gates `npm`'s immediate children, and a postinstall reverse-shell that `npm` spawns directly to run `nc -e /bin/sh` gets `-EPERM` from the kernel BEFORE the binary loads. (Only `Critical` returns `-EPERM`; a `High`/warn mark emits a warn event without blocking — see the verdict handling in `check_execve`.)

**Scope — one level:** the BLOCK check is keyed on the *direct* parent's PID, so it gates a marked PID's immediate children only, not deeper descendants. A grandchild (`npm` → `node` → `sh`) or a double-forked / reparented process (now a child of PID 1) escapes the kernel block. Warn-mode telemetry walks the full PPid chain in userspace (`atty-guard/src/warn_consumer.rs`, `pid_in_tree_root`) and so sees deeper trees; a verifier-safe bounded ancestry walk (or fork-time mark propagation) for the BLOCK path is future work. See the comment above `check_execve` in `atty_guard.bpf.c`.

## Prerequisites

| Component       | Version            | Notes                                                            |
|-----------------|--------------------|------------------------------------------------------------------|
| Kernel          | ≥ 5.7              | `lsm/bprm_check_security` BPF attach was added in 5.7.           |
| BTF             | enabled            | `/sys/kernel/btf/vmlinux` must exist. CO-RE needs it.            |
| LSM             | bpf enabled        | Boot kernel with `lsm=bpf,...` (Arch and Debian default include).|
| `clang`         | ≥ 14               | Needed for BPF CO-RE relocations.                                |
| `bpftool`       | recent             | For `bpftool btf dump file ... format c > vmlinux.h`.            |
| `libbpf-dev`    | shipped with distro| Kernel BPF helper headers.                                       |
| `CAP_BPF`       | on the daemon      | systemd unit will add `AmbientCapabilities=CAP_BPF CAP_SYS_RESOURCE`. |

## Build

```sh
cd atty-guard/ebpf
make vmlinux.h         # one-time, regenerate when kernel updates
make
# → produces atty_guard.bpf.o
```

The output `.o` ships alongside the daemon binary. Userspace finds it via `dirname(argv[0])/atty_guard.bpf.o` first, then `/usr/lib/atty-guard/atty_guard.bpf.o` as a fallback.

## Run

```sh
atty-guard --enable-ebpf
# atty-guard: listening on /run/atty-guard/atty-guard.sock (tier2=stub)
# atty-guard: eBPF: loaded atty_guard.bpf.o
# atty-guard: eBPF: attached lsm/bprm_check_security
# atty-guard: eBPF: attached tracepoint:syscalls:sys_enter_socket (AF_ALG)
```

Without `--enable-ebpf`, the daemon behaves exactly as in V2-A — in-memory threat map, no kernel-side enforcement, but the UDS protocol stays the same. atty doesn't need to know whether the eBPF path is active.

## Migration path for the threat map

V2-A: `Mutex<HashMap<u32, ThreatLevel>>` in-memory, owned by `threat_map.rs`.

V2-B: same trait surface, backed by a `libbpf_rs::Map` of kind `BPF_MAP_TYPE_HASH` so the kernel-side LSM hook reads the same record atty wrote. The Rust `ThreatMap` struct grows a backend enum:

```rust
enum ThreatMapBackend {
    Memory(Mutex<HashMap<u32, ThreatLevel>>),
    Bpf(libbpf_rs::Map),
}
```

`set`/`get` dispatch on the variant. No external API change.

### Concurrent access on the BPF hash map (TODO)

`BPF_MAP_TYPE_HASH` is RCU-protected on the kernel side: per-CPU read fast paths, writes go through a lock. From userspace the libbpf `update`/`lookup` calls are individually atomic but a read-modify-write sequence is not. The V2-B impl needs to decide:

1. **Last-write-wins** (current design) — atty fires `set_threat_level` for a PID; whatever fires last is what the next LSM hook sees. Acceptable because atty's writes are per-Enter, not in tight loops.
2. **Optimistic transactions** with the `bpf_map_lookup_and_delete_elem` family — overkill for this workload.

Going with (1) for now; track this paragraph as the "we did consider it" record. Atomicity per-key is what the LSM hook actually needs.

## Safety / failure modes

- **BPF verifier rejects the program**: daemon falls back to in-memory mode + logs a warning. atty's UDS contract is unaffected; only the kernel-side enforcement is missing.
- **Daemon crashes**: BPF programs stay loaded (kernel-attached); without userspace draining the ringbuf, new events back up and `bpf_ringbuf_reserve` returns NULL — the programs degrade to "log nothing, allow everything" on the async side. The sync LSM path STILL functions because it reads the threat map directly; the only loss is async event collection. systemd `Restart=on-failure` (set in the shipped system unit) brings the daemon back fast.
- **Kernel < 5.7**: feature detection at startup; daemon errors out cleanly when `--enable-ebpf` was passed.
- **No CAP_BPF**: same — error at startup with a clear message pointing at the systemd unit `AmbientCapabilities` config.

## Why not a custom kernel module

Stability and update cadence. A kernel module has to track kernel ABI changes; eBPF + CO-RE is portable across kernels with the same BTF available. The LSM hook surface is stable since 5.7 and the verifier guarantees the program can't crash the kernel — exactly the right safety boundary for a sidecar shipped by a userland tool.
