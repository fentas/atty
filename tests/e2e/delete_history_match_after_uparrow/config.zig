//! delete_history_match_after_uparrow — the #1 ergonomic use case
//! for `delete_history_match`: user presses Up arrow to recall a
//! command, sees it on the prompt, presses Ctrl+Shift+D to remove
//! it from history.
//!
//! Why the dedicated scenario: Up arrow is a CSI sequence
//! (`\x1B[A`), and `line_state.applyInput` flips `uncertain = true`
//! on any unmodelled CSI. The handler's `!line_state.uncertain`
//! guard would then skip the delete unless something restored the
//! buffer. `syncFromCapture` does that on every master read while
//! OSC 133 is `.in_input` — but atty's poll loop processes stdin
//! BEFORE master, so a fast Up-arrow → Ctrl+Shift+D sequence
//! arrives at the handler with `uncertain == true` and the master
//! echo of the recalled line not yet drained. The handler now
//! falls back to `osc133_tracker.currentInput()` in that case.
//!
//! Sets up OSC 133 markers in PS1 (mirrors `atty init bash`) so
//! the OSC 133 tracker can actually capture the recalled line.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-delete-uparrow",
        .format = .plain,
        .capacity = 32,
    }),
};
