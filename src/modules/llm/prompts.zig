//! atty-owned system prompts — one per dispatch mode. Each prompt
//! is fully self-contained (no shared preamble, no cross-references)
//! so a model focused on one mode never sees rules for the others
//! and the same vocabulary mismatch can't drift across modes.
//!
//! Prompts live as `.md` files under `prompts/` next to this Zig
//! source — `@embedFile` pulls them into the binary at comptime so
//! the protocol stays embedded but editing/diffing the text doesn't
//! drag Zig string-escape ceremony along. Markdown also renders
//! readably when a maintainer wants to review a prompt in isolation.
//!
//! The atty preamble (the relevant prompt below) is ALWAYS prepended
//! to whatever the user puts in `cfg.system_prompt`. User-supplied
//! text appends after a blank line — they can add domain context
//! without losing the action protocol the parser depends on.
//!
//! The protocol itself: free prose plus an optional fenced action
//! block as the LAST element. Fence lang tag selects the action:
//!   ```exec      → run a shell command
//!   ```question  → multi-choice prompt
//!   ```done      → finish with a one-sentence summary (terminal toast)
//! No fence = pure chat — treated as `done` + reason; chat
//! surfaces push that reason as an assistant turn so the
//! conversation stays open (other modes emit the conclusion
//! banner and end the dialog).

const std = @import("std");
const types = @import("types.zig");

/// Alt+A — one-shot. Single command, no dialog, no follow-up.
pub const prompt_single: []const u8 = @embedFile("prompts/single.md");

/// Alt+S — multi-turn dialog. User confirms each exec.
pub const prompt_dialog: []const u8 = @embedFile("prompts/dialog.md");

/// Alt+Shift+S — multi-turn dialog, atty auto-executes each command.
pub const prompt_auto: []const u8 = @embedFile("prompts/auto.md");

/// Provider-specific extension for agentic CLIs (gemini, claude) whose
/// runtime exposes their own shell/filesystem tools. Tells the model
/// those tools don't work under atty and to route everything through
/// the `exec` block. The `geminiCli`/`claudeCode` presets default
/// `prompt_ext` to this; the plain HTTP presets (`openai`, `ollama`)
/// leave it empty — though any provider, HTTP included, can opt in via
/// its own `prompt_ext`.
pub const agentic_cli_ext: []const u8 = @embedFile("prompts/agentic_cli.md");

/// Select the atty-owned prompt for `mode`. Caller appends the
/// user's `cfg.system_prompt` (if any) after a blank line so domain
/// context stacks on top of the action protocol.
pub fn selectPrompt(mode: types.Mode) []const u8 {
    return switch (mode) {
        .single => prompt_single,
        // Chat surfaces (`Alt+C` / `Alt+Shift+C`) dispatch as
        // `.dialog` or `.auto` via `currentDispatchMode`; the bare
        // `.chat` Mode value only routes through `for_modes` masks
        // for provider resolution today. Defaulting to the dialog
        // prompt here is the sensible fall-back if a caller ever
        // surfaces `.chat` for prompt selection.
        .dialog, .chat => prompt_dialog,
        .auto => prompt_auto,
    };
}

test {
    _ = @import("prompts_tests.zig");
}
