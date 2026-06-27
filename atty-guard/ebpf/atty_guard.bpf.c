// SPDX-License-Identifier: GPL-2.0
//
// atty-guard kernel-side eBPF program. Provides:
//
//   1. An LSM hook on `bprm_check_security` that gates execve when
//      the parent PID's threat level (read from a BPF hash map
//      atty-guard writes to over UDS) is Critical — returns -EPERM,
//      blocking the syscall.
//
//   2. Tracepoints on `socket(AF_ALG)` (a copy.fail-class LPE signal)
//      and `sched_process_fork` / `_exit` (propagate-on-fork mark
//      maintenance). The LSM hook above emits the Warn/Block events the
//      daemon consumes; there is no every-execve trace program — its
//      output went unconsumed, so it was removed (see git log).
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

// Enforcement depth — how far the LSM hook looks for a Critical mark.
// Selected at runtime by userspace via the `enforce_cfg` map (below);
// an unset map reads back zero == ENFORCE_ONE_LEVEL, the historical
// behavior, so a daemon that never writes the config still works.
#define ENFORCE_ONE_LEVEL 0 // gate a marked PID's direct children only
#define ENFORCE_ANCESTRY  1 // walk up to cfg.max_depth ancestors
#define ENFORCE_PROPAGATE 2 // mark propagates on fork; check own PID

// Compile-time ceiling on the ancestry walk — a larger runtime
// cfg.max_depth is truncated here (the walk just stops at 16). Bounded
// so the verifier accepts the (non-unrolled, pointer-chasing) loop.
#define MAX_ANCESTRY 16

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

// Enforcement config — single-entry array written by userspace at
// startup / reload. CO-RE doesn't relocate map *values*, so the layout
// is hand-fixed (matches the Rust writer's byte order: mode, max_depth,
// then padding to 8 bytes).
struct enforce_config {
    __u8 mode;      // ENFORCE_ONE_LEVEL / _ANCESTRY / _PROPAGATE
    __u8 max_depth; // ancestry ceiling; kernel walks at most MAX_ANCESTRY
    __u8 _pad[6];
};

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct enforce_config);
} enforce_cfg SEC(".maps");

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

// Resolve the active enforcement config. An unset map reads back the
// array's zero value → ENFORCE_ONE_LEVEL with depth forced to 1, so a
// daemon that never writes the config keeps the historical behavior.
static __always_inline void read_enforce(struct enforce_config *out)
{
    __u32 k = 0;
    struct enforce_config *cfg = bpf_map_lookup_elem(&enforce_cfg, &k);
    if (cfg) {
        out->mode = cfg->mode;
        out->max_depth = cfg->max_depth;
    } else {
        out->mode = ENFORCE_ONE_LEVEL;
        out->max_depth = 1;
    }
}

// Does this execve's lineage carry a Critical mark under the active
// mode? Returns the matching threat_map key (for the event), else 0.
//
//   one_level : the immediate parent's tgid — the historical pivot.
//   ancestry  : the nearest Critical ancestor within cfg.max_depth. A
//               double-fork that reparents to PID 1 severs the chain
//               and escapes — which is why `propagate` exists.
//   propagate : the task's OWN pid — the mark was copied onto it at
//               fork (see trace_fork), so deeper descendants AND
//               double-forked daemons stay covered.
static __always_inline __u32 critical_match(struct task_struct *task)
{
    struct enforce_config cfg;
    read_enforce(&cfg);

    if (cfg.mode == ENFORCE_PROPAGATE) {
        __u32 self = bpf_get_current_pid_tgid() >> 32;
        __u8 *lvl = bpf_map_lookup_elem(&threat_map, &self);
        if (lvl && *lvl == THREAT_CRITICAL)
            return self;
        return 0;
    }

    // one_level walks exactly one hop; ancestry walks up to max_depth.
    // one_level ignores cfg.max_depth so a zero-valued (unwritten) map
    // can't accidentally disable it. A bounded loop (i < MAX_ANCESTRY)
    // is verifier-safe on its own — each bpf_core_read is a safe probe,
    // so the chain walk doesn't need full unrolling.
    __u32 depth = (cfg.mode == ENFORCE_ANCESTRY) ? cfg.max_depth : 1;
    struct task_struct *p = task;
    for (int i = 0; i < MAX_ANCESTRY; i++) {
        if ((__u32)i >= depth)
            break;
        struct task_struct *parent = NULL;
        bpf_core_read(&parent, sizeof(parent), &p->real_parent);
        if (!parent)
            break;
        __u32 ppid = 0;
        bpf_core_read(&ppid, sizeof(ppid), &parent->tgid);
        if (ppid <= 1)
            break; // reached init — chain root, nothing above
        __u8 *lvl = bpf_map_lookup_elem(&threat_map, &ppid);
        if (lvl && *lvl == THREAT_CRITICAL)
            return ppid;
        p = parent;
    }
    return 0;
}

