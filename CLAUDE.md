# atty — agent orientation

A Suckless-style PTY proxy in Zig 0.16. Sits between a terminal emulator and a shell; composes its middleware (atuin autosuggest, guardrail, history) **at compile time** via an `inline for` over a config tuple. No plugin loader, no `*anyopaque`, no runtime branching on the module list.

User is on omarchy/Hyprland with Ghostty. Project hosted at `github.com/fentas/atty`, master is the main branch, release-please-driven CI.

## Build & test

```sh
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe   # build atty
zig build test  -Dtarget=x86_64-linux-gnu                    # unit tests
zig build itest -Dtarget=x86_64-linux-gnu                    # PTY integration tests
zig build e2e   -Dtarget=x86_64-linux-gnu                    # scripted-PTY scenarios + visual diff
zig fmt --check src/ build.zig
```

`-Dtarget=x86_64-linux-gnu` is **required on this dev box** — Arch's gcc-16 crt1.o has SFrame relocations Zig 0.16's linker can't handle. Without the flag the build fails with `R_X86_64_PC64`. CI uses musl targets so doesn't hit this.

`make build` / `make test` / `make itest` / `make e2e` wrap the above. `make link` symlinks `~/.local/bin/atty` to `./zig-out/bin/atty` for dev.

## File layout (most-touched)

```
src/
├── main.zig              CLI entry (atty [shell [args]])
├── root.zig              library entry — re-exports for @import("atty")
├── proxy.zig             poll() loop, signals, ghost-text, statusbar
├── module.zig            shared types: Action, Context (incl. ctx.incognito), Error
├── dispatch.zig          Dispatcher(modules) — inline-for walker
├── pty.zig               posix_openpt / grantpt / fork+exec child
├── line_state.zig        best-effort user-input buffer model + uncertain flag
├── ghost.zig             ghost-overlay state machine
├── statusbar.zig         DECSTBM bottom row
├── ansi.zig              minimal SGR/CSI helpers
├── style.zig             atty.Style + atty.style.presets
├── keymap.zig            Action + Binding + key("Ctrl+Shift+I")
├── defaults.zig          atty-shipped defaults — single source of truth
├── config_resolver.zig   merges user_config + defaults via @hasDecl
├── config.def.zig        committed template (atty maintains)
├── config.zig            user's overrides — GITIGNORED, seeded by build.zig
├── modules/
│   ├── atuin.zig         async worker; ghost + record + sync
│   ├── guardrail.zig     dangerous-command confirmation
│   └── history.zig       shell-native ~/.bash_history fallback
└── test/
    ├── integration.zig   real-PTY tests (zig build itest)
    └── e2e/              .e2e DSL scenarios + VT-grid diff harness

tests/e2e/<name>/scenario.e2e + tests/e2e/<name>/golden/{env.toml,cast.json,...}
```

## Critical pattern — config resolution (read before touching anything config-shaped)

Four files, dwm `config.def.h` / `config.h` style:

- **`defaults.zig`** — every subsystem is a `pub const Xxx = struct { … = … };` + a `pub const xxx: Xxx = .{};` instance. Per-field defaults inside the struct are the merge primitive.
- **`config.def.zig`** — committed template, commented examples, atty maintains.
- **`config.zig`** — user's overrides, **gitignored**. `build.zig` copies the template across on first build.
- **`config_resolver.zig`** — `pub const xxx = if (@hasDecl(user, "xxx")) user.xxx else defaults.xxx;` per subsystem. Re-exports the types for user annotations.

Internal code imports `@import("config")` and reads `config.proxy.tick_interval_ms`, `config.ghost.style`, etc. — never flat decls.

**Style rule (committed to):** every subsystem is a struct, even with one field today. Adding a sibling field is "new field in the struct" and existing user configs pick it up via Zig's per-field defaults — no migration. The only flat exception is `modules` (heterogeneous comptime tuple — can't be a struct field).

When adding a new knob inside an existing subsystem: just add a struct field in `defaults.zig`. Don't touch the resolver. Don't touch user configs.

## Module framework

Optional hooks (each guarded by `@hasDecl`, statically eliminated when missing):

```zig
pub fn attach    (allocator, io) !Runtime
pub fn detach    (rt: *Runtime, io) void
pub fn onInput   (rt, ctx, input) !Action          // hot path
pub fn onOutput  (rt, ctx, output) !void           // hot path
pub fn onTick    (rt, ctx, elapsed_ms) !void
pub fn onLineCommit(rt, ctx, line) !void           // Enter on non-empty + non-uncertain line
pub fn provideGhostText(rt, ctx) !?[]const u8      // first non-null wins (order = priority)
pub fn statusText(rt, ctx) !?[]const u8            // segment for the status bar
```

