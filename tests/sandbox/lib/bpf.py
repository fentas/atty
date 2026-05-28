"""BPF LSM availability probe for sandbox scenarios.

eBPF scenarios are inherently kernel-conditional — the LSM hook
that atty-guard installs (`lsm/bprm_check_security`) needs the
kernel to have BPF LSM enabled at boot. GH-hosted ubuntu runners
historically ship without it; the same scenarios shouldn't fail
loudly on those runners, they should skip with a clear message.
"""
from __future__ import annotations

import sys
from pathlib import Path


def kernel_supports_bpf_lsm() -> bool:
    """True iff the host kernel has BPF LSM enabled.

    The canonical check is `/sys/kernel/security/lsm` containing
    the substring `bpf` — that's the kernel reporting which
    Security Modules are active. Without this, attaching a
    `lsm/*` BPF program fails with EINVAL no matter how good the
    daemon code is.
    """
    lsm_file = Path("/sys/kernel/security/lsm")
    try:
        return "bpf" in lsm_file.read_text()
    except FileNotFoundError:
        return False


def skip_if_no_bpf_lsm(scenario_name: str) -> None:
    """Print a SKIP line and exit 0 when BPF LSM is unavailable.

    The runner treats exit 0 as PASS; the SKIP banner makes the
    skip visible in logs without flagging the suite as failing.
    """
    if not kernel_supports_bpf_lsm():
        print(f"SKIP: {scenario_name} — host kernel lacks BPF LSM "
              "(/sys/kernel/security/lsm does not contain 'bpf'). "
              "Build kernel with CONFIG_BPF_LSM=y AND set "
              "lsm=…,bpf in cmdline to enable.")
        sys.exit(0)