// LSM hook — fires after the kernel resolves the new program but
// before execve() succeeds. A non-zero return rejects the syscall.
// `critical_match` decides, per the configured depth, whether this
// execve descends from a marked process.
//
// Comm note: at bprm_check_security the kernel hasn't updated the new
// binary's comm yet — `bpf_get_current_comm` returns the CALLING
// task's comm. Diagnostic breadcrumb only.
SEC("lsm/bprm_check_security")
int BPF_PROG(check_execve, struct linux_binprm *bprm)
{
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    __u32 child_pid = bpf_get_current_pid_tgid() >> 32;

    __u32 flagged = critical_match(task);
    if (flagged) {
        // Emit a "blocked" event before refusing so the daemon can
        // surface the reason in atty's banner.
        struct execve_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
        if (e) {
            e->kind = EVENT_EXECVE;
            e->verdict = VERDICT_BLOCK;
            e->pid = child_pid;
            e->ppid = flagged;
            bpf_get_current_comm(e->comm, sizeof(e->comm));
            e->argv0[0] = '\0';
            bpf_ringbuf_submit(e, 0);
        }
        return -EPERM;
    }

    // warn_pids stays one-level (parent pivot) regardless of block
    // depth — it's a pilot signal, not enforcement. Block always wins
    // above, so a warn→block transition on the same PID has no race.
    struct task_struct *parent = NULL;
    bpf_core_read(&parent, sizeof(parent), &task->real_parent);
    __u32 parent_pid = 0;
    if (parent)
        bpf_core_read(&parent_pid, sizeof(parent_pid), &parent->tgid);

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
        // No EPERM — warn logs the would-have-blocked event but allows.
    }

    return 0;
}

// Fork propagation — only active in ENFORCE_PROPAGATE. When a marked
// process forks, copy its threat level onto the child's PID so the
// child's later execve is gated by `critical_match`'s own-PID check.
// The copy happens at fork, BEFORE any double-fork/daemonize can
// reparent the descendant away — that's what closes the detach gap a
// pure ancestry walk can't. No-op (one extra map lookup) in the other
// modes so they don't pay for propagation they don't use.
SEC("tracepoint/sched/sched_process_fork")
int trace_fork(struct trace_event_raw_sched_process_fork *ctx)
{
    __u32 k = 0;
    struct enforce_config *cfg = bpf_map_lookup_elem(&enforce_cfg, &k);
    if (!cfg || cfg->mode != ENFORCE_PROPAGATE)
        return 0;

    __u32 parent = (__u32)ctx->parent_pid;
    __u32 child = (__u32)ctx->child_pid;
    __u8 *lvl = bpf_map_lookup_elem(&threat_map, &parent);
    // Only a Critical mark is worth propagating — that's the one the LSM
    // hook blocks on. Copying High/annotation levels would churn the map
    // with entries critical_match never acts on.
    if (lvl && *lvl == THREAT_CRITICAL) {
        __u8 v = *lvl;
        bpf_map_update_elem(&threat_map, &child, &v, BPF_ANY);
    }
    return 0;
}

// Exit GC — drop a process's threat_map entry when its thread-group
// leader exits, in EVERY mode. propagate mode NEEDS it (the kernel owns
// the fork-propagated entries); one_level / ancestry entries are
// userspace-owned, but deleting on exit is still correct (the PID is
// gone) and means propagated entries can't leak if the operator ever
// switches modes. Cost is one hash delete per process exit — usually a
// miss, negligible. Not gated on enforce_cfg so it stays correct
// independent of the active depth.
SEC("tracepoint/sched/sched_process_exit")
int trace_exit(struct trace_event_raw_sched_process_template *ctx)
{
    __u64 pt = bpf_get_current_pid_tgid();
    __u32 tgid = (__u32)(pt >> 32);
    __u32 tid = (__u32)pt;
    if (tgid == tid) // process (leader) exit, not a bare thread
        bpf_map_delete_elem(&threat_map, &tgid);
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
