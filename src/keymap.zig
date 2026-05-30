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
pub const isModifiedVtCsi = csiu.isModifiedVtCsi;
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
    /// Open/close the FULL-SCREEN chat overlay — atty's alt-screen
    /// takes over the terminal and renders the LLM conversation +
    /// chat input. Default **Alt+Shift+C**. Useful for focused
    /// review of long conversations / structured assistant
    /// rendering.
    ///
    /// `Alt+C` (without Shift) is reserved for the lighter-weight
    /// inline chat mode (see `llm_inline_chat_toggle`) that keeps
    /// the shell visible above a reserved chat strip — that's the
    /// default for casual back-and-forth.
    llm_chat_overlay_toggle,
    /// Open/close the INLINE chat mode — reserves N rows above the
    /// statusbar for a slim chat panel; the shell stays visible
    /// above the reservation and keystrokes route to the chat
    /// input. Default **Alt+C**. The inline mode is for "ask the
    /// LLM something while the current command's output is still
    /// scrolling past." For deep review use Alt+Shift+C (full
    /// overlay).
    llm_inline_chat_toggle,
    /// While the inline chat panel is open, move keystroke focus to
    /// the SHELL prompt without closing the panel. Default
    /// **Ctrl+Up**. The panel stays painted; new keystrokes flow to
    /// the shell as usual. The block-cursor glyph in the chat input
    /// row dims to signal "panel is parked." Sibling of
    /// `chat_focus_to_chat`. No-op when the panel isn't open.
    chat_focus_to_shell,
    /// Move keystroke focus back into the inline chat panel. Default
    /// **Ctrl+Down**. Sibling of `chat_focus_to_shell`. No-op when
    /// the panel isn't open.
    chat_focus_to_chat,
    /// Scroll the chat history view back / forward by one turn.
    /// Targets whichever chat surface is open: overlay first, then
    /// the inline panel (only when focus is in the panel — Ctrl+Up
    /// parks focus on the shell, and shell-scope PageUp belongs to
    /// the shell, not the chat). Bumps `chat_view_offset` (overlay)
    /// or `chat_inline_view_offset` (inline) by 1, clamped so the
    /// view never moves past the oldest turn. Sibling
    /// `chat_scroll_page_*` scrolls by one viewport's worth.
    ///
    /// Default **Shift+Up / Shift+Down** while focus is in a
    /// chat surface; otherwise the keystroke falls through to
    /// the shell unchanged.
    chat_scroll_up,
    chat_scroll_down,
    /// Scroll the chat history view back / forward by one page —
    /// "page" = the number of scrollback rows the surface is
    /// currently showing (8 in the overlay's small layout, panel
    /// rows minus 2 in the inline panel). Default
    /// **PageUp / PageDown** while focus is in a chat surface;
    /// otherwise unbound and PageUp/PageDown pass through to the
    /// shell unchanged.
    chat_scroll_page_up,
    chat_scroll_page_down,
    /// Snap the chat view back to the live tail (newest turn at the
    /// bottom). Reverses any PageUp scrolling without having to
    /// PageDown the matching amount. Default **Ctrl+End** while
    /// focus is in a chat surface; bare End is already taken by
    /// `ghost_accept` so the modified arrow form is the only
    /// non-conflicting option.
    chat_scroll_to_tail,
    /// Recall the most recent persisted dialog — loads its turns
    /// + conclusion into the in-memory ring and opens the inline
    /// chat panel. Refuses (with a hint) when a chat surface is
    /// already open or persistence is disabled / has no
    /// archived dialogs. Default **Alt+R**. A picker overlay
    /// surfacing the FULL archive (not just the newest) is a
    /// future follow-up; this binding lands the "resume the
    /// conversation I just had" use case.
    chat_recall,
    /// Grow / shrink the inline chat panel by one row. Hardcoded
    /// minimum is 3 rows (divider + ≥1 scrollback + input — same
    /// invariant `Config.inline_chat_rows`'s comptime-assert
    /// enforces). Upper bound is the proxy's `applyReserveRows`
    /// clamp against live terminal height. Live height lives in
    /// `Runtime.chat_inline_rows_override`; resets when the panel
    /// closes. Default **Ctrl+Alt+Up / Ctrl+Alt+Down** (dual-
    /// encoded: kitty kbd CSI-u + legacy modified-arrow).
    llm_chat_inline_grow,
    llm_chat_inline_shrink,
    /// Toggle auto-exec while a chat surface is open. Off → the
    /// user confirms each LLM-suggested command (default dialog
    /// behaviour). On → atty auto-executes each `exec` action.
    /// No-op outside chat (Alt+Shift+S enters auto mode globally
    /// from non-chat contexts). Default **Alt+T** with kitty kbd
    /// CSI-u sibling.
    llm_chat_toggle_auto,
    /// Render a one-screen cheat-sheet of every keybinding atty
    /// surfaces — pulled from `config.keymap.bindings`. Scrolls into
    /// shell history (like the LLM conclusion banner) so it stays
    /// available in scrollback without commandeering the screen.
    ///
    /// **Not bound by default.** The shipped `Alt+H` binding triggers
    /// the LLM-mode help (`llm_exec_toggle_help`), which falls
    /// through to this renderer at the proxy when NOT in AI mode —
    /// so `Alt+H` does the right thing in both contexts via a single
    /// keybinding. User configs that want a dedicated, unconditional
    /// cheat-sheet key can bind this action directly (e.g. `Alt+?`).
    show_help,
    /// Dump the security_guard warn-event buffer into scrollback
    /// and clear the buffer (clears the `⚠ N` statusbar segment;
    /// new kernel events from the daemon re-arm it). Each event
    /// renders as one line with timestamp / pid / parent / comm /
    /// argv0. No-op when the buffer is empty. Default
    /// **Alt+Shift+W**.
    ///
    /// Render-and-clear is the deliberate semantic — the operator
    /// has the scrollback record; a per-event interactive picker
    /// would require an alt-screen overlay that competes with
    /// vim/htop/etc., and warn events are append-only audit data,
    /// not a workflow that needs in-place mutation.
    security_guard_show_warnings,
};

pub const Binding = struct {
    /// The raw bytes the terminal emits for the key. Matched against
    /// the entire stdin read — terminals send most named keys as a
    /// single read, but the match is byte-exact so chunked reads (rare)
    /// won't trigger.
    bytes: []const u8,
    action: Action,
    /// Human-readable label for the key (e.g. "Alt+C", "Ctrl+Shift+I").
    /// Surfaced by the Alt+H help overlay. Optional — empty means
    /// "don't surface in help" (use for dual-encoding siblings like
    /// the legacy + CSI-u variants of the same chord; only one of the
    /// pair should advertise itself in help).
    label: []const u8 = "",
    /// One-line description of what the action does. Surfaced by the
    /// Alt+H help overlay alongside the key label. Empty (the default)
    /// suppresses the entry — useful for internal / advanced bindings
    /// the user shouldn't see in the cheat-sheet.
    description: []const u8 = "",
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

// ===========================================================================
// Tests — extracted to `keymap_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("keymap_tests.zig");
}

// Pull in the sub-files so `zig build test` discovers their tests
// when only `keymap.zig` is referenced from `unit_tests.zig`.
test {
    _ = parser;
    _ = csiu;
}
