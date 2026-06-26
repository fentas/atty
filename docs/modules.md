---
layout: default
title: Writing a module
permalink: /modules/
---

# Writing a module
{:.no_toc}

## Built-in modules

| Module | Purpose | Default |
|---|---|---|
| [`atuin`]({{ '/modules/atuin/' | relative_url }}) | Ghost suggestions + recording via Atuin's `atuin search` / `atuin history start` | opt-in |
| [`guardrail`]({{ '/modules/guardrail/' | relative_url }}) | Comptime-list confirmation for `rm -rf`, `dd`, fork bombs, `curl … \| sh` | ✅ |
| [`history`]({{ '/modules/history/' | relative_url }}) | Shell-native suggestions from `~/.bash_history` / `~/.zsh_history` | ✅ |
| [`llm`]({{ '/llm/' | relative_url }}) | `#: <intent>` → command rewrite; Alt+A single · Alt+S dialog · Alt+C chat · Alt+r resend | opt-in |
| [`mouse_links`]({{ '/modules/mouse_links/' | relative_url }}) | Left-click a path token in output → `$EDITOR +LINE 'path'` | opt-in |
| [`mouse_urls`]({{ '/modules/mouse_urls/' | relative_url }}) | Left-click a URL → opener, gated by `whitelist_only` / `ask_each` trust | opt-in |
| [`security_guard`]({{ '/modules/security_guard/' | relative_url }}) | Pre-Enter Tier-1 + UDS to atty-guard sidecar; `Alt+Shift+W` warn dump | opt-in |

Every row has a dedicated page — click through for configuration knobs and limitations.

* TOC
{:toc}

A module is a Zig type — typically produced by a
`configure(comptime cfg: Config) type` factory — that exposes some
subset of:

```zig
pub const name: []const u8                          // optional, for logs
pub const Runtime  : type
pub const default_bindings: []const Binding         // optional — see below
pub fn   attach    (allocator, io) !Runtime
pub fn   detach    (rt: *Runtime, io) void
pub fn   onInput   (rt: *Runtime, ctx: *Context, input: []const u8) !Action
pub fn   onOutput  (rt: *Runtime, ctx: *Context, output: []const u8) !void
pub fn   onTick    (rt: *Runtime, ctx: *Context, elapsed_ms: u64) !void
pub fn   onLineCommit(rt: *Runtime, ctx: *Context, line: []const u8) !void
pub fn   onResize  (rt: *Runtime) void              // optional — re-arm size-aware paints
pub fn   onMouseClick(rt: *Runtime, ctx: *Context, evt: mouse.Event) !MouseAction
pub fn   onAction  (rt: *Runtime, ctx: *Context, action: anytype) !bool
pub fn   deleteHistoryMatch(rt: *Runtime, ctx: *Context, line: []const u8) !void
pub fn   provideGhostText(rt: *Runtime, ctx: *Context) !?[]const u8
pub fn   provideGhostList(rt: *Runtime, ctx: *Context) !?[]const []const u8
pub fn   pollShellInput(rt: *Runtime, ctx: *Context) !?[]const u8
pub fn   provideHintText(rt: *Runtime, ctx: *Context) !?[]const u8
pub fn   provideErrorText(rt: *Runtime, ctx: *Context) !?[]const u8
pub fn   provideTermBytes(rt: *Runtime, ctx: *Context) !?[]const u8
pub fn   statusText(rt: *Runtime, ctx: *Context) !?[]const u8
pub fn   isOverlayActive(rt: *Runtime) bool         // claims atty's alt-screen
pub fn   isInlineChatActive(rt: *Runtime) bool      // claims rows above the statusbar
pub fn   extraReserveRows(rt: *Runtime) u16         // # rows the module wants reserved
```

Modules that paint a persistent alt-screen overlay on the user's
outer terminal (via `provideTermBytes` emitting `\x1B[?1049h`) must
implement `isOverlayActive` so the proxy can divert PTY-master
output into a ring buffer while the overlay is up — without it,
shell output writes to STDOUT clobber the overlay's painted
content. The LLM module's full chat overlay (`Alt+Shift+C`) is the
current example. The inline chat panel (`Alt+C`) takes a different
path — it grows the statusbar reservation via `extraReserveRows`
rather than taking over the alt-screen, so it does NOT implement
`isOverlayActive` (the shell stays visible above the panel).

The framework introspects each module via `@hasDecl` at comptime —
missing hooks are statically eliminated from the dispatch loop, not
merely skipped at runtime.

## Shared types

