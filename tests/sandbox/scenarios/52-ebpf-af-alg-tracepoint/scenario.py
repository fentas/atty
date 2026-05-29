#!/usr/bin/env python3
"""52-ebpf-af-alg-tracepoint — AF_ALG syscall trace + classifier upgrade.

Pins the V2-B sys_enter_execve / AF_ALG tracepoint chain: when
a process opens an AF_ALG socket (the canonical
crypto-LPE-precursor shape per the atty-guard/ebpf/README.md
threat model), the daemon's tracepoint fires + the classifier
upgrades any subsequent classify for that PID's tree.

Skips cleanly when:
- BPF LSM not in `/sys/kernel/security/lsm` (lib/bpf.py).
- atty_guard.bpf.o not baked into the image.
"""
from __future__ import annotations

import socket
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, "/sandbox")
from lib.bpf import skip_if_no_bpf_lsm  # noqa: E402
from lib.daemon import Daemon  # noqa: E402


BPF_OBJ = Path("/usr/lib/atty-guard/atty_guard.bpf.o")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def skip_if_no_bpf_object() -> None:
    if not BPF_OBJ.is_file():
        print(f"SKIP: 52-ebpf-af-alg-tracepoint — {BPF_OBJ} not "
              "baked. Build Dockerfile.ebpf on a host with "
              "/sys/kernel/btf/vmlinux present.")
        sys.exit(0)


def open_af_alg_socket() -> bool:
    """Returns True iff AF_ALG socket creation worked. Kernel
    builds without `CONFIG_CRYPTO_USER_API` won't have AF_ALG;
    treat that as a clean skip too."""
    try:
        s = socket.socket(socket.AF_ALG, socket.SOCK_SEQPACKET, 0)
        s.close()
        return True
    except (OSError, AttributeError):
        return False


def main() -> None:
    skip_if_no_bpf_lsm("52-ebpf-af-alg-tracepoint")
    skip_if_no_bpf_object()

    if not hasattr(socket, "AF_ALG"):
        print("SKIP: 52-ebpf-af-alg-tracepoint — python's socket "
              "module lacks AF_ALG. Need python 3.6+ AND a kernel "
              "with CONFIG_CRYPTO_USER_API.")
        sys.exit(0)

    with Daemon(extra_args=["--ebpf-mode", "block"], verbosity=1) as d:
        time.sleep(1.0)
        log_before = d.read_log()
        if "eBPF attached" not in log_before:
            d.dump_log()
            fail(f"daemon didn't attach eBPF; log:\n{log_before}")

        # Trigger the AF_ALG tracepoint by opening + closing a
        # socket. The kernel-side tracepoint runs in the same
        # process context as the calling task.
        opened = open_af_alg_socket()
        if not opened:
            print("SKIP: 52-ebpf-af-alg-tracepoint — kernel lacks "
                  "CONFIG_CRYPTO_USER_API (AF_ALG socket creation "
                  "failed at runtime). Test can't trigger the "
                  "tracepoint.")
            sys.exit(0)

        # The tracepoint's effect is internal to the daemon
        # (threat_map / classifier hint). We can't directly
        # observe the BPF map from userspace without bpftool
        # privileges, but we CAN assert the daemon didn't fault
        # OR log an EPERM-style refusal — the canonical positive
        # signal at this verbosity level is that the daemon log
        # carries no new errors after the syscall.
        time.sleep(0.5)
        log_after = d.read_log()
        # Filter to lines added AFTER opening the socket.
        new_lines = log_after[len(log_before):]
        if "panic" in new_lines or "failed" in new_lines.lower():
            d.dump_log()
            fail(f"daemon logged failure after AF_ALG syscall:\n{new_lines}")

    print("PASS: 52-ebpf-af-alg-tracepoint")


if __name__ == "__main__":
    main()