Hot-path rules: no allocations, no blocking I/O (use a worker thread + cv-signal mailbox like atuin's), no global locks.

Modules can read `ctx.incognito` to opt into stricter behaviour. By default ghost text still works in incognito; only **recording** is gated by the proxy (it skips `dispatchLineCommit`).

## Conventions

- **Conventional commits.** `feat(scope):` / `fix(scope):` / `refactor(scope):` / `docs:` etc. Release-please groups by type for the changelog. Squash-and-merge PRs.
- **Comments: WHY only.** Never explain what the code does (well-named idents do that); never reference the current task, fix, or callers. Multi-line docstrings are rare.
- **No backwards-compat shims** unless a user has explicitly asked. This is pre-1.0, refactor aggressively.
- **Suckless ethos.** Edit `src/config.zig`, recompile, done. No runtime config files, no plugin loaders. `make link` for live dev binary; `get.atty.sh` does the same symlink trick for source-build users.
- **Test pattern.** Unit tests inline in each file (`test "…" { … }`); pulled into `src/unit_tests.zig` for `zig build test`. PTY tests in `src/test/integration.zig`. Scripted scenarios in `tests/e2e/*/scenario.e2e` + goldens.

## Things to be careful about

- **`std.fs.cwd()` is gone in 0.16.** Use `std.Io.Dir.cwd()` with `b.graph.io` for build-time file ops, or libc externs via `std.c.*` for runtime.
- **Cycle:** `atty` module imports `config`, `config_resolver` imports `defaults`, `defaults` imports `atty` for module-factory types. Works because each side only consumes the other's *types* lazily. Don't add eager value-level imports across the cycle.
- **Multi-module file rule (0.16):** a `.zig` file can only belong to *one* module. `defaults.zig` lives in the `config` module; don't `@import("defaults.zig")` from `root.zig` (in the `atty` module) — go via `@import("config")` and re-export.
- **DECSTBM + slave winsize must stay coordinated.** When the status bar is enabled, slim the slave PTY's reported `rows` by `reserve_rows` or the shell wraps wrong. SIGWINCH path in `proxy.zig` re-applies both.
- **Kitty keyboard protocol is on by default** with flag 1 (disambiguate). atty pushes `\x1b[>1u` at startup, pops on exit. The proxy's stdin handler intercepts unmapped CSI-u sequences (via `keymap.isCsiU`) and drops them so the shell never sees mojibake. Legacy keys (Ctrl+D/Ctrl+C/arrows/…) are not CSI-u shaped and pass through unchanged. `Ctrl+Shift+I` and Alt+i both bind to `incognito_toggle` — first uses the kitty CSI-u encoding, second is the classic-encoding fallback for terminals that don't support the protocol.
- **e2e goldens are config-sensitive.** The e2e harness uses the user's compiled binary. If `src/config.zig` has `statusbar.enabled = true`, snapshots include the bar. CI/release builds use `config.def.zig` defaults (statusbar off) — that's the canonical environment.
- **First-paint after activate** of the statusbar should clear the reserved rows (old shell content can leak through DECSTBM otherwise).

## Things deliberately not yet built (don't propose without checking with user)

- OSC 133 prompt-marker support (would clean up the line-state `uncertain` mess but needs shell-side cooperation).
- A persistent visual indicator other than the statusbar segment (cursor-color / cursor-shape were discussed and dropped).
- Atuin `history end` with exit codes (needs ID capture + double CLI invocation; deferred).
- atuin-side `deleteHistoryMatch` is shipped. Default scope is `.exact` — shells out to `atuin search --search-mode fuzzy --delete '^<line>$'` so only the typed line is removed (atuin v18 has no exact-match search mode, but its fuzzy mode honors fzf-style anchors). Scope is configurable via `Config.delete_scope`: `.prefix` / `.full_text` / `.fuzzy` widen the sweep if you want it.

## Release flow

`feat/fix/refactor` PRs land on master → release-please opens/updates a `chore(release): X.Y.Z` PR → maintainer merges it → tag is pushed → `.github/workflows/release.yml` cross-compiles musl binaries (x86_64 + aarch64) + multi-arch Docker image to `ghcr.io/fentas/atty`. Never push to master with `--no-verify`. Never force-push to master.

## Where to look first

- Behavior question → `docs/architecture.md`
- Module API question → `docs/modules.md`
- Config option question → `src/defaults.zig` (canonical defaults) + `src/config.def.zig` (commented examples)
- Module-specific question → `src/modules/<name>.zig` (each file is self-contained with its own tests)