```zig
pub const Action = union(enum) {
    forward,                    // pass bytes through unchanged
    swallow,                    // drop bytes entirely (short-circuits)
    replace: []const u8,        // substitute these bytes
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    line:      *LineState,      // current user input buffer + uncertain flag
    scratch:   *std.ArrayList(u8),
    is_tty:    bool,
    incognito: bool,            // user toggled incognito mode
    shell_alt_screen_active: bool,  // shell-side TUI (nvim/k9s/less) is in alt-screen
    module_overlay_active:   bool,  // any module's overlay is up on atty's outer terminal
    // …other fields (cursor_row, subprocess) — see src/module.zig
};

pub const Error = error{ ModuleFailed, OutOfMemory };
```

## Minimal example — Upper

Capitalise every keystroke before it reaches the shell:

```zig
const std = @import("std");
const m = @import("../module.zig");

pub const Config = struct {};

pub fn configure(comptime _: Config) type {
    return struct {
        pub const name = "upper";

        pub const Runtime = struct {
            buf: [256]u8 = undefined,
        };

        pub fn attach(_: std.mem.Allocator) !Runtime { return .{}; }
        pub fn detach(_: *Runtime) void {}

        pub fn onInput(
            rt: *Runtime,
            _: *m.Context,
            input: []const u8,
        ) m.Error!m.Action {
            if (input.len > rt.buf.len) return .forward;
            for (input, 0..) |b, i| rt.buf[i] = std.ascii.toUpper(b);
            return .{ .replace = rt.buf[0..input.len] };
        }
    };
}
```

Then in `src/config.zig`:

```zig
const atty = @import("atty");

pub const Upper = @import("modules/upper.zig").configure(.{});
// or if you've placed it inside src/modules/:
//   atty.modules.upper.configure(.{})

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    Upper,
};
```

## Lifecycle

- `attach(allocator)` returns the initial Runtime value. Spawn worker
  threads, open sockets, etc. here. The framework heap-allocates the
  Runtime — you don't need to.
- `detach(rt)` is called once at shutdown. Signal worker threads to
  stop, join them, close sockets.

Allocation: each module's Runtime is heap-allocated by `attachAll`
and freed by `detachAll`. Modules don't manage their own Runtime
allocation.

## Hot-path rules

`onInput` runs on every single keystroke (~100 Hz worst case).
Therefore:

- **No allocations.** Use a fixed-size buffer in your Runtime, or the
  per-dispatch `ctx.scratch`.
- **No blocking I/O.** If you need a network/socket lookup, do it on a
  worker thread and expose the result via `provideGhostText`.
- **No global locks.** Per-Runtime mutexes are fine.

`provideGhostText` runs whenever the proxy needs to refresh the
overlay (after a keystroke, after shell output, on tick). It runs
*after* `onInput` for that event, so `ctx.line.current()` reflects
the post-input buffer.

`onTick` fires on poll() timeout (default 100 ms). Use it for
periodic work — TTL expiry, status updates. Don't do heavy work
here; ticks are not throttled.

`onLineCommit` fires once per Enter-press, *after* the line buffer has
been cleared, with the pre-Enter line as its argument. Use it for
history recording, audit logs, telemetry. The hook **does not fire**
when the line was empty or when `line_state.uncertain` was true at
submit time — recording a wrong line is worse than missing one, so
the proxy skips uncertain commits. Don't block here; spawn a worker
or detach a thread if your work involves I/O.

## Action semantics

| Returned action    | What happens                                                                                                                 |
|--------------------|------------------------------------------------------------------------------------------------------------------------------|
| `.forward`         | Bytes flow on to the next module.                                                                                            |
| `.swallow`         | Chain stops, nothing is written to the PTY.                                                                                  |
| `.replace`         | Next modules see the new bytes; PTY writes those.                                                                            |
| `.replace_commit`  | Same as `.replace`, AND fires `onLineCommit` on the pre-replace line **when the original input contained Enter** (see below).|

If a module returns `.replace`, downstream modules see the *replaced*
bytes, not the original. This composes guardrail with autosuggestion:
guardrail can swallow Enter, and Atuin never sees the keystroke that
would have submitted a dangerous command.

`.replace_commit` exists for modules that intercept Enter to do
something custom but still want the typed line to land in history.
The LLM module uses it: typing `#: list files` + **`Alt+A`** (or
**Enter** when `Config.enter_action = .single` — default is
`.none`, an explicit-action-only safety gate) returns
`.replace_commit = "\x15"` — Ctrl+U kills the readline buffer so
the shell doesn't run the prompt, but the proxy fires
`dispatchLineCommit` on `#: list files` so atuin / history record
it. The next time the user starts typing `#: l…` their prior
prompts surface as ghost suggestions.

