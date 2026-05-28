#!/usr/bin/env python3
"""Sandbox scenario runner — discovers tests/sandbox/scenarios/*/scenario.py,
builds the base docker image, and runs each scenario in a fresh container.

Usage:
    python3 tests/sandbox/runner.py             # run all
    python3 tests/sandbox/runner.py 00-smoke    # run one
    python3 tests/sandbox/runner.py --no-build  # skip image rebuild

Exits 0 if all scenarios pass, 1 if any fail.
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
# Per-scenario wall-clock cap. Without it a hung container blocks
# the entire runner forever (subprocess.run has no default timeout).
SCENARIO_TIMEOUT_S = 120


def stage_binaries() -> None:
    """Build atty with the sandbox config (daemon enabled at the
    production socket path) and stage it for the docker build.

    Sandbox can't use the developer's `zig-out/bin/atty` directly
    because the developer's `src/config.zig` typically has
    `security_guard.daemon_socket_path = ""` — without that, the
    auto-block scenario can't see daemon verdicts in PTY output.
    Build with `-Dconfig=tests/sandbox/config.sandbox.zig` so the
    developer's config is untouched.
    """
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    sandbox_config = SANDBOX_DIR / "config.sandbox.zig"
    if not sandbox_config.exists():
        die(f"sandbox config missing: {sandbox_config}")
    out_prefix = BUILD_DIR / "zig-out"
    print(f"[runner] building sandbox atty via {sandbox_config.name} …")
    subprocess.run(
        [
            "zig", "build",
            "-Dtarget=x86_64-linux-musl",
            "-Doptimize=ReleaseSafe",
            f"-Dconfig={sandbox_config.relative_to(REPO_ROOT)}",
            "-p", str(out_prefix.relative_to(REPO_ROOT)),
        ],
        check=True,
        cwd=REPO_ROOT,
    )
    built = out_prefix / "bin" / "atty"
    if not built.exists():
        die(f"sandbox atty build produced no binary at {built}")
    shutil.copy2(built, BUILD_DIR / "atty")


def build_image() -> None:
    print(f"[runner] building {IMAGE_TAG} …")
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
    try:
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
            ],
            timeout=SCENARIO_TIMEOUT_S,
        )
        ok = result.returncode == 0
    except subprocess.TimeoutExpired:
        print(f"[runner] {name}: TIMEOUT (> {SCENARIO_TIMEOUT_S}s)")
        # `docker run --rm` cleans the container even on host-side
        # kill, so no manual `docker rm` needed.
        return False
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
