//! Keymap — proxy-level key bindings, dwm `keys[]` style.
//!
//! The terminal sends one or more bytes per keypress (`\x1b[C` for
//! right-arrow, `\x06` for Ctrl-F, …). When the proxy reads stdin and
//! the bytes match a `Binding.bytes`, the corresponding `Action` runs
//! instead of the original keystroke being forwarded to the shell.
//!
//! atty defines the closed set of `Action`s; user configs assemble
//! the bindings list. Modifier keys are baked into the byte sequence
//! itself — `\x1b[1;5C` is Ctrl-Right, etc. — so there's no separate
//! modifier field to bookkeep.
//!
//! Why this lives at the proxy and not on a module: the trigger ("this
//! key was pressed") and the payload ("the ghost text from whichever
//! module won the gather race") are decoupled. A single accept key
//! shouldn't have to know whether atuin or history provided the
//! suggestion.
//!
//! File layout: this file owns the Action enum, the Binding struct,
//! the linear `match` scan, and the public re-exports. The compile-
//! time `key("Right")` name parser lives in `keymap/parser.zig`;
//! the kitty-keyboard CSI-u encode/decode + stream translator live
//! in `keymap/csiu.zig`. The split keeps each file under a few
//! hundred lines and prevents the ~150-line CSI-u table and the
//! ~200-line key-name parser from crowding the public types.

const std = @import("std");

const parser = @import("keymap/parser.zig");
const csiu = @import("keymap/csiu.zig");

/// Compile-time key name parser — `key("Right")` returns `"\x1b[C"`.
/// Re-exported from `keymap/parser.zig`. Unknown names trip
/// `@compileError` so typos in user configs are caught at build
/// time.
pub const key = parser.key;

/// Kitty keyboard protocol push/pop byte strings. Re-exported from
/// `keymap/csiu.zig`. Proxy emits the push at startup so terminals
/// like Ghostty disambiguate Ctrl+Shift+I from Tab; pop on exit.
pub const kitty_kbd_push = csiu.kitty_kbd_push;
pub const kitty_kbd_pop = csiu.kitty_kbd_pop;

/// Re-exported CSI-u helpers from `keymap/csiu.zig`. The proxy uses
/// these to detect, classify, and fold kitty-keyboard sequences
/// back to legacy bytes before forwarding them to bash readline
/// (which doesn't speak the protocol).
pub const csiUToLegacy = csiu.csiUToLegacy;
pub const isCsiU = csiu.isCsiU;
pub const csiULen = csiu.csiULen;
pub const translateCsiUStream = csiu.translateCsiUStream;