**Important caveat**: `.replace_commit` does NOT unconditionally
fire `onLineCommit`. The proxy still requires the *original* input
chunk (the bytes the user just typed, pre-replace) to contain
Enter — and the usual gating around incognito mode, leading-space
HISTCONTROL convention, and `committed_was_uncertain` still
applies. Returning `.replace_commit` on a non-Enter keystroke is a
no-op as far as history is concerned; the only thing it changes
vs. plain `.replace` is that the Enter test looks at the original
bytes instead of the replacement.

The dispatcher preserves `.replace_commit` across later modules'
plain `.replace` substitutions — once a module asks for the commit
to fire, the decision sticks (only the bytes get overwritten).

## statusText — contributing to the status bar

Modules can advertise a one-line segment to the bottom status bar by
implementing the optional `statusText` hook:

```zig
pub fn statusText(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
    if (rt.queued_records > 0) {
        // Cache in your Runtime; this runs on every render cycle.
        return rt.cached_status_line;
    }
    return null;   // null = no segment this frame
}
```

The proxy collects every module's segment, joins them with ` │ `,
prefixes the optional `config.statusbar.base_text`, and paints the
result into the reserved row. Returning `null` (or an empty string)
skips the segment cleanly — separators stay correct.

Segment order = module declaration order. There's no claim on
columns; the assembled text is left-aligned in the row and silently
truncated past 256 bytes. If you want per-module max-width, format
your own segment with a cap.

Don't allocate in `statusText` — it runs every render cycle. Cache
the formatted string in your `Runtime`.

## provideHintText / provideErrorText — notifications above the status bar

When the statusbar is enabled with `reserve_rows >= 2`, the row
above the status text is a transient notification slot. Two
parallel hooks fill it, each with its own visual treatment and
TTL:

```zig
pub fn provideHintText(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8;
pub fn provideErrorText(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8;
```

- **Hints** (`provideHintText`) render in `config.statusbar.hint_style`
  — dim italic by default. Used for informational annotations the
  user should see briefly (LLM explanation of the injected command,
  guardrail "blocked: …" rationale, …).
- **Errors** (`provideErrorText`) render in `config.statusbar.error_style`
  — dim red by default, with a leading `⚠ ` glyph so the row reads
  as a notification rather than info text. Take precedence over
  hints on the same row.

Both are **one-shot**: return the text once on an edge change,
return `null` thereafter. The proxy hands the result to
`StatusBar.setHint` / `setError` which manage TTL from there
(`config.statusbar.hint_ttl_ms` defaults to 30s; `error_ttl_ms`
defaults to 60s). After expiry the slot reverts — a still-active
suppressed hint resurfaces once its error sibling expires.

Typical pattern:

```zig
pub const Runtime = struct {
    pending_hint_buf: [256]u8 = undefined,
    pending_hint_len: usize = 0,
    pending_hint: bool = false,
};

// Set the pending flag from wherever your data arrives — worker
// thread, onLineCommit, an external callback.
fn latchHint(rt: *Runtime, msg: []const u8) void {
    const n = @min(msg.len, rt.pending_hint_buf.len);
    @memcpy(rt.pending_hint_buf[0..n], msg[0..n]);
    rt.pending_hint_len = n;
    rt.pending_hint = true;
}

pub fn provideHintText(rt: *Runtime, _: *m.Context) m.Error!?[]const u8 {
    if (!rt.pending_hint) return null;
    rt.pending_hint = false;
    return rt.pending_hint_buf[0..rt.pending_hint_len];
}
```

## provideTermBytes — write to the user's outer terminal

