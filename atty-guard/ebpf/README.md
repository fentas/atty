# eBPF programs (V2-B)

Status: **design + skeleton (no auto-loading yet).** The userspace loader that drives this `.o` lands in a follow-up under the `ebpf` Cargo feature; for now this directory documents the planned shape and ships the kernel-side source so it's reviewable.

## What this does

Two BPF programs cooperating with the userspace daemon over two maps:

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
                  │  tracepoint:syscalls:sys_enter_execve│
                  │     ↳ emit event on ringbuf (async)  │
                  └─────────────────────────────────────┘
```

The LSM hook is the **sync** path: kernel blocks the execve() syscall and waits for our verdict. The tracepoint is the **async** path: every execve is logged for Tier-2 classification, may later upgrade the PID's threat level (which the LSM hook honours on the next execve).

## Why eBPF / why an LSM hook

The PTY proxy sees commands the user types into atty. It does NOT see:

- Postinstall scripts forked off `npm install` (the script's parent is `npm`, not atty's shell).
- Reverse shells started over a socket that never went through a PTY.
- Anything dropped via `at` / `cron` after the user logs out.

The eBPF LSM hook closes that gap: it fires on _every_ execve, traceable back to the kernel parent PID. atty marks `npm`'s PID as `High`, the hook gates every child execve on that map entry, and a postinstall reverse-shell trying to spawn `nc -e /bin/sh` gets `-EPERM` from the kernel BEFORE the binary loads.

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

## Run (when V2-B userspace lands)

```sh
atty-guard --enable-ebpf
# atty-guard: listening on /run/user/1000/atty-guard.sock (tier2=stub)
# atty-guard: eBPF: loaded atty_guard.bpf.o
# atty-guard: eBPF: attached lsm/bprm_check_security
# atty-guard: eBPF: attached tracepoint:syscalls:sys_enter_execve
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

## Safety / failure modes

- **BPF verifier rejects the program**: daemon falls back to in-memory mode + logs a warning. atty's UDS contract is unaffected; only the kernel-side enforcement is missing.
- **Daemon crashes**: BPF programs stay loaded (kernel-attached); without userspace draining the ringbuf, new events back up and `bpf_ringbuf_reserve` returns NULL — the programs degrade to "log nothing, allow everything" on the async side. The sync LSM path STILL functions because it reads the threat map directly; the only loss is async event collection. systemd-user `Restart=on-failure` brings the daemon back fast.
- **Kernel < 5.7**: feature detection at startup; daemon errors out cleanly when `--enable-ebpf` was passed.
- **No CAP_BPF**: same — error at startup with a clear message pointing at the systemd unit `AmbientCapabilities` config.

## Why not a custom kernel module

Stability and update cadence. A kernel module has to track kernel ABI changes; eBPF + CO-RE is portable across kernels with the same BTF available. The LSM hook surface is stable since 5.7 and the verifier guarantees the program can't crash the kernel — exactly the right safety boundary for a sidecar shipped by a userland tool.
