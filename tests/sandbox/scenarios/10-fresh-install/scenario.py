#!/usr/bin/env python3
"""10-fresh-install — contrib/install.sh end-to-end.

Pins the operator install path: a fresh box runs install.sh,
ends up with the binary, system user/group, state dirs (atty:atty
0750), config dir (root:root 0755), unit file, AND the right
systemctl calls (daemon-reload + enable --now + try-restart).

Failure modes this catches:
- Binary install missing executable bit.
- State dir created world-readable.
- Unit file forgotten or installed to the wrong path.
- systemctl call sequence reordered (a regression that called
  try-restart before enable --now would let the unit be
  disabled at boot but appear "working" today).

Systemd-in-docker is awkward; we mock systemctl into a recorder
shim that captures every invocation, then verify the call log
matches what production would do. UDS reachability is verified
separately by booting the daemon under runuser the way the smoke
test does — the unit's ExecStart line is what install.sh writes.
"""
from __future__ import annotations

import shutil
import stat
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, "/sandbox")
from lib.daemon import Daemon  # noqa: E402
from lib.users import as_user  # noqa: E402


SYSTEMCTL_LOG = Path("/tmp/systemctl-calls.log")
INSTALL_SCRIPT = Path("/install-src/atty-guard/contrib/install.sh")
EXPECTED_FILES = [
    ("/usr/local/bin/atty-guard", "root", "root", 0o755),
    ("/etc/systemd/system/atty-guard.service", "root", "root", 0o644),
    ("/etc/atty-guard", "root", "root", 0o755),
    ("/var/lib/atty-guard", "atty", "atty", 0o750),
]


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def wipe_state() -> None:
    # Base image pre-creates these; install.sh has to be idempotent
    # over them. To prove install.sh actually creates them (not
    # just inherits the base image's bytes), wipe before running
    # the installer. /var/lib/atty-guard included: without it, a
    # regression where install.sh stopped creating the state dir
    # would still pass because the base image pre-created it.
    # atty:atty user/group stay (install.sh is idempotent over
    # them too — useradd would refuse to re-create).
    for p in ["/usr/local/bin/atty-guard",
              "/etc/systemd/system/atty-guard.service",
              "/etc/atty-guard",
              "/var/lib/atty-guard"]:
        path = Path(p)
        if path.is_file() or path.is_symlink():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)


def install_mock_systemctl() -> None:
    # /usr/local/bin > /usr/bin in default PATH so this shadows
    # the system systemctl for install.sh's lifetime. Recorder
    # appends every invocation to SYSTEMCTL_LOG; nothing else.
    shim = Path("/usr/local/bin/systemctl")
    shim.write_text(
        "#!/bin/sh\n"
        f"echo \"$*\" >> {SYSTEMCTL_LOG}\n"
        # `status` is the only call install.sh wants output from
        # (it pipes through `--no-pager --lines=5`). Print enough
        # to keep the heredoc from spitting nothing.
        "case \"$1\" in\n"
        "  *status*) echo 'atty-guard.service - mock';;\n"
        "esac\n"
        "exit 0\n"
    )
    shim.chmod(0o755)


def check_files() -> None:
    import grp
    import pwd
    for path_str, want_owner, want_group, want_mode in EXPECTED_FILES:
        p = Path(path_str)
        if not p.exists():
            fail(f"install.sh did not create {path_str}")
        st = p.stat()
        owner = pwd.getpwuid(st.st_uid).pw_name
        group = grp.getgrgid(st.st_gid).gr_name
        mode = stat.S_IMODE(st.st_mode)
        if (owner, group) != (want_owner, want_group):
            fail(f"{path_str} owned {owner}:{group} (want "
                 f"{want_owner}:{want_group})")
        if mode != want_mode:
            fail(f"{path_str} mode {oct(mode)} (want {oct(want_mode)})")


def check_unit_file() -> None:
    # The unit file is what systemd would actually ExecStart. If
    # install.sh installs a unit pointing at /opt/wrong/path, the
    # systemctl shim happily accepts the enable but boot would
    # fail with "binary not found". Pin the ExecStart line to the
    # binary path install.sh actually wrote.
    unit = Path("/etc/systemd/system/atty-guard.service").read_text()
    if "ExecStart=/usr/local/bin/atty-guard" not in unit:
        fail(f"unit file ExecStart wrong / missing.\nunit contents:\n{unit}")


def check_systemctl_calls() -> None:
    if not SYSTEMCTL_LOG.exists():
        fail("install.sh did not invoke systemctl at all")
    calls = [ln.strip() for ln in SYSTEMCTL_LOG.read_text().splitlines() if ln.strip()]
    # Production order:
    #   daemon-reload → enable --now atty-guard.service → try-restart
    # A regression that swapped enable and try-restart would mean the
    # unit isn't enabled for next boot (try-restart on inactive is a
    # no-op; the install would appear to work but die on reboot).
    expected_prefixes = [
        "daemon-reload",
        "enable --now atty-guard.service",
        "try-restart atty-guard.service",
    ]
    idx = 0
    for call in calls:
        if call.startswith(expected_prefixes[idx]):
            idx += 1
            if idx == len(expected_prefixes):
                break
    if idx != len(expected_prefixes):
        fail("systemctl call sequence wrong. expected (in order): "
             f"{expected_prefixes!r}. saw: {calls!r}")


def check_uds_reachable() -> None:
    # Boot the daemon the way the (mocked-out) systemd unit would
    # — runuser + same binary path. If install.sh installed
    # a broken binary or misconfigured state dirs, the daemon
    # won't come up and Daemon() raises.
    with Daemon():
        for user in ("alice", "bob"):
            res = as_user(user, ["/usr/local/bin/atty-guard",
                                 "atoms", "list", "--user"])
            if res.returncode != 0:
                fail(f"{user} can't reach daemon after install: "
                     f"rc={res.returncode} stderr={res.stderr!r}")


def main() -> None:
    if not INSTALL_SCRIPT.exists():
        fail(f"install.sh not staged at {INSTALL_SCRIPT}. The runner "
             "must mount /install-src for this scenario.")

    wipe_state()
    install_mock_systemctl()
    if SYSTEMCTL_LOG.exists():
        SYSTEMCTL_LOG.unlink()

    # install.sh expects to find its binary at
    # `$REPO_ROOT/target/release/atty-guard`. We already have a
    # working atty-guard in the container; symlink it into the
    # location install.sh probes so the script's `install -m 0755`
    # call has a real file to copy.
    target = Path("/install-src/atty-guard/target/release/atty-guard")
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        # Dockerfile.base bakes a backup at
        # /opt/atty-guard.image-backup precisely for this restore.
        shutil.copy2("/opt/atty-guard.image-backup", target)
        target.chmod(0o755)

    # Run install.sh as root (matches make install-guard path).
    proc = subprocess.run(
        ["bash", str(INSTALL_SCRIPT)],
        capture_output=True,
        timeout=30,
    )
    if proc.returncode != 0:
        fail(f"install.sh failed rc={proc.returncode}\n"
             f"stdout={proc.stdout.decode()}\n"
             f"stderr={proc.stderr.decode()}")

    check_files()
    check_unit_file()
    check_systemctl_calls()

    # Remove the mock so Daemon's real boot uses no systemctl at all.
    Path("/usr/local/bin/systemctl").unlink()

    check_uds_reachable()

    print("PASS: 10-fresh-install")


if __name__ == "__main__":
    main()
