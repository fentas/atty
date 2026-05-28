# sandbox tests — end-to-end atty + atty-guard scenarios

Real binaries, real users, real UDS — the bits unit tests can't reach.

## Running

```sh
make sandbox           # build sandbox atty + base image + run scenarios
```

`make sandbox` does three things in order:

1. Builds atty with `-Dconfig=tests/sandbox/config.sandbox.zig` so
   the binary's `security_guard.daemon_socket_path` points at
   `/run/atty-guard/atty-guard.sock`. Your `src/config.zig` is
   untouched. Output goes into `tests/sandbox/.build/zig-out/`.
2. Builds atty-guard **inside the container** (Ubuntu 24.04
   builder stage in `Dockerfile.base`) so its glibc matches the
   runtime stage's glibc — no host-side `make build-guard` step.
3. Runs each scenario in a fresh container.

`make sandbox` is idempotent: re-running uses cached docker layers
(< 10s on warm cache). To rebuild from scratch, delete the image:

```sh
docker image rm atty-sandbox:base
```

### Running one scenario

```sh
python3 tests/sandbox/runner.py 00-smoke
```

### Skipping the rebuild step (faster iteration)

```sh
python3 tests/sandbox/runner.py --no-build 00-smoke
```

## Scenarios

Each lives at `tests/sandbox/scenarios/<NN-name>/scenario.py`. The
runner discovers them lexicographically, so the `NN` prefix
controls ordering (smaller numbers run first).

Convention: each `scenario.py` is self-contained (no test
framework dependency), starts the daemon via `lib.daemon.Daemon`,
drives an atty proxy via `subprocess.run` or `ptyprocess`, and
asserts via plain `assert` or by exiting non-zero with a
descriptive `fail()` message.

Current scenarios:

- **`00-smoke`** — framework liveness check. Daemon starts, UDS
  appears, atty proxy can spawn a child shell.
- **`10-fresh-install`** — `contrib/install.sh` end-to-end:
  binary + state dirs + unit file at expected paths with the
  expected ownership, systemctl call sequence (daemon-reload →
  enable --now → try-restart) verified via a recorder shim.
- **`20-cross-uid-threat-level`** — bob can neither set nor read
  alice's PID threat level via the UDS (issues #271 + #275 gates).
- **`30-sudo-atoms-add`** — alice's `sudo atty-guard atoms add`
  lands in her per-UID file (`atty:atty 0640`); bob's list view
  doesn't see it (cross-UID isolation).
- **`40-auto-block`** — V2-J-2 accumulator opt-in: with
  `[accumulator] block_threshold = 0.8`, a multi-Tier-1 command
  triggers daemon Block + atty paints REFUSED.
- **`50-ebpf-loader`** — `--ebpf-mode` flag plumbing + graceful
  fallback. Sandbox image is built without `--features ebpf`
  on purpose so the FeatureNotBuilt path is the test target.
  Full kernel-side eBPF testing (51 / 52 in #332's original
  scope) needs a separate sandbox image build with libbpf-dev +
  clang + the .bpf.o pre-compiled — deferred to a follow-up
  issue.
- **`62-onnx-fallback`** — pins the PR #316 / #026 fail-closed
  posture: explicit `[tier2] backend = "onnx"` + missing model
  must refuse to start; default path (no operator request)
  keeps the legacy degrade-to-stub fallback. Doesn't need a
  real model file; the actual-classify scenarios (60 / 61
  from #333's original scope) need model download + cache
  infrastructure and are deferred to a follow-up issue.

## Per-scenario docker flags

Most scenarios run with the runner's default `docker run` flags
(`--rm --network=none --tmpfs /tmp:exec`). Scenarios that need
extra capabilities (eBPF probe needs `CAP_BPF`, etc.) drop a
`docker.json` sibling next to their `scenario.py`:

```json
{"privileged": true,
 "cap_add": ["BPF", "SYS_ADMIN"],
 "security_opt": ["apparmor=unconfined"],
 "volumes": [{"src": "/sys/fs/bpf", "dst": "/sys/fs/bpf", "rw": true}]}
```

The runner merges these into the `docker run` invocation. All
fields are optional.

## Image layout

The base image (`atty-sandbox:base`) is built from
`Dockerfile.base`. Inputs:

- `tests/sandbox/.build/atty` — staged from `zig-out/bin/atty`
  (musl-static, portable across libc).
- `atty-guard/` source — compiled by the `guard-builder` stage
  against Ubuntu 24.04's glibc so it loads cleanly in the
  runtime stage.

The runner stages atty into `.build/` before each `docker build`.
The `.build/` directory is gitignored.

Image contents:
- Ubuntu 24.04 base.
- System `atty:atty` user/group + `/var/lib/atty-guard` (0750
  atty:atty) + `/run/atty-guard` (0750 atty:atty) — matches
  what `contrib/install.sh` would create on a real install.
- Unprivileged users `alice` (uid 1001) + `bob` (uid 1002), both
  in the `atty` group so they can reach the daemon UDS.
- NOPASSWD sudo for `atty-guard` only — scenarios drive the
  mediated CLI (`sudo atty-guard atoms add …`) without prompting.

## Why not systemd in the container?

systemd-in-docker is awkward (requires `--privileged`, `/run/systemd`
mounts, PID 1 dance) and most install.sh failure modes can be caught
by checking the FILES the script writes (binary, unit file, perms,
state dirs) without actually booting the unit. Scenarios that
specifically need to test systemd activation can use a
`systemctl-mock` approach OR override per-scenario with a
`docker run --privileged` flag.
