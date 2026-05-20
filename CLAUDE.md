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
│   ├── _lib.zig          shared helpers for built-in modules (nowMs, ListBuilder)
│   ├── atuin.zig         async worker; ghost + record + sync + pick list
│   ├── guardrail.zig     dangerous-command confirmation
│   ├── history.zig       shell-native ~/.bash_history fallback + pick list
│   └── security_guard/   pre-Enter Tier-1 + UDS client to atty-guard sidecar
└── test/
    ├── integration.zig   real-PTY tests (zig build itest)
    └── e2e/              .e2e DSL scenarios + VT-grid diff harness

atty-guard/                  Rust sidecar daemon — system service running
│                            as `atty:atty` user/group (post-#140). UDS
│                            server with two-tier classifier (Tier-1
│                            regex/atom + Tier-2 SLM/heuristic), V2-J
│                            multi-hit accumulator, V2-J-2 opt-in auto-
│                            Block (`[accumulator] block_threshold`; red
│                            `REFUSED` line atty-side), eBPF LSM +
│                            execve/AF_ALG tracepoints, OSV live npm
│                            lookup, atom fetcher (GTFOBins + sanitized
│                            Sigma; LOLBAS dropped — Windows-native, see
│                            git log on atom_fetcher.rs for rationale).
│                            Mediated CLI: `sudo atty-guard atoms/urls/
│                            session/trust …` for per-UID mutations
│                            (SO_PEERCRED-gated). Three-source atom
│                            overlay scanned per classify: bundled
│                            (include_str!) → /var/lib/atty-guard/
│                            atoms.system.txt (daemon-fetched, perm-
│                            gated atty:atty 0640) → /var/lib/atty-guard/
│                            users/<uid>/atoms.user.txt (sudo-mediated).
│                            Install: `sudo make install-guard
│                            [GUARD_FEATURES=...,ebpf]` — the ebpf flag
│                            triggers the systemd drop-in auto-install.
├── Cargo.toml               feature flags: ebpf, tier2-onnx, osv-live, atoms-fetch
├── README.md
├── contrib/                 system unit + install.sh (re-execs sudo;
│                            --with-ebpf flag drops in the ebpf override).
├── ebpf/                    V2-B kernel C (LSM hook + execve + AF_ALG)
└── src/                     atom_fetcher / atom_matcher / classifier /
                             cli_client / ebpf / onnx_backend / osv /
                             protocol / sanitize / server / threat_map /
                             trust_store

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
pub fn provideGhostList(rt, ctx) !?[]const []const u8 // multi-row pick list (Ctrl+1..9 / Esc+1..9)
pub fn statusText(rt, ctx) !?[]const u8            // segment for the status bar
pub fn isOverlayActive(rt) bool                    // module owns atty's alt-screen (chat overlay etc.)
```

Hot-path rules: no allocations, no blocking I/O (use a worker thread + cv-signal mailbox like atuin's), no global locks.

Modules can read `ctx.incognito` to opt into stricter behaviour. By default ghost text still works in incognito; only **recording** is gated by the proxy (it skips `dispatchLineCommit`).

## Conventions

- **Conventional commits.** `feat(scope):` / `fix(scope):` / `refactor(scope):` / `docs:` etc. Release-please groups by type for the changelog. Squash-and-merge PRs.
- **Comments: WHY only.** Never explain what the code does (well-named idents do that); never reference the current task, fix, or callers. Multi-line docstrings are rare.
- **No backwards-compat shims** unless a user has explicitly asked. This is pre-1.0, refactor aggressively.
- **Suckless ethos.** Edit `src/config.zig`, recompile, done. No runtime config files, no plugin loaders. `make link` for live dev binary; `get.atty.sh` does the same symlink trick for source-build users.
- **Test pattern.** Unit tests live in **sibling files**: `src/foo.zig` is tested by `src/foo_tests.zig` next to it (same directory). The source file has a single `test { _ = @import("foo_tests.zig"); }` discovery stub; `src/unit_tests.zig` imports source files only, and test discovery cascades through the stub. The siblings use a fixed header: `const std`, `const testing`, `const mod = @import("foo.zig");`, then re-bind any pub decls (`const Style = mod.Style;`) so test bodies stay short. Exception: `src/modules/llm/dialog.zig` keeps tests inline because production code (the `Module(cfg, Runtime)` factory) is interleaved between two test stripes — extraction would split it across files. PTY tests in `src/test/integration.zig`. Scripted scenarios in `tests/e2e/*/scenario.e2e` + goldens.

## Things to be careful about

- **`std.fs.cwd()` is gone in 0.16.** Use `std.Io.Dir.cwd()` with `b.graph.io` for build-time file ops, or libc externs via `std.c.*` for runtime.
- **Cycle:** `atty` module imports `config`, `config_resolver` imports `defaults`, `defaults` imports `atty` for module-factory types. Works because each side only consumes the other's *types* lazily. Don't add eager value-level imports across the cycle.
- **Multi-module file rule (0.16):** a `.zig` file can only belong to *one* module. `defaults.zig` lives in the `config` module; don't `@import("defaults.zig")` from `root.zig` (in the `atty` module) — go via `@import("config")` and re-export.
- **DECSTBM + slave winsize must stay coordinated.** When the status bar is enabled, slim the slave PTY's reported `rows` by `reserve_rows` or the shell wraps wrong. SIGWINCH path in `proxy.zig` re-applies both.
- **Kitty keyboard protocol is on by default** with flag 1 (disambiguate). atty pushes `\x1b[>1u` at startup, pops on exit. The proxy's stdin handler intercepts unmapped CSI-u sequences (via `keymap.isCsiU`) and drops them so the shell never sees mojibake. Legacy keys (Ctrl+D/Ctrl+C/arrows/…) are not CSI-u shaped and pass through unchanged. `Ctrl+Shift+I` and Alt+i both bind to `incognito_toggle` — first uses the kitty CSI-u encoding, second is the classic-encoding fallback for terminals that don't support the protocol. **Release / repeat events** (`\x1b[<kc>;<mod>:3u` etc.) get dropped by `csiUToLegacy` so vim/nvim — which push a higher kitty kbd level than atty and start receiving press+release pairs from the terminal — don't see plain letters doubled when atty translates the press to legacy form. The raw CSI-u still passes through to alt-screen apps so they can decode events natively.
- **All `Alt+letter` LLM bindings ship in dual form** (legacy `\x1b<letter>` + kitty kbd CSI-u sibling). Terminals that push the kitty kbd disambiguate flag (Ghostty/kitty/foot/WezTerm) emit `\x1b[97;3u` for Alt+a rather than the legacy `\x1ba`; keymap matching runs BEFORE the CSI-u → legacy translation in the stdin path, so a legacy-only binding silently misses. See `src/defaults.zig`. Adding a new `Alt+letter` binding without the CSI-u sibling makes it inert on those terminals.
- **`atty doctor`** emits a shell snippet (`eval "$(atty doctor)"`) that diagnoses the OSC 133 integration chain — `$ATTY` set, shell detected, functions defined, `PROMPT_COMMAND` wired (array AND string form), PS1 contains `;A` / `;B` markers. Use when `Alt+S` reports "needs OSC 133" after running `atty init bash`. The typical failure is the init's `exec atty bash` step replaces the shell process and discards the in-memory function defs — eval needs to be in `.bashrc` (canonical) or run a SECOND time inside the atty session (`ATTY=1` skips the exec, runs OSC 133 setup in-place).
- **`Config.enter_action`** (LLM module) controls what bare Enter on `#: …` does. Default `.none` makes Enter a no-op in AI mode — Alt+A / Alt+S / Alt+Shift+S are the explicit triggers. `.single` / `.dialog` / `.auto` re-bind Enter to the corresponding action for muscle-memory users. The default exists to defend against accidental LLM calls when typing `#:` comments at the prompt.
- **syncFromCapture is length-aware AND cursor-preserving.** The proxy's `line_state.syncFromCapture(osc.input)` call only fires when (a) line_state is `uncertain` (recovery path — Arrow-Up recall, Tab completion) OR (b) `osc.input.len >= line_state.current().len`. Without the gate, bash readline's mid-typing PS1 redraws (which re-emit `;A`/`;B` markers and clear `osc.input`) would wipe the keystroke buffer between characters, observed as "ghost text matches last N-1 chars when typing N chars fast." See `src/proxy.zig` `syncFromCapture` site. **Inside `syncFromCapture` itself**, the early-return clears `uncertain` but preserves `cursor_pos` when the capture's content matches the existing buffer — the OSC 133 stream carries no cursor information, so clamping to EOL would falsely re-engage ghost when the user is mid-line after Arrow-Left × N + Tab (no completion match). Only the rewrite branch (content actually changed) clamps `cursor_pos = new_len`.
- **security_guard's daemon-`Block` path refuses outright.** `queryDaemon` branches on verdict before arming: Safe → forward, Warn → arm the `[y]/[a]/[t]/[B]/cancel` banner (`[a]llow always` session-trust + `[B]lock host forever` session-block landed in #142), **Block → write a red `REFUSED — <reason>` line, mark the shell PID Critical, and clear readline (`{.replace = "\x15"}`) with no follow-up keystroke.** Trust-cache hits short-circuit BOTH paths so prior `[t]rust` choices survive auto-Block enablement. Post-#147 there's no atty-side trust file — `rt.trust` is in-memory only, seeded lazily from the daemon's `commands.trusted.txt` via TrustList on first Enter, and mirrored on every `[t]` via TrustAdd. Render style is `Config.refused_style` (bold red 8-color default, distinct from `warning_style`'s dim italic).
- **e2e goldens are config-sensitive.** The e2e harness uses the user's compiled binary. If `src/config.zig` has `statusbar.enabled = true`, snapshots include the bar. CI/release builds use `config.def.zig` defaults (statusbar off) — that's the canonical environment.
- **First-paint after activate** of the statusbar should clear the reserved rows (old shell content can leak through DECSTBM otherwise).

## Things deliberately not yet built (don't propose without checking with user)

- OSC 133 prompt-marker support is **shipped** in `src/osc133.zig`. atty auto-detects: when the shell emits `\x1b]133;A/B/C/D` markers the proxy overrides line_state.committed with the marker stream's captured input region, closing the history-recall gap. Inert when no markers arrive. Enable shell-side via Ghostty's `shell-integration-features = osc-133`, or by sourcing your shell integration script (ble.sh / zsh4humans / VS Code's). Falls back to keystroke tracking automatically.
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
- "How do I install the full security stack?" → `docs/operator-workflow.md` (atty-guard + atom corpus + eBPF + doctor)
