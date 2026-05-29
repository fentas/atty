#!/usr/bin/env python3
"""70-shai-hulud-npm — Shai-Hulud package classify replay.

Pins that `npm install @ctrl/tinycolor` (one of the original
Shai-Hulud-compromised packages, listed in
src/modules/security_guard/data/flagged_npm.txt under the
"Shai-Hulud npm worm" heading) lands as a Warn/Block verdict
with the package name surfaced in the reason text.

This is a structural assertion on the npm-flagged-pkg classifier
path — a regression where the corpus loader silently dropped
the package name, or the reason renderer lost the matched
identifier, would surface here even though the unit tests for
the matcher itself still pass.

Failure modes this catches:
- flagged_npm.txt seed entry removed in a corpus prune (the
  matcher unit test would still pass on the remaining list).
- npm-install reason rendering regression that loses the
  package name from the reason string.
- classify path for npm parsing regression (the daemon never
  reaches the flagged-list step).
"""
from __future__ import annotations

import sys

sys.path.insert(0, "/sandbox")
from lib.daemon import Daemon  # noqa: E402
from lib.uds import call  # noqa: E402


FLAGGED_PKG = "@ctrl/tinycolor"
PROBE_CMD = f"npm install {FLAGGED_PKG}"


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
        # Single flagged-npm hit → exactly one signal → can't
        # auto-Block per classifier.rs:372's `hits.len() >= 2`
        # guard. Tightening to warn-only catches a regression
        # where that guard goes away — 40-auto-block tests the
        # same guard via the URL path; this is the npm sibling.
        if verdict != "warn":
            d.dump_log()
            fail(f"expected warn (single-signal can't auto-Block) "
                 f"on flagged-npm hit, got verdict={verdict!r}; "
                 f"full response: {resp}")
        reason = resp.get("reason", "")
        if FLAGGED_PKG not in reason:
            d.dump_log()
            fail(f"reason text missing the flagged package name "
                 f"{FLAGGED_PKG!r}; reason={reason!r}; full "
                 f"response: {resp}")

    print("PASS: 70-shai-hulud-npm")


if __name__ == "__main__":
    main()
