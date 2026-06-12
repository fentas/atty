// SPDX-License-Identifier: GPL-2.0
//
// atty-guard kernel-side eBPF program. Provides:
//
//   1. An LSM hook on `bprm_check_security` that gates execve when
//      the parent PID's threat level (read from a BPF hash map
//      atty-guard writes to over UDS) is Critical — returns -EPERM,
//      blocking the syscall.
//
//   2. A tracepoint on `sys_enter_execve` that copies metadata
//      (pid, ppid, comm[16], argv[0..127]) into a BPF ringbuf for
//      the userspace daemon to consume. Async signal — does NOT
//      block. Used for log-only / Warn flows.
//
// Build (V2-B; this PR ships the skeleton, build wiring follows):
//
//   clang -O2 -g -target bpf -D__TARGET_ARCH_x86 \
//       -I/usr/include/bpf \
//       -c atty_guard.bpf.c -o atty_guard.bpf.o
//
// CO-RE: include `vmlinux.h` (generated from kernel BTF) before any
// kernel types. Generated once with:
//
//   bpftool btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h

// vmlinux.h MUST come first — declares the kernel types
// (struct linux_binprm, struct task_struct, struct
// trace_event_raw_sys_enter, …) the programs below dereference.
// Generated via `bpftool btf dump file /sys/kernel/btf/vmlinux
// format c > vmlinux.h`. See the Makefile target.
#include "vmlinux.h"

#include <bpf/bpf_core_read.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

#ifndef EPERM
#define EPERM 1
#endif

// Match the userspace ThreatLevel enum byte-for-byte.
#define THREAT_LOW      0
#define THREAT_HIGH     1
#define THREAT_CRITICAL 2

// PID → threat level. Owned by userspace atty-guard; updated via
// `set_threat_level` RPCs from atty in `--ebpf-mode=block`. The
// LSM hook below reads it on every execve and EPERMs Critical.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 16384);
    __type(key, __u32);
    __type(value, __u8);
} threat_map SEC(".maps");

// PID → marked (value byte unused, presence is the signal). Owned
// by userspace in `--ebpf-mode=warn` — populated when a Block
// verdict comes in but the operator opted into warn-not-block. The
// LSM hook below emits a verdict=WARN event when a child execve's
// parent is in this map and ALLOWS the execve (no EPERM). Lets the
// operator pilot block-mode behaviour without killing real work.
//
// Separate from threat_map (Option A from #347) instead of a tagged
// value: BPF map values aren't CO-RE-relocated, so a struct
// value's layout depends on the .bpf.o build's compiler padding —
// two single-primitive maps avoid that whole class of drift.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 16384);
    __type(key, __u32);
    __type(value, __u8);
} warn_pids SEC(".maps");

// Ringbuf for async execve events. Sized at 1 MiB — plenty for the
// commit-rate of an interactive shell. Userspace drains in a loop.
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 20);
} events SEC(".maps");

// Tagged event union. `kind` discriminates which other fields are
// meaningful; `verdict` says what the LSM decided (only meaningful
// for kind=EXECVE — tracepoint hits and AF_ALG always carry
// VERDICT_TRACE). Kept POD + fixed-size so the ringbuf carries one
// entry shape regardless of source.
//
// Layout is hand-padded (no compiler-chosen padding bytes) so the
// userspace Rust mirror can `#[repr(C)]` it without surprises —
// total 156 bytes, same as before adding `verdict` (reclaimed one
// of the original three pad bytes).
#define EVENT_EXECVE       1
#define EVENT_AF_ALG       2 // AF_ALG socket() — used by copy.fail
                             // class kernel LPEs (algif_aead).

#define VERDICT_TRACE      0 // Async log path (tracepoint hits).
#define VERDICT_WARN       1 // LSM hook saw warn_pids match;
                             // allowed the execve.
#define VERDICT_BLOCK      2 // LSM hook saw threat_map=Critical;
                             // returned -EPERM.

struct execve_event {
    __u8  kind;           // EVENT_EXECVE / EVENT_AF_ALG
    __u8  verdict;        // VERDICT_TRACE / VERDICT_WARN / VERDICT_BLOCK
    __u8  _pad[2];
    __u32 pid;
    __u32 ppid;
    char  comm[16];
    char  argv0[128];     // EVENT_EXECVE: first argv. EVENT_AF_ALG: unused.
};

