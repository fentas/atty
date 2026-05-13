# Changelog

All notable changes to atty are documented here. This file is
maintained automatically by [release-please]; manual entries below
that point are merged into the relevant release on the next run.

[release-please]: https://github.com/googleapis/release-please

## [0.3.0](https://github.com/fentas/atty/compare/v0.2.0...v0.3.0) (2026-05-13)


### Features

* **atuin:** delete_scope config — default .exact via fuzzy + ^…$ anchors ([166e534](https://github.com/fentas/atty/commit/166e5349769a5985c849869477af011f86bf6b83))
* **atuin:** provideGhostList + src/modules/_lib.zig shared helpers ([ad53afa](https://github.com/fentas/atty/commit/ad53afa56213c95b9e2577c746ce006b55069da5))
* **atuin:** record on Enter + manual sync via CLI ([b615bba](https://github.com/fentas/atty/commit/b615bba41cb1b21f1f8a192249637035853640c4))
* **config:** accept-ghost takes a list of keys + recover from uncertain ([2c00a82](https://github.com/fentas/atty/commit/2c00a82928831d74d4c36124d410ea2db88da2aa))
* **e2e:** per-scenario config + ghost_accept + statusbar_visible scenarios ([91245c2](https://github.com/fentas/atty/commit/91245c2b82d94aba47fd26a8b4cbe84338b36192))
* **get.sh:** symlink installed binary to source build dir ([ccde793](https://github.com/fentas/atty/commit/ccde793d1c8c18a50311c5d8e9f4e0c2f5bc7d4c))
* **ghost:** configurable overlay style via atty.ghost.Style ([43bf695](https://github.com/fentas/atty/commit/43bf695942e8b6aadc6a93913fd1020c35d3c170))
* **ghost:** multi-row pick list — provideGhostList + Ctrl+1..9 / Esc+1..9 ([774b71e](https://github.com/fentas/atty/commit/774b71ecacb1dba70ecea4674279d73349bc5599))
* **guardrail:** per-rule .mode — confirm / confirm_once / block / silent_block ([a690d18](https://github.com/fentas/atty/commit/a690d18e4a4aabbe7ddfb6dcb8a2ba66544462aa))
* **history:** add shell-native history module ([32f8eed](https://github.com/fentas/atty/commit/32f8eedfc7b67a0d68668c1188e81cc3bbdde782))
* **history:** Ctrl+Shift+D deletes matching line, status bar flashes ([5cb85e6](https://github.com/fentas/atty/commit/5cb85e61bf2e7165f0bd2c5274e3190f467bc1ba))
* **history:** shell-native history module ([6f0e816](https://github.com/fentas/atty/commit/6f0e816c3bba462cf6775725033fa34a9f30ee3b))
* **incognito:** Ctrl+Shift+I toggle + kitty kbd + status bar segment ([795170c](https://github.com/fentas/atty/commit/795170cbe495396984900d5730c996aa2710d2b0))
* **incognito:** muted-red style for the 🔒 segment ([d9d53f6](https://github.com/fentas/atty/commit/d9d53f61a9d8fc3633f33b79dd79449b16c7d759))
* **input-tracking:** DSR + 1-row grid emulator to recover line state from shell redraws ([3185e53](https://github.com/fentas/atty/commit/3185e53c07c864d2b546e40cabef975c0c9df5d1))
* **keymap:** Ctrl+Tab also accepts the ghost suggestion ([db435f6](https://github.com/fentas/atty/commit/db435f6f3a2c1e801a4df9bb2cfc9afa8824f079))
* **make:** add link/unlink targets for live dev binary ([94fe9c6](https://github.com/fentas/atty/commit/94fe9c6c52785d20c3b5038c39647bb199217ca9))
* **osc133:** auto-detected marker support, falls back to keystroke tracking ([9bc9e3b](https://github.com/fentas/atty/commit/9bc9e3b8c169228442056120df3ca97739df7ed4))
* **statusbar:** DECSTBM-reserved bottom row + module statusText hook ([4003649](https://github.com/fentas/atty/commit/4003649b4ee64ff050742379808858a610ef7544))
* **test:** add e2e framework with VT grid and visual snapshots ([f2f49b9](https://github.com/fentas/atty/commit/f2f49b912e32c573b9fe20df8da492d45512ab76))


### Bug Fixes

* **atuin:** implement deleteHistoryMatch — Ctrl+Shift+D now reaches atuin too ([b210d37](https://github.com/fentas/atty/commit/b210d377e20fef2de2ab3be549489164b8e0056e))
* **atuin:** newest match first, async sync, right-arrow accepts ghost ([fcaecda](https://github.com/fentas/atty/commit/fcaecdaf1360f222e0e8953a319b75fd60c3e8d6))
* **atuin:** suggestion_ttl_ms = 0 disables the timer; new default ([1341b42](https://github.com/fentas/atty/commit/1341b423b28c54b81616119c7133467da3edc041))
* **ghost_accept:** gather fresh suggestion, don't require ghost.visible ([6ed10c1](https://github.com/fentas/atty/commit/6ed10c1b29a018d4585234795564a2417236c3d4))
* **ghost_list:** dynamic activation, atuin-Ctrl+R style — no permanent dead space ([c1cdefb](https://github.com/fentas/atty/commit/c1cdefbaa52be0e2ded9b592da82abea9be09cdc))
* **ghost_list:** inflate statusbar reservation so shell pushes prompt above the list ([fe6d19e](https://github.com/fentas/atty/commit/fe6d19eae088f63ca29f80c67ffd152ce059e88d))
* **ghost_list:** paint with absolute CUP, anchored to bottom rows ([c56aee2](https://github.com/fentas/atty/commit/c56aee2bec132a7c9c072999bde5fdc23c0f1bc3))
* **ghost:** drop input-path renderGhost — was racing the shell echo ([eff5aa1](https://github.com/fentas/atty/commit/eff5aa11c94a4bb846e702900a08eea8112604f8))
* **guardrail:** banner never fired end-to-end + dispatchLineCommit ran past .swallow ([e72586a](https://github.com/fentas/atty/commit/e72586ac13d4afec2bae8d5dc232749a196a8536))
* **incognito:** three real bugs from manual testing ([d7bd349](https://github.com/fentas/atty/commit/d7bd3491241a9e91e64a57c4186b1fb1e1820c88))
* **input-tracking:** three race-condition fixes after live-test off-by-one ([77a127b](https://github.com/fentas/atty/commit/77a127b54cdae3d8dd4e1fa736b55eb96eb60295))
* **kitty:** re-enable disambiguate flag + intercept unmapped CSI-u ([e8d304b](https://github.com/fentas/atty/commit/e8d304bccf940377e6fe69e91d4402c5da966e71))
* **kitty:** translate CSI-u back to legacy bytes for Ctrl+letter, Esc, Tab, … ([90c4e5d](https://github.com/fentas/atty/commit/90c4e5db7120efbcda53a8d2277a9d8ad168b6d1))
* **statusbar:** activate parks cursor at (1,1), not in reserved area ([1808fbb](https://github.com/fentas/atty/commit/1808fbb8b8ecfabef7c268601cbd932091fe1507))
* **statusbar:** clear screen on activate for consistent fresh start ([accc89d](https://github.com/fentas/atty/commit/accc89d6fb1a05ce4321241e19935bd8614d1677))


### Refactor

* **config:** every subsystem is a struct (style guide commitment) ([74ae7af](https://github.com/fentas/atty/commit/74ae7af90c55efc9734a3542e9d7e1b2c8acde56))
* **config:** generalise key bindings as { bytes, action } pairs ([6ac581b](https://github.com/fentas/atty/commit/6ac581b14255c3b40ed06dc602135d1e01b26484))
* **config:** group statusbar fields into atty.StatusBar struct ([d0d0f15](https://github.com/fentas/atty/commit/d0d0f15b9307871dcbd45cdfd584d7eebfb375c2))
* **config:** split user config from defaults (dwm-style) ([734da31](https://github.com/fentas/atty/commit/734da31a047b45e89947fae64ee0c9d11a3ba992))
* **defaults:** swap atuin → history in the default tuple ([18be9bc](https://github.com/fentas/atty/commit/18be9bc2a6b387ff4a18ecf329e8e5faebc88aa5))
* **ghost_list:** sweep dead anchor/RenderMode plumbing + docs ([425bbbd](https://github.com/fentas/atty/commit/425bbbd1fcfba4a3f72bd6d802a73fd79eb91798))
* **keymap:** extract keymap.match() + tests, use from proxy ([f8926fb](https://github.com/fentas/atty/commit/f8926fb469ce593373cddc9e6784eaad4048b0ce))
* **main:** extract args.zig parser + tests (7 cases) ([8037b1e](https://github.com/fentas/atty/commit/8037b1e7a311ec220e08d82ff96d33cf76225388))
* **proxy:** extract status_text.zig — pure segment assembly + tests ([98c02db](https://github.com/fentas/atty/commit/98c02db538b9da01c6805dc5b5c15f226d3851cd))
* **proxy:** hoist keymap import + name kitty kbd push/pop bytes ([0e416a4](https://github.com/fentas/atty/commit/0e416a4d76f3cf51f11af201ce0c2af7738dfa6c))
* **style:** promote Style to a first-class atty.Style with presets ([d2898f7](https://github.com/fentas/atty/commit/d2898f7a3ad2e2029ed54be939a716cda555038b))


### Documentation

* add CLAUDE.md for fresh-agent orientation ([86d5f28](https://github.com/fentas/atty/commit/86d5f280e4b84aa6bf17f8cf2c3bad137d91a1bf))
* clarify gatherGhostText priority + atuin/history race window ([8347363](https://github.com/fentas/atty/commit/83473632844d616b2ec85d3b9d215e95c8668361))
* keymap, atuin record/sync, onLineCommit, e2e ([247a4f1](https://github.com/fentas/atty/commit/247a4f115b5358fbc1474dd2dd05e04be226290f))
* **osc133:** document the marker integration in architecture.md ([2e72d32](https://github.com/fentas/atty/commit/2e72d3239367291a8b6d2de3b9d1c4a17540d434))
* refresh Zig version references to 0.16 ([7aef0df](https://github.com/fentas/atty/commit/7aef0df0ee57551ec9cd4f4230ef942d0bba16ed))

## [0.2.0](https://github.com/fentas/atty/compare/v0.1.0...v0.2.0) (2026-05-13)


### Features

* **atuin:** delete_scope config — default .exact via fuzzy + ^…$ anchors ([166e534](https://github.com/fentas/atty/commit/166e5349769a5985c849869477af011f86bf6b83))
* **atuin:** provideGhostList + src/modules/_lib.zig shared helpers ([ad53afa](https://github.com/fentas/atty/commit/ad53afa56213c95b9e2577c746ce006b55069da5))
* **atuin:** record on Enter + manual sync via CLI ([b615bba](https://github.com/fentas/atty/commit/b615bba41cb1b21f1f8a192249637035853640c4))
* **config:** accept-ghost takes a list of keys + recover from uncertain ([2c00a82](https://github.com/fentas/atty/commit/2c00a82928831d74d4c36124d410ea2db88da2aa))
* **e2e:** per-scenario config + ghost_accept + statusbar_visible scenarios ([91245c2](https://github.com/fentas/atty/commit/91245c2b82d94aba47fd26a8b4cbe84338b36192))
* **get.sh:** symlink installed binary to source build dir ([ccde793](https://github.com/fentas/atty/commit/ccde793d1c8c18a50311c5d8e9f4e0c2f5bc7d4c))
* **ghost:** configurable overlay style via atty.ghost.Style ([43bf695](https://github.com/fentas/atty/commit/43bf695942e8b6aadc6a93913fd1020c35d3c170))
* **ghost:** multi-row pick list — provideGhostList + Ctrl+1..9 / Esc+1..9 ([774b71e](https://github.com/fentas/atty/commit/774b71ecacb1dba70ecea4674279d73349bc5599))
* **guardrail:** per-rule .mode — confirm / confirm_once / block / silent_block ([a690d18](https://github.com/fentas/atty/commit/a690d18e4a4aabbe7ddfb6dcb8a2ba66544462aa))
* **history:** add shell-native history module ([32f8eed](https://github.com/fentas/atty/commit/32f8eedfc7b67a0d68668c1188e81cc3bbdde782))
* **history:** Ctrl+Shift+D deletes matching line, status bar flashes ([5cb85e6](https://github.com/fentas/atty/commit/5cb85e61bf2e7165f0bd2c5274e3190f467bc1ba))
* **history:** shell-native history module ([6f0e816](https://github.com/fentas/atty/commit/6f0e816c3bba462cf6775725033fa34a9f30ee3b))
* **incognito:** Ctrl+Shift+I toggle + kitty kbd + status bar segment ([795170c](https://github.com/fentas/atty/commit/795170cbe495396984900d5730c996aa2710d2b0))
* **incognito:** muted-red style for the 🔒 segment ([d9d53f6](https://github.com/fentas/atty/commit/d9d53f61a9d8fc3633f33b79dd79449b16c7d759))
* **input-tracking:** DSR + 1-row grid emulator to recover line state from shell redraws ([3185e53](https://github.com/fentas/atty/commit/3185e53c07c864d2b546e40cabef975c0c9df5d1))
* **keymap:** Ctrl+Tab also accepts the ghost suggestion ([db435f6](https://github.com/fentas/atty/commit/db435f6f3a2c1e801a4df9bb2cfc9afa8824f079))
* **make:** add link/unlink targets for live dev binary ([94fe9c6](https://github.com/fentas/atty/commit/94fe9c6c52785d20c3b5038c39647bb199217ca9))
* **osc133:** auto-detected marker support, falls back to keystroke tracking ([9bc9e3b](https://github.com/fentas/atty/commit/9bc9e3b8c169228442056120df3ca97739df7ed4))
* **statusbar:** DECSTBM-reserved bottom row + module statusText hook ([4003649](https://github.com/fentas/atty/commit/4003649b4ee64ff050742379808858a610ef7544))
* **test:** add e2e framework with VT grid and visual snapshots ([f2f49b9](https://github.com/fentas/atty/commit/f2f49b912e32c573b9fe20df8da492d45512ab76))


### Bug Fixes

* **atuin:** implement deleteHistoryMatch — Ctrl+Shift+D now reaches atuin too ([b210d37](https://github.com/fentas/atty/commit/b210d377e20fef2de2ab3be549489164b8e0056e))
* **atuin:** newest match first, async sync, right-arrow accepts ghost ([fcaecda](https://github.com/fentas/atty/commit/fcaecdaf1360f222e0e8953a319b75fd60c3e8d6))
* **atuin:** suggestion_ttl_ms = 0 disables the timer; new default ([1341b42](https://github.com/fentas/atty/commit/1341b423b28c54b81616119c7133467da3edc041))
* **ghost_accept:** gather fresh suggestion, don't require ghost.visible ([6ed10c1](https://github.com/fentas/atty/commit/6ed10c1b29a018d4585234795564a2417236c3d4))
* **ghost_list:** dynamic activation, atuin-Ctrl+R style — no permanent dead space ([c1cdefb](https://github.com/fentas/atty/commit/c1cdefbaa52be0e2ded9b592da82abea9be09cdc))
* **ghost_list:** inflate statusbar reservation so shell pushes prompt above the list ([fe6d19e](https://github.com/fentas/atty/commit/fe6d19eae088f63ca29f80c67ffd152ce059e88d))
* **ghost_list:** paint with absolute CUP, anchored to bottom rows ([c56aee2](https://github.com/fentas/atty/commit/c56aee2bec132a7c9c072999bde5fdc23c0f1bc3))
* **ghost:** drop input-path renderGhost — was racing the shell echo ([eff5aa1](https://github.com/fentas/atty/commit/eff5aa11c94a4bb846e702900a08eea8112604f8))
* **guardrail:** banner never fired end-to-end + dispatchLineCommit ran past .swallow ([e72586a](https://github.com/fentas/atty/commit/e72586ac13d4afec2bae8d5dc232749a196a8536))
* **incognito:** three real bugs from manual testing ([d7bd349](https://github.com/fentas/atty/commit/d7bd3491241a9e91e64a57c4186b1fb1e1820c88))
* **input-tracking:** three race-condition fixes after live-test off-by-one ([77a127b](https://github.com/fentas/atty/commit/77a127b54cdae3d8dd4e1fa736b55eb96eb60295))
* **kitty:** re-enable disambiguate flag + intercept unmapped CSI-u ([e8d304b](https://github.com/fentas/atty/commit/e8d304bccf940377e6fe69e91d4402c5da966e71))
* **kitty:** translate CSI-u back to legacy bytes for Ctrl+letter, Esc, Tab, … ([90c4e5d](https://github.com/fentas/atty/commit/90c4e5db7120efbcda53a8d2277a9d8ad168b6d1))
* **statusbar:** activate parks cursor at (1,1), not in reserved area ([1808fbb](https://github.com/fentas/atty/commit/1808fbb8b8ecfabef7c268601cbd932091fe1507))
* **statusbar:** clear screen on activate for consistent fresh start ([accc89d](https://github.com/fentas/atty/commit/accc89d6fb1a05ce4321241e19935bd8614d1677))


### Refactor

* **config:** every subsystem is a struct (style guide commitment) ([74ae7af](https://github.com/fentas/atty/commit/74ae7af90c55efc9734a3542e9d7e1b2c8acde56))
* **config:** generalise key bindings as { bytes, action } pairs ([6ac581b](https://github.com/fentas/atty/commit/6ac581b14255c3b40ed06dc602135d1e01b26484))
* **config:** group statusbar fields into atty.StatusBar struct ([d0d0f15](https://github.com/fentas/atty/commit/d0d0f15b9307871dcbd45cdfd584d7eebfb375c2))
* **config:** split user config from defaults (dwm-style) ([734da31](https://github.com/fentas/atty/commit/734da31a047b45e89947fae64ee0c9d11a3ba992))
* **defaults:** swap atuin → history in the default tuple ([18be9bc](https://github.com/fentas/atty/commit/18be9bc2a6b387ff4a18ecf329e8e5faebc88aa5))
* **ghost_list:** sweep dead anchor/RenderMode plumbing + docs ([425bbbd](https://github.com/fentas/atty/commit/425bbbd1fcfba4a3f72bd6d802a73fd79eb91798))
* **keymap:** extract keymap.match() + tests, use from proxy ([f8926fb](https://github.com/fentas/atty/commit/f8926fb469ce593373cddc9e6784eaad4048b0ce))
* **main:** extract args.zig parser + tests (7 cases) ([8037b1e](https://github.com/fentas/atty/commit/8037b1e7a311ec220e08d82ff96d33cf76225388))
* **proxy:** extract status_text.zig — pure segment assembly + tests ([98c02db](https://github.com/fentas/atty/commit/98c02db538b9da01c6805dc5b5c15f226d3851cd))
* **proxy:** hoist keymap import + name kitty kbd push/pop bytes ([0e416a4](https://github.com/fentas/atty/commit/0e416a4d76f3cf51f11af201ce0c2af7738dfa6c))
* **style:** promote Style to a first-class atty.Style with presets ([d2898f7](https://github.com/fentas/atty/commit/d2898f7a3ad2e2029ed54be939a716cda555038b))


### Documentation

* add CLAUDE.md for fresh-agent orientation ([86d5f28](https://github.com/fentas/atty/commit/86d5f280e4b84aa6bf17f8cf2c3bad137d91a1bf))
* clarify gatherGhostText priority + atuin/history race window ([8347363](https://github.com/fentas/atty/commit/83473632844d616b2ec85d3b9d215e95c8668361))
* keymap, atuin record/sync, onLineCommit, e2e ([247a4f1](https://github.com/fentas/atty/commit/247a4f115b5358fbc1474dd2dd05e04be226290f))
* **osc133:** document the marker integration in architecture.md ([2e72d32](https://github.com/fentas/atty/commit/2e72d3239367291a8b6d2de3b9d1c4a17540d434))
* refresh Zig version references to 0.16 ([7aef0df](https://github.com/fentas/atty/commit/7aef0df0ee57551ec9cd4f4230ef942d0bba16ed))

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
