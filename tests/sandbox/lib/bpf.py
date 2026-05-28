"""BPF LSM availability probe for sandbox scenarios.

eBPF scenarios are inherently kernel-conditional — the LSM hook
that atty-guard installs (`lsm/bprm_check_security`) needs the
kernel to have BPF LSM enabled at boot. GH-hosted ubuntu runners
historically ship without it; the same scenarios shouldn't fail
loudly on those runners, they should skip with a clear message.

Split into two probes so scenarios can distinguish "kernel doesn't
support this" (true skip) from "container forgot the bind mount"
(scenario bug, should fail loudly).
"""
from __future__ import annotations

import sys
from pathlib import Path


_LSM_FILE = Path("/sys/kernel/security/lsm")


def securityfs_available() -> bool:
    """True iff `/sys/kernel/security` is mounted + readable.

    A privileged container that didn't bind-mount it would fail
    here even on a fully BPF-LSM-capable host. Use this to
    distinguish a container misconfig (loud failure) from a
    genuine kernel limitation (clean skip).
    """
    try:
        return _LSM_FILE.parent.is_dir()
    except OSError:
        return False


def kernel_supports_bpf_lsm() -> bool:
    """True iff securityfs is available AND BPF is in the LSM
    list. `/sys/kernel/security/lsm` is the kernel reporting
    which Security Modules are active; without 'bpf' in that
    list, attaching a `lsm/*` BPF program fails with EINVAL.
    """
    if not securityfs_available():
        return False
    try:
        return "bpf" in _LSM_FILE.read_text()
    except FileNotFoundError:
        return False


def skip_if_no_bpf_lsm(scenario_name: str) -> None:
    """Print a SKIP line and exit 0 when BPF LSM is unavailable.

    Failure cases handled differently:
    - securityfs not mounted in the container → loud failure
      (scenario's docker.json bug; user needs to know).
    - securityfs mounted but kernel lacks BPF LSM → clean skip
      (host kernel limitation, scenario can't run).
    """
    if not securityfs_available():
        print(f"FAIL: {scenario_name} — securityfs not mounted at "
              f"{_LSM_FILE.parent}. Add to scenario's docker.json: "
              '{"volumes": [{"src": "/sys/kernel/security", '
              '"dst": "/sys/kernel/security"}]}', file=sys.stderr)
        sys.exit(1)
    if not kernel_supports_bpf_lsm():
        print(f"SKIP: {scenario_name} — host kernel lacks BPF LSM "
              f"({_LSM_FILE} does not contain 'bpf'). Build kernel "
              "with CONFIG_BPF_LSM=y AND set lsm=…,bpf in cmdline.")
        sys.exit(0)
