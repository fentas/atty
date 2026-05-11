# Changelog

All notable changes to atty are documented here. This file is
maintained automatically by [release-please]; manual entries below
that point are merged into the relevant release on the next run.

[release-please]: https://github.com/googleapis/release-please

## 0.1.0

Initial public scaffold.

### Features

- PTY proxy with low-level POSIX setup (`posix_openpt`/`grantpt`/`unlockpt`),
  termios raw-mode RAII guard, SIGWINCH/SIGCHLD propagation via
  self-pipe.
- Comptime-composed module framework (`Dispatcher(modules)`) with
  `onInput` / `onOutput` / `provideGhostText` / `onTick` hooks. Missing
  hooks are statically eliminated from the binary via `@hasDecl`.
- **Atuin** module: async worker thread + one-slot mailbox; subprocess
  backend via `atuin search`; socket backend stub; TTL-driven
  suggestion expiry.
- **Guardrail** module: substring/prefix rule engine; swallow-on-Enter
  + confirm-on-Enter UX; configurable rule list.
- Ghost-text overlay state machine (DECSC/DECRC + dim/italic SGR), with
  idempotent re-render to avoid flicker under tick refresh.
- Best-effort line-state tracking with `uncertain` flag for unmodelled
  input sequences.
- Single-file `src/config.zig` is the Suckless-style user-editable
  config. `-Dconfig=path` flag (or `make CONFIG=…`) for out-of-tree
  configs.

### Documentation

- README + GitHub Pages site at <https://atty.sh> with
  terminal-aesthetic Jekyll layout.
- `docs/architecture.md`, `docs/modules.md`, `docs/providers.md`.

### Build

- `build.zig` with `run`, `test`, `itest` targets; `-Doptimize` /
  `-Dtarget` / `-Dconfig`.
- Multi-stage `Dockerfile` (Debian builder → minimal runtime).
- `Makefile` for the developer UX (`build`, `test`, `install`,
  `docker`, `docker-binary`).
- `scripts/install.sh` one-shot Docker → `./dist/atty`.

### CI

- `ci.yml`: `zig fmt --check`, build, unit + integration tests,
  end-to-end smoke, docker-builder smoke, binary artifact upload.
- `pages.yml`: Jekyll → GitHub Pages on push to main.