pub const Action = union(enum) {
    /// Replace the keystroke with the bytes of the currently-visible
    /// ghost suggestion (i.e. accept fish-style autosuggestion).
    /// No-op when no ghost is showing or the line is in an uncertain
    /// state.
    ghost_accept,
    /// Accept ONE word of the ghost suggestion (fish's Alt+f /
    /// Ctrl+Right semantics — partial accept). The "word" is the
    /// next whitespace-delimited chunk INCLUDING the trailing
    /// whitespace, so successive presses walk through the
    /// suggestion section by section. Useful when the bottom of
    /// the ghost is correct but you want to edit the middle.
    /// No-op when no ghost / uncertain line / already at end of
    /// suggestion.
    ghost_accept_word,
    /// Flip incognito mode on/off. While on: line commits aren't
    /// recorded (no atuin / history writes); the status bar prepends
    /// a 🔒 segment; a one-line stderr toast announces the flip.
    incognito_toggle,
    /// Delete every history entry that matches the current line.
    /// Fires `deleteHistoryMatch` on every module that implements it
    /// (today: history + atuin), then sends Ctrl+U to the shell so
    /// the prompt clears, and flashes a transient status-bar message.
    delete_history_match,
    /// Pick the Nth entry from the multi-suggestion list rendered
    /// below the prompt and replace the keystroke with its trailing
    /// portion (same substitution as ghost_accept, but indexed). N
    /// is 1-based and capped at 9; out-of-range picks no-op.
    /// Default bindings: Ctrl+1..Ctrl+9 (kitty kbd CSI-u) and
    /// Esc+1..Esc+9 (legacy ESC+digit; doubles as Alt+digit on
    /// non-kitty terminals).
    ghost_pick: u8,

    /// AI mode — single-prompt. Fires when the user is in AI mode
    /// (line starts with `#: `) and presses the bound key (default
    /// Alt+A). The module:
    /// - reads the task body from `line_state.current()` (after the
    ///   prefix), trimmed of surrounding whitespace
    /// - signals the worker thread with the task
    /// - queues `\x15` (Ctrl+U) on `pending_injection` so the next
    ///   `pollShellInput` tick drains it to the shell, which wipes
    ///   the typed `#: …` text. The LLM response is then injected
    ///   when the worker finishes.
    /// - clears `ai_mode_active` (the line is about to be wiped)
    ///
    /// The legacy `#:<Enter>` trigger is also still wired for
    /// backwards compat — both routes call the same
    /// `triggerSinglePrompt` helper. The only difference is how
    /// Ctrl+U gets surfaced: the Enter path returns
    /// `.replace_commit = "\x15"` from `onInput` (the proxy
    /// substitutes the Enter), the Alt+A path queues it on
    /// `pending_injection` (since `onAction` has no return-value
    /// channel to the proxy). Subsequent commits may remove the
    /// Enter trigger in favour of the explicit-action workflow.
    llm_exec_single,
    /// AI mode — dialog exec. LLM proposes a command + description,
    /// lands on the prompt with an indicator, user confirms with
    /// Enter or cancels. Command's output is fed back to the LLM,
    /// which decides the next step (command, question, or done).
    /// Loop continues until done or `llm_exec_cancel`. Default
    /// binding: Alt+S. Requires OSC 133 (`;C`/`;D`) for output
    /// capture — fails hard with a statusbar message if absent.
    llm_exec_dialog,
    /// AI mode — auto exec. Same as dialog but auto-confirms each
    /// command after a brief visible delay
    /// (`config.llm_exec.auto_delay_ms`). Default binding:
    /// Alt+Shift+S.
    llm_exec_auto,
    /// AI mode — cycle through the configured `models` list.
    /// Current pick surfaces in the statusbar. Default Alt+M.
    llm_exec_cycle_model,
    /// AI mode — open/close the help overlay listing keys + current
    /// state. Default Alt+H.
    llm_exec_toggle_help,
    /// Cancel a running exec loop (dialog or auto). Returns to the
    /// shell prompt at a clean state, clears any captured output
    /// and partially-generated suggestions. Default Ctrl+Shift+X.
    /// Works while exec is running OR while AI mode is just entered
    /// but no action has fired yet (in which case it's equivalent
    /// to Esc).
    llm_exec_cancel,
    /// Re-emit the LLM session conclusion (the formatted summary
    /// printed above the next prompt when the LLM finished a
    /// dialog). Default Alt+C. Useful to recall the result of a
    /// completed session that has scrolled out of view. No-op
    /// when no conclusion has been captured yet (i.e. before the
    /// first `action=done` in this atty session).
    ///
    /// Phase 1 of the chat-overlay design (per
    /// docs/llm-exec-mode-followups.md): re-display only. Phase 2
    /// will turn this into a persistent overlay with chat input +
    /// LLM round-trip + context controls. The action variant is
    /// added now so the keymap surface is stable across the
    /// two-PR rollout.
    llm_chat_overlay_toggle,
};

pub const Binding = struct {
    /// The raw bytes the terminal emits for the key. Matched against
    /// the entire stdin read — terminals send most named keys as a
    /// single read, but the match is byte-exact so chunked reads (rare)
    /// won't trigger.
    bytes: []const u8,
    action: Action,
};

/// Linear scan over `bindings` looking for an exact byte match against
/// `input`. Returns the bound action, or null when no binding matches
/// (or the input is empty / a binding has an empty `.bytes`). Pulled
/// out of the proxy loop so the dispatch logic is testable without a
/// PTY fixture.
pub fn match(bindings: []const Binding, input: []const u8) ?Action {
    if (input.len == 0) return null;
    for (bindings) |bind| {
        if (bind.bytes.len == 0) continue;
        if (std.mem.eql(u8, input, bind.bytes)) return bind.action;
    }
    return null;
}

