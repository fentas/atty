#!/usr/bin/env python3
"""Sandbox scenario runner — discovers tests/sandbox/scenarios/*/scenario.py,
builds the base docker image, and runs each scenario in a fresh container.

Usage:
    python3 tests/sandbox/runner.py             # run all
    python3 tests/sandbox/runner.py 00-smoke    # run one
    python3 tests/sandbox/runner.py --no-build  # skip image rebuild

Exits 0 if all scenarios pass, 1 if any fail.

Design notes
------------

Why python+ptyprocess and not bash+expect: keystroke timing and
PTY assertions are easier to reason about in python (real types,
proper exception propagation), and we get pytest-grade isolation
between scenarios without rolling our own framework.

Why containers per scenario (not one container reused): each
scenario starts from a known-clean state — fresh /var/lib/atty-guard,
no stale daemon, no leaked PIDs from previous runs. Trade ~3s of
container startup for deterministic isolation.

Why we don't run systemd inside the container: systemd-in-docker
is awkward (--privileged + /run/systemd mount + PID 1 dance) and
scenarios that need to test install.sh's systemd integration can
verify the FILES + the unit's ExecStart line without actually
booting the unit. The daemon runs as a plain background process.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SANDBOX_DIR = REPO_ROOT / "tests" / "sandbox"
BUILD_DIR = SANDBOX_DIR / ".build"
IMAGE_TAG = "atty-sandbox:base"


def stage_binaries() -> None:
    """Copy the host-built atty binary into the docker build
    context. atty is statically-linked musl (per the Makefile's
    default TARGET=x86_64-linux-musl) so the host binary is
    portable into the container. atty-guard is built INSIDE the
    container via the Dockerfile's builder stage so it picks up
    matching glibc.
    """
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    atty_src = REPO_ROOT / "zig-out" / "bin" / "atty"
    if not atty_src.exists():
        die(
            f"atty binary not found at {atty_src}.\n"
            f"Run `make build` first (or `zig build -Doptimize=ReleaseSafe`)."
        )
    shutil.copy2(atty_src, BUILD_DIR / "atty")


def build_image() -> None:
    print(f"[runner] building {IMAGE_TAG} …")
    # Build context is REPO_ROOT so the builder stage can COPY
    # atty-guard/. The Dockerfile is referenced explicitly via -f
    # because docker doesn't look inside tests/sandbox/ by default.
    # `.dockerignore` at the repo root keeps the context small
    # (excludes zig-out, target/, .git, etc.) — see file for the
    # exclude list.
    subprocess.run(
        [
            "docker",
            "build",
            "-t",
            IMAGE_TAG,
            "-f",
            str(SANDBOX_DIR / "Dockerfile.base"),
            str(REPO_ROOT),
        ],
        check=True,
    )


def discover_scenarios() -> list[Path]:
    return sorted(
        (SANDBOX_DIR / "scenarios").glob("*/scenario.py"),
        key=lambda p: p.parent.name,
    )


def run_scenario(script: Path) -> bool:
    name = script.parent.name
    print(f"\n[runner] === {name} ===")
    # Mount the sandbox tree read-only at /sandbox so scenarios
    # can import shared helpers from /sandbox/lib/.
    # --tmpfs /tmp so atuin / atty caches don't leak between runs.
    # --network=none so accidental fetches fail fast in the smoke
    # tier; scenarios that need network override this themselves.
    result = subprocess.run(
        [
            "docker",
            "run",
            "--rm",
            "--network=none",
            "--tmpfs",
            "/tmp:exec",
            "-v",
            f"{SANDBOX_DIR}:/sandbox:ro",
            "-w",
            "/sandbox",
            IMAGE_TAG,
            "python3",
            f"/sandbox/scenarios/{name}/scenario.py",
        ]
    )
    ok = result.returncode == 0
    print(f"[runner] {name}: {'PASS' if ok else 'FAIL'}")
    return ok


def die(msg: str) -> None:
    print(f"[runner] error: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "names",
        nargs="*",
        help="Scenario names to run (default: all). e.g. 00-smoke",
    )
    ap.add_argument("--no-build", action="store_true", help="Skip image rebuild")
    args = ap.parse_args()

    if not args.no_build:
        stage_binaries()
        build_image()

    scenarios = discover_scenarios()
    if not scenarios:
        die("no scenarios found under tests/sandbox/scenarios/")

    if args.names:
        wanted = set(args.names)
        scenarios = [s for s in scenarios if s.parent.name in wanted]
        missing = wanted - {s.parent.name for s in scenarios}
        if missing:
            die(f"unknown scenarios: {sorted(missing)}")

    failed: list[str] = []
    for script in scenarios:
        if not run_scenario(script):
            failed.append(script.parent.name)

    print("\n[runner] " + ("=" * 40))
    if failed:
        print(f"[runner] FAILED: {failed}")
        return 1
    print(f"[runner] all {len(scenarios)} scenario(s) passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
