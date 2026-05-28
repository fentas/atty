#!/usr/bin/env python3
"""30-sudo-atoms-add — mediated CLI + per-UID file isolation.

Pins the design from PR #141 + the cross-UID hardening in #275:
alice's `sudo atty-guard atoms add` lands in HER per-UID file
(`/var/lib/atty-guard/users/<alice-uid>/atoms.user.txt`, atty:atty
0640), and bob's daemon view is empty — atoms are NOT a host-global
list.

Failure modes this would catch: a regression that wrote atoms to
a shared file, dropped the atty:atty ownership requirement, or
served alice's atoms to bob.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, "/sandbox")
from lib.daemon import Daemon  # noqa: E402
from lib.users import UID_ALICE, as_user  # noqa: E402
import json  # noqa: E402
import subprocess  # noqa: E402


PATTERN = "curl evil.example"
ALICE_ATOMS = Path(f"/var/lib/atty-guard/users/{UID_ALICE}/atoms.user.txt")


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    with Daemon():
        add = as_user("alice", ["sudo", "/usr/local/bin/atty-guard",
                                "atoms", "add", PATTERN])
        if add.returncode != 0:
            fail(f"alice sudo atoms add failed: rc={add.returncode} "
                 f"stderr={add.stderr!r}")

        if not ALICE_ATOMS.exists():
            fail(f"per-UID file missing: {ALICE_ATOMS}")
        st = ALICE_ATOMS.stat()
        # Daemon refuses to load atoms files that aren't atty-owned;
        # bug-class to catch: a writer that left them as the caller's
        # uid would let alice tamper with her own classifier scope.
        import pwd
        import grp
        owner = pwd.getpwuid(st.st_uid).pw_name
        group = grp.getgrgid(st.st_gid).gr_name
        mode = st.st_mode & 0o777
        if (owner, group, mode) != ("atty", "atty", 0o640):
            fail(f"{ALICE_ATOMS} ownership/mode wrong: "
                 f"{owner}:{group} {oct(mode)} (want atty:atty 0640)")

        content = ALICE_ATOMS.read_text()
        if PATTERN not in content:
            fail(f"pattern not persisted in {ALICE_ATOMS}: {content!r}")

        # bob's --user list must NOT see alice's atom. Substring
        # match is fine here — we're asserting absence in a small
        # known-format output.
        bob_list = as_user("bob", ["/usr/local/bin/atty-guard",
                                   "atoms", "list", "--user"])
        if bob_list.returncode != 0:
            fail(f"bob atoms list failed: rc={bob_list.returncode} "
                 f"stderr={bob_list.stderr!r}")
        if PATTERN in bob_list.stdout.decode():
            fail(f"cross-UID leak: bob can see alice's atom: "
                 f"{bob_list.stdout!r}")

        # alice's --user list MUST see it (sanity — would catch a
        # writer that landed the file but didn't reload the cache).
        alice_list = as_user("alice", ["/usr/local/bin/atty-guard",
                                       "atoms", "list", "--user"])
        if PATTERN not in alice_list.stdout.decode():
            fail(f"alice can't see her own atom after add: "
                 f"{alice_list.stdout!r}")

        # The list view is one path; the classifier is another.
        # A regression that kept `atoms list` scoped correctly
        # while leaking alice's atom into bob's per-UID overlay
        # at classify-time would still bite production. Send a
        # classify RPC AS bob and assert no atom hit. UDS peer
        # cred is what the daemon gates on, so we wrap the
        # python lib.uds call in runuser.
        classify = subprocess.run(
            ["runuser", "-u", "bob", "--", "python3", "-c",
             "import sys; sys.path.insert(0, '/sandbox'); "
             "import json; from lib.uds import call; "
             f"print(json.dumps(call('classify', command={PATTERN!r})))"],
            capture_output=True,
            timeout=10,
        )
        if classify.returncode != 0:
            fail(f"bob classify subprocess failed: {classify.stderr!r}")
        verdict = json.loads(classify.stdout)
        # ResponseBody::Classify carries verdict + category.
        # Safe + Category::None means no atom hit. A leak would
        # surface as verdict=warn + category=none (atom hits go
        # through the generic AtomMatcher reason).
        if verdict.get("verdict") != "safe":
            fail(f"cross-UID atom leak at classify time: bob's "
                 f"classify of {PATTERN!r} returned {verdict}")

    print("PASS: 30-sudo-atoms-add")


if __name__ == "__main__":
    main()
