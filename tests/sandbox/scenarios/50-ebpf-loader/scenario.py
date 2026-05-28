#!/usr/bin/env python3
"""50-ebpf-loader — --ebpf-mode flag plumbing + graceful fallback.

Two passes:

1. `--ebpf-mode=disabled` (default) — daemon must NOT attempt to
   attach. No "eBPF" log line at all. Pins a regression where
   disabled accidentally tries to load.

2. `--ebpf-mode=observe` on an image WITHOUT --features ebpf —
   daemon must log "eBPF unavailable" (FeatureNotBuilt) AND
   continue serving. This is the production fallback path when
   operators forget `--features ebpf` on their build. The
   sandbox image is built with `tier2-onnx,osv-live,atoms-fetch`
   on purpose so this test exercises the fallback without
   needing the full kernel-side .bpf.o + CAP_BPF setup (which
   needs a separate sandbox image build — see follow-up issue).

Failure modes this catches:
- --ebpf-mode flag missing from CLI (clap parse error → daemon
  won't start at all).
- Disabled mode silently attempting attach.
- Graceful fallback path regression (daemon panics instead of
  logging + continuing).
"""
from __future__ import annotations

import sys
import time

sys.path.insert(0, "/sandbox")
from lib.daemon import Daemon  # noqa: E402


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def wait_for_log(daemon: Daemon, needle: str, timeout: float) -> bool:
    """Poll daemon.read_log() until `needle` appears or timeout.
    Belt-and-braces: the eBPF eprintln runs before the UDS bind
    (main.rs ebpf_state branch) so the log line should be on disk
    by the time Daemon.__enter__ returns, but stderr buffering or
    a slow runuser exec can leave a small window.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        if needle in daemon.read_log():
            return True
        time.sleep(0.1)
    return False


def main() -> None:
    # Pass 1: default disabled — no eBPF banner at all. Give the
    # daemon 1s of running time so an accidental attach attempt
    # would have surfaced.
    with Daemon(verbosity=1) as d:
        time.sleep(1.0)
        log = d.read_log()
        if "eBPF" in log:
            d.dump_log()
            fail(f"default mode emitted eBPF log line: {log!r}")

    # Pass 2: observe on no-feature build — fallback path.
    with Daemon(extra_args=["--ebpf-mode", "observe"], verbosity=1) as d:
        if not wait_for_log(d, "eBPF unavailable", timeout=3.0):
            d.dump_log()
            fail("observe mode did NOT log 'eBPF unavailable' within "
                 "3s — expected the FeatureNotBuilt fallback path.")
        # Daemon must still be reachable (not crashed by the fallback).
        if not d.socket_ready():
            fail("daemon socket disappeared after eBPF fallback log")

    print("PASS: 50-ebpf-loader")


if __name__ == "__main__":
    main()