// LSM hook — fires after the kernel has resolved the new program
// but before execve() succeeds. Returning a non-zero value rejects
// the syscall with that errno.
//
// Threat-map pivot: lookup by the PARENT PID, not the current one.
// `bpf_get_current_pid_tgid()` returns the execve'ing task (the
// child-to-be); the threat model marks the parent (e.g. `npm`,
// `sudo`) so its DIRECT children's execve is gated. We read
// `task->real_parent->tgid` via BPF CO-RE.
//
// LIMITATION — one level only: this gates a marked PID's direct
// children, NOT deeper descendants. `npm`(marked) → `node`(gated) →
// `sh`(NOT gated: its real_parent is `node`, which isn't in the map),
// and any double-fork / `nohup … &` / daemonize reparents the
// descendant to PID 1 and drops the mark entirely. Deepening this to
// a bounded ancestry walk (or propagating the mark on fork) is
// future work; a verifier-safe loop here needs care and a kernel to
// test against. Until then the userspace warn-subscriber's PPid-chain
// walk (warn_consumer.rs::pid_in_tree_root) provides the deeper-tree
// view for warn-mode telemetry (atty-guard/src/warn_consumer.rs,
// `pid_in_tree_root`); the kernel BLOCK is one level.
//
// Comm note: at bprm_check_security time the kernel hasn't yet
// updated the new binary's comm — `bpf_get_current_comm` returns
// the CALLING task's comm (the parent). Userspace must NOT assume
// `comm` = the binary about to load; we keep it as a diagnostic
// breadcrumb only.
SEC("lsm/bprm_check_security")
int BPF_PROG(check_execve, struct linux_binprm *bprm)
{
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    struct task_struct *parent = NULL;
    bpf_core_read(&parent, sizeof(parent), &task->real_parent);
    __u32 parent_pid = 0;
    if (parent)
        bpf_core_read(&parent_pid, sizeof(parent_pid), &parent->tgid);

    __u32 child_pid = bpf_get_current_pid_tgid() >> 32;
    __u8 *level = bpf_map_lookup_elem(&threat_map, &parent_pid);

    if (level && *level == THREAT_CRITICAL) {
        // Emit a "blocked" event before refusing so the daemon can
        // surface the reason in atty's banner.
        struct execve_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
        if (e) {
            e->kind = EVENT_EXECVE;
            e->verdict = VERDICT_BLOCK;
            e->pid = child_pid;
            e->ppid = parent_pid;
            bpf_get_current_comm(e->comm, sizeof(e->comm));
            e->argv0[0] = '\0';
            bpf_ringbuf_submit(e, 0);
        }
        return -EPERM;
    }

    // warn_pids takes effect only when threat_map didn't match —
    // block always wins so an operator transitioning from warn to
    // block on the same PID doesn't see a window where both states
    // race.
    __u8 *warn = bpf_map_lookup_elem(&warn_pids, &parent_pid);
    if (warn) {
        struct execve_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
        if (e) {
            e->kind = EVENT_EXECVE;
            e->verdict = VERDICT_WARN;
            e->pid = child_pid;
            e->ppid = parent_pid;
            bpf_get_current_comm(e->comm, sizeof(e->comm));
            e->argv0[0] = '\0';
            bpf_ringbuf_submit(e, 0);
        }
        // No EPERM — warn mode logs the would-have-blocked event
        // for operator visibility but lets the execve proceed.
    }

    return 0;
}

// Tracepoint — async log of every execve. Userspace runs Tier-2
// classification on the event and may later upgrade the PID's
// threat level via `set_threat_level`, which the LSM hook above
// will honour on the NEXT execve.
SEC("tracepoint/syscalls/sys_enter_execve")
int trace_execve(struct trace_event_raw_sys_enter *ctx)
{
    struct execve_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e)
        return 0;

    // sys_enter_execve args:
    //   args[0] = const char __user *filename
    //   args[1] = const char __user *const __user *argv
    //   args[2] = const char __user *const __user *envp
    // The previous comment was misleading; argv is args[1].
    e->kind = EVENT_EXECVE;
    e->verdict = VERDICT_TRACE;
    e->pid = bpf_get_current_pid_tgid() >> 32;

    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    struct task_struct *parent = NULL;
    bpf_core_read(&parent, sizeof(parent), &task->real_parent);
    e->ppid = 0;
    if (parent)
        bpf_core_read(&e->ppid, sizeof(e->ppid), &parent->tgid);

    bpf_get_current_comm(e->comm, sizeof(e->comm));

    // First argv element — best-effort copy. Userspace fans out to
    // /proc/<pid>/cmdline for the full vector.
    const char *const *argv = (const char *const *)ctx->args[1];
    const char *arg0 = NULL;
    bpf_probe_read_user(&arg0, sizeof(arg0), argv);
    if (arg0)
        bpf_probe_read_user_str(e->argv0, sizeof(e->argv0), arg0);
    else
        e->argv0[0] = '\0';

    bpf_ringbuf_submit(e, 0);
    return 0;
}

// AF_ALG socket() watcher — kernel-side detector for copy.fail-class
// LPEs (CVE-2026-31431 and adjacent algif_aead misuse). The exploit
// MUST create an AF_ALG socket to reach the splice()-into-page-cache
// gadget; normal interactive shells essentially never do this. Any
// hit is a worth-surfacing signal.
//
// We don't BLOCK the syscall here (would break legitimate users like
// `cryptsetup` and crypto unit tests); the LSM `socket_create` hook
// is the right place for blocking. This tracepoint just logs to the
// ringbuf so userspace can upgrade the calling PID's threat level
// and/or notify the user via atty's banner.
//
// sys_enter_socket args:
//   args[0] = int family   (AF_ALG = 38)
//   args[1] = int type
//   args[2] = int protocol
#define AF_ALG 38

SEC("tracepoint/syscalls/sys_enter_socket")
int trace_socket(struct trace_event_raw_sys_enter *ctx)
{
    int family = (int)ctx->args[0];
    if (family != AF_ALG)
        return 0;

    struct execve_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e)
        return 0;

    e->kind = EVENT_AF_ALG;
    e->verdict = VERDICT_TRACE;
    e->pid = bpf_get_current_pid_tgid() >> 32;

    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    struct task_struct *parent = NULL;
    bpf_core_read(&parent, sizeof(parent), &task->real_parent);
    e->ppid = 0;
    if (parent)
        bpf_core_read(&e->ppid, sizeof(e->ppid), &parent->tgid);

    bpf_get_current_comm(e->comm, sizeof(e->comm));
    e->argv0[0] = '\0';

    bpf_ringbuf_submit(e, 0);
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
