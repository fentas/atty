#!/usr/bin/env python3
"""58-ebpf-detection-gap — the kernel does not autonomously detect
non-proxy execve chains. (Characterization test of a known limitation.)

The enforcement (LSM) hook only acts on PIDs the daemon has marked, and
the ONLY thing that marks is the proxy — the atty prompt sending a typed
command for classification. A process chain that bypasses the prompt —
e.g. a compromised dependency at runtime spawning `python → node →
exploit` — is seen by the kernel but never classified, so it's never
marked and never blocked, EVEN under the deepest enforcement depth
(`propagate_on_fork`). The `sys_enter_execve` tracepoint's per-execve
events are discarded by the daemon today; the kernel-side detection they
were meant to feed is unbuilt.

So this is a **detection** gap, not an enforcement-*depth* gap — the
deeper modes can't help, because there's no marked ancestor to descend
from. This test pins that reality: a non-proxy chain runs unblocked.

(That enforcement itself works once a PID *is* marked is covered by
51 / 55 / 56. `node` here is substituted by a second python for image
portability — the shape, an interpreter chain ending in a payload, is
what matters.)

If kernel-side detection is ever wired, this test will start failing —
which is the signal to update it. Skips cleanly without BPF LSM / the
baked .bpf.o.
"""
from __future__ import annotations

import subprocess
import sys

sys.path.insert(0, "/sandbox")
from lib.bpf import skip_if_no_bpf_lsm, skip_if_no_bpf_object  # noqa: E402
from lib.daemon import Daemon  # noqa: E402

NAME = "58-ebpf-detection-gap"

# python → python → sh → payload. Nothing sends a set_threat RPC, so
# threat_map stays empty and the LSM has nothing to gate. The `echo`
# stands in for the exploit's execve; its appearance proves the deep,
# unmarked execve was allowed.
CHAIN = (
    "import subprocess, sys; "
    "subprocess.run([sys.executable, '-c', "
    "\"import subprocess; subprocess.run(['sh', '-c', 'echo PAYLOAD_EXECUTED'])\"])"
)
TOKEN = "PAYLOAD_EXECUTED"


def fail(msg: str) -> None:
    print(f"FAIL: {NAME}: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    skip_if_no_bpf_lsm(NAME)
    skip_if_no_bpf_object(NAME)

    # Deepest enforcement on purpose: if even propagate can't stop it,
    # the gap is detection, not depth.
    with Daemon(
        extra_args=["--ebpf-mode", "block", "--enforcement-depth", "propagate_on_fork"],
        verbosity=1,
    ) as d:
        import time

        time.sleep(1.5)
        if "eBPF attached" not in d.read_log():
            d.dump_log()
            fail("daemon didn't attach eBPF — can't characterize the gap")

        # Run the chain entirely outside the proxy (no marking at all).
        res = subprocess.run(
            [sys.executable, "-c", CHAIN],
            capture_output=True,
            timeout=15,
        )
        out = res.stdout.decode("utf-8", errors="replace")

    if TOKEN not in out:
        fail("the unmarked non-proxy chain's payload did NOT run — if "
             "enforcement started catching it, kernel-side detection was "
             f"wired and this test needs updating. rc={res.returncode} "
             f"stdout={out!r} stderr={res.stderr.decode('utf-8', 'replace')!r}")

    print(f"PASS: {NAME} (confirmed gap: a non-proxy chain runs unblocked "
          "even under propagate_on_fork)")


if __name__ == "__main__":
    main()