`pollShellInput` writes to the pty.master (the shell sees the
bytes); `provideTermBytes` writes to the user's *outer* stdout
(only the user's terminal sees the bytes — the shell is unaware).
Used for OSC sequences that affect the terminal as a whole:
cursor colour transitions, title updates, palette hints.

```zig
pub fn provideTermBytes(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8;
```

Same one-shot contract as `provideHintText`. The proxy calls per
tick; if non-null, the returned bytes are written to
`STDOUT_FILENO`. The bytes should be edge-triggered — a module
that returns the same OSC sequence on every tick will flood the
terminal with redundant escapes.

Example — emit OSC 12 (set cursor colour) on a state transition:

```zig
pub fn provideTermBytes(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
    const matches = std.mem.startsWith(u8, ctx.line.current(), "#: ");
    if (matches and !rt.cursor_signal_active) {
        rt.cursor_signal_active = true;
        return "\x1B]12;cyan\x07";
    }
    if (!matches and rt.cursor_signal_active) {
        rt.cursor_signal_active = false;
        return "\x1B]112\x07"; // reset to default
    }
    return null;
}
```

Don't allocate here — it runs every tick. Static literals or
fixed buffers on the Runtime only.

## pollShellInput — inject bytes into the shell asynchronously

Sibling of `provideTermBytes` for the *shell-input* direction.
Returned bytes go to `pty.master` as if the user had typed them —
the shell echoes them back, readline lets the user edit or
submit. Used by the LLM module to inject a generated command for
review after the worker thread returns a response.

```zig
pub fn pollShellInput(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8;
```

The proxy also runs `line_state.applyInput` on the injected
bytes, so downstream `onInput` / `onLineCommit` see the injected
command as if the user had typed it.

Same one-shot pattern — return bytes once when ready, return
`null` thereafter. First non-null wins across modules (order =
declaration order in `config.modules`).

## default_bindings — registering module-owned keys

A module can ship its own default keybindings instead of relying on
the user to wire them up in `Keymap.bindings`:

```zig
pub const default_bindings: []const atty.keymap.Binding = &.{
    .{
        .bytes = atty.keymap.key("Alt+a"),
        .action = .llm_exec_single,
        .label = "Alt+A",
        .description = "LLM: single-shot",
    },
    // dual encoding for kitty-keyboard terminals
    .{ .bytes = "\x1b[97;3u", .action = .llm_exec_single },
};
```

The dispatcher's `all_default_bindings` const comptime-concatenates
every declaring module's slice. The proxy's stdin matcher consults
`config.keymap.bindings` first (user wins) AND falls back to the
module list — so:

- A user who removes a module from their `modules` tuple loses ALL
  of that module's keys automatically (no manual cleanup).
- A user who wants to rebind one can still list an override in their
  own `Keymap.bindings`; first-match precedence keeps their choice.
- New modules added to the tuple bring their keys without forcing
  the user to edit config.

**`label` + `description`** feed the `Alt+H` cheat-sheet renderer.
Leave them empty on dual-encoding siblings (only one entry per
action variant gets printed — the renderer dedupes by enum tag).

## extraReserveRows — claim rows above the statusbar

Modules that paint a slim panel pinned to the bottom of the user's
main screen (not an alt-screen overlay) implement
`extraReserveRows` to advertise how many rows they want reserved:

```zig
pub fn extraReserveRows(rt: *Runtime) u16 {
    return if (rt.panel_open) cfg.panel_rows else 0;
}
```

The proxy sums every module's response each iteration, clamps to
`rows-1` so the shell always has at least one row, and applies the
result via `statusbar.applyReserveRows` (non-screen-clobbering —
unlike `activate` which emits `ED 2`). Then the panel's
`provideTermBytes` paint runs into the newly-reserved rows.

Pair with `isInlineChatActive` (bool getter) so the proxy can:

- suppress ghost text from painting INTO the reserved rows
- skip `line_state.applyInput` for keystrokes the module is
  swallowing (otherwise the in-flight chat text pollutes the
  shell-side line model)

The LLM module's Alt+C inline chat panel is the canonical example.

## provideGhostList — contributing to the multi-row pick list

Companion to `provideGhostText`. Where `provideGhostText` returns one
suggestion (painted after the cursor), `provideGhostList` returns up
to N alternatives painted in dim rows below the prompt as a numbered
list:

    $ git status              ← inline ghost (newest match)
     1: git push origin master
     2: git commit -m foo
     3: git log

The proxy paints this list dynamically when `config.ghost.list_count > 0`
and the user is typing a non-empty, non-uncertain line. Key bindings
`Ctrl+1..Ctrl+9` (kitty kbd) and `Esc+1..Esc+9` (legacy fallback)
pick the Nth entry — same substitution semantics as `ghost_accept`.

```zig
pub fn provideGhostList(rt: *Runtime, ctx: *m.Context) m.Error!?[]const []const u8 {
    if (ctx.line.uncertain) return null;
    const query = ctx.line.current();
    if (query.len == 0) return null;

    // Build up to N matches via the shared `_lib.ListBuilder` —
    // dedupes by content + skips the inline-ghost entry so the list
    // complements rather than duplicates the inline ghost.
    var builder = lib.ListBuilder(9){};
    const inline_match = findInlineSuggestion(rt, query); // your own
    for (yourCandidates(rt, query)) |entry| {
        if (builder.full()) break;
        _ = builder.tryAdd(entry, inline_match);
    }
    if (builder.len == 0) return null;
    // Spill into your Runtime's persistent storage — the slice we
    // return must outlive the local builder frame.
    @memcpy(rt.list_slices[0..builder.len], builder.items());
    rt.list_slices_len = builder.len;
    return rt.list_slices[0..rt.list_slices_len];
}
```

The same "first non-null wins" precedence model as `provideGhostText`
applies — order modules in your config to express priority.

`src/modules/_lib.zig` provides `nowMs()` + `ListBuilder(cap)` —
shared helpers with the dedup-on-add pattern both built-in modules
use. Reach for them rather than re-rolling.

## deleteHistoryMatch — react to the user's "delete this line" key

When the user fires `Action.delete_history_match` (default `Ctrl+Shift+D`),
the proxy calls every module's `deleteHistoryMatch` with the current
line buffer content. Both built-in record-keeping modules implement
this — `history` removes matching lines from its in-memory + on-disk
log, and `atuin` shells out to `atuin search --delete` with the
caller-selected `delete_scope` (default `.exact`, exploiting fuzzy
mode's `^...$` anchors for a true exact-match delete since atuin
v18 has no per-entry-ID delete CLI).

```zig
pub fn deleteHistoryMatch(rt: *Runtime, ctx: *m.Context, line: []const u8) m.Error!void {
    // Remove every entry in your store whose content equals `line`.
    // `line` is non-empty and the line state was certain when the
    // user pressed the key — the proxy gates these conditions.
    ...
}
```

After dispatching, the proxy sends `\x15` (Ctrl+U) to the shell so
the prompt clears, and flashes a transient message in the status bar.

## ctx.incognito — opt into stricter behavior

The proxy gates `dispatchLineCommit` when the user has flipped
incognito on (or when the line starts with a space —
`HISTCONTROL=ignorespace` convention), so atuin / history never see
the commit and don't record. Ghost suggestions and queries keep
working — incognito is about not *recording*, not about hiding.

If your module wants to be stricter — e.g. suppress its own
suggestions while typing a secret — read `ctx.incognito` and
short-circuit. The default is "still suggest".

## Order matters

The dispatcher walks `config.modules` front-to-back. Put
short-circuiting modules (guardrail) first; passive ones (Atuin) last.

For `provideGhostText` the *first non-null* result wins, so order
expresses priority. There's no negotiation between modules — a later
module is asked only if every earlier one returned null.

### Composing two ghost providers

With both atuin and history enabled:

```zig
pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.atuin.configure(.{}),     // asked first
    atty.modules.history.configure(.{}),   // fallback when atuin is null
};
```

Per keystroke, the proxy calls `gatherGhostText` once. It iterates
front-to-back and returns the first non-null:

```zig
inline for (modules, 0..) |M, i| {
    if (comptime @hasDecl(M, "provideGhostText")) {
        if (try M.provideGhostText(rts[i], ctx)) |text| return text;
    }
}
```

**The async/sync subtlety.** Atuin's `provideGhostText` reads a
worker-thread mailbox (`res_buf`). On the very first keystroke of a
new prefix the mailbox is still empty — atuin returns null while its
worker shells out to `atuin search`. During that ~50 ms window the
fallback (history, which is synchronous in-memory) gets to serve the
suggestion. Once atuin's worker finishes writing `res_buf`, the next
render swaps in atuin's answer. If atuin and history disagree, the
overlay briefly switches as you type.

This is a deliberate trade-off, not a bug: it keeps ghost text visible
during atuin's lookup latency. If you'd rather see a single source,
remove the fallback or put history first.

## Testing

Write tests inline in your module file. They'll be picked up by
`zig build test` if you add your file to `src/unit_tests.zig`.

```zig
test "my module swallows the dangerous Enter" {
    const M = configure(.{});
    var rt = try M.attach(std.testing.allocator);
    defer M.detach(&rt);

    var line = LineState{};
    _ = line.applyInput("rm -rf /");
    var scratch = std.ArrayList(u8).init(std.testing.allocator);
    defer scratch.deinit();
    var ctx = m.Context{
        .allocator = std.testing.allocator,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    try std.testing.expectEqual(m.Action.swallow, try M.onInput(&rt, &ctx, "\r"));
}
```

See `src/modules/guardrail.zig` for a worked example with an
injectable output sink so tests don't write to stderr.

## Verifying dead-code elimination

The strong claim is that disabled modules contribute nothing to the
binary. Verify it:

```sh
# build with all modules
make build
size=$(stat -c %s zig-out/bin/atty)

# remove a module from config.modules, rebuild
$EDITOR src/config.zig
make build
smaller=$(stat -c %s zig-out/bin/atty)

# check symbols
nm zig-out/bin/atty | grep -c atuin  # should be 0 after removing Atuin
```

If a module's symbols persist after removal, you've found a leak
(probably a forgotten `@import` somewhere) — file an issue.
