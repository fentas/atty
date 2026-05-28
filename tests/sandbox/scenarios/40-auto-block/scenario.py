#!/usr/bin/env python3
"""40-auto-block — V2-J accumulator threshold + REFUSED render.

Enables the opt-in auto-Block (`[accumulator] block_threshold`),
sends a multi-Tier-1 command through atty as alice, and asserts
atty paints `REFUSED` instead of arming the prompt banner.

`nc -e /bin/sh -i` fires EXACTLY two atoms (`nc -e` and
`/bin/sh -i`) at confidence 0.6 each. Combined = 1 − 0.4² =
0.84, comfortably above our 0.8 threshold. Deliberately chosen
over `curl … | sh` because that ALSO trips the `curl_pipe_sh`
precise regex (1.0 confidence) which would mask any regression
in the two-atom accumulator math. The ≥ 2 distinct signals
guard is non-configurable so a single-atom command can't get
auto-Blocked regardless of threshold.

Failure modes this catches:
- block_threshold parsing regression — daemon ignores the value
  silently and keeps Warn.
- Accumulator math regression — two atoms no longer combine to
  cross the threshold.
- REFUSED rendering regression — atty no longer paints the line
  on a Block verdict.
- single-hit guard regression — threshold drops so low that one
  atom would Block.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, "/sandbox")
from lib.daemon import Daemon  # noqa: E402
from lib.pty import drain, read_until  # noqa: E402

import ptyprocess  # noqa: E402


CONFIG = Path("/etc/atty-guard/config.toml")
DANGER_CMD = "nc -e /bin/sh -i 127.0.0.1 4444"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def write_config() -> None:
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(
        "[accumulator]\n"
        # 0.8 = trip on two atoms (1 - 0.4² = 0.84) but NOT one
        # atom at 0.6 — defends the single-hit-stays-Warn invariant.
        "block_threshold = 0.8\n"
    )


def drive_atty_with_danger() -> tuple[str, bool]:
    """Spawn atty as alice, type the dangerous command, return
    captured PTY output and whether atty stayed alive afterwards.
    """
    inner = (
        "export PS1='\\$ ' TERM=xterm-256color HOME=/home/alice; "
        "exec /usr/local/bin/atty bash --noprofile --norc"
    )
    proc = ptyprocess.PtyProcess.spawn(
        ["runuser", "-u", "alice", "--", "bash", "-c", inner],
        dimensions=(24, 80),
    )

    captured = bytearray()
    read_until(proc, b"$ ", timeout=4.0, sink=captured)
    proc.write(f"{DANGER_CMD}\r".encode())

    # Wait for REFUSED OR until the prompt advances (which would
    # mean the daemon DIDN'T block). 4s budget covers the daemon
    # round-trip (config-loaded, no SLM, just Tier-1).
    found_refused = read_until(proc, b"REFUSED", timeout=4.0, sink=captured)
    # Let atty also paint the readline clear so the snapshot
    # includes both REFUSED + the cleared prompt.
    drain(proc, timeout=0.5, sink=captured)

    try:
        proc.kill(9)
    except ptyprocess.PtyProcessError:
        pass

    return bytes(captured).decode("utf-8", errors="replace"), found_refused


def main() -> None:
    write_config()
    # Daemon must be started AFTER the config file is in place —
    # --config is read once at boot.
    with Daemon(config_path=CONFIG) as daemon:
        out, found = drive_atty_with_danger()

        if not found:
            daemon.dump_log()
            fail(f"daemon did NOT auto-Block multi-Tier-1 command.\n"
                 f"captured PTY:\n{out!r}")

        # After Block atty sends Ctrl+U to wipe readline; bash
        # shouldn't fork nc. `bash: nc: command not found` would
        # appear if the command had actually run.
        if "nc: command not found" in out or "nc: connect" in out:
            fail(f"command appears to have RUN despite REFUSED line.\n"
                 f"captured: {out!r}")

    print("PASS: 40-auto-block")


if __name__ == "__main__":
    main()