test "match returns null on empty input" {
    const bs = [_]Binding{.{ .bytes = "\x06", .action = .ghost_accept }};
    try std.testing.expectEqual(@as(?Action, null), match(&bs, ""));
}

test "match skips bindings with empty .bytes (so a half-built config can't always-fire)" {
    const bs = [_]Binding{
        .{ .bytes = "", .action = .ghost_accept },
        .{ .bytes = "\x06", .action = .ghost_accept },
    };
    try std.testing.expectEqual(@as(?Action, null), match(&bs, ""));
    try std.testing.expectEqual(Action.ghost_accept, match(&bs, "\x06").?);
}

test "match resolves a real binding by exact byte sequence" {
    const bs = [_]Binding{
        .{ .bytes = key("Right"), .action = .ghost_accept },
        .{ .bytes = key("Ctrl+Shift+I"), .action = .incognito_toggle },
        .{ .bytes = key("Ctrl+Shift+D"), .action = .delete_history_match },
    };
    try std.testing.expectEqual(Action.ghost_accept, match(&bs, "\x1b[C").?);
    try std.testing.expectEqual(Action.incognito_toggle, match(&bs, "\x1B[105;6u").?);
    try std.testing.expectEqual(Action.delete_history_match, match(&bs, "\x1B[100;6u").?);
    try std.testing.expectEqual(@as(?Action, null), match(&bs, "\x1b[A"));
}

test "match does not bind Ctrl+C against the shipped default bindings" {
    // Regression guard: Ctrl+C (0x03) is a legacy control code we
    // MUST pass through to the shell so SIGINT-style line-abort
    // still works. None of the default bindings shall accidentally
    // shadow it. We replicate the default list verbatim here rather
    // than @import("defaults.zig") to avoid the multi-module file
    // rule (defaults.zig lives in the `config` module, keymap in
    // `atty`). If the upstream defaults ever change, e2e + the
    // ctrl_c_aborts_line scenario will catch behavioural regressions;
    // this test specifically forbids any binding for these bytes.
    const defaults_bindings = [_]Binding{
        .{ .bytes = key("Right"), .action = .ghost_accept },
        .{ .bytes = key("End"), .action = .ghost_accept },
        .{ .bytes = key("Ctrl+F"), .action = .ghost_accept },
        .{ .bytes = key("Ctrl+Tab"), .action = .ghost_accept },
        .{ .bytes = key("Ctrl+Shift+I"), .action = .incognito_toggle },
        .{ .bytes = key("Alt+i"), .action = .incognito_toggle },
        .{ .bytes = key("Ctrl+Shift+D"), .action = .delete_history_match },
    };
    try std.testing.expectEqual(@as(?Action, null), match(&defaults_bindings, "\x03"));
    try std.testing.expectEqual(@as(?Action, null), match(&defaults_bindings, "\x04"));
    try std.testing.expectEqual(@as(?Action, null), match(&defaults_bindings, "\x1A"));
    try std.testing.expectEqual(@as(?Action, null), match(&defaults_bindings, "\x1C"));
}

test "match requires byte-exact equality (chunked reads don't trigger)" {
    const bs = [_]Binding{.{ .bytes = "\x1b[C", .action = .ghost_accept }};
    try std.testing.expectEqual(@as(?Action, null), match(&bs, "\x1b["));
    try std.testing.expectEqual(@as(?Action, null), match(&bs, "\x1b[Cx"));
}

test "Action.ghost_pick carries the index as a payload" {
    // Regression guard for the union(enum) shape — switch sites in
    // proxy.zig depend on capturing the index via `|n|`.
    const a: Action = .{ .ghost_pick = 3 };
    switch (a) {
        .ghost_pick => |n| try std.testing.expectEqual(@as(u8, 3), n),
        else => return error.TestFailed,
    }
}

// Pull in the sub-files so `zig build test` discovers their tests
// when only `keymap.zig` is referenced from `unit_tests.zig`.
test {
    _ = parser;
    _ = csiu;
}
