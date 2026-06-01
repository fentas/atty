//! llm_ai_mode_hint — verify the statusbar swaps to the AI mode hint
//! when the user types the `#: ` prefix.
//!
//! Lands the foundation of `feat/llm-exec-mode`: typing the prefix
//! flips `Runtime.ai_mode_active` true, and the statusText hook
//! returns the verbose action-key hint instead of the default
//! `atty` base text. Backspacing the prefix flips it back.
//!
//! The LLM module is inert here (no `api_base` set), but AI mode
//! tracking + statusText work regardless — the action keys are
//! observation-only when the worker is dormant.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.llm.configure(.{
        // No `.provider` override → defaults to `.http = .{}`
        // with an empty api_base = inert mode. We don't want the
        // e2e scenario to make real HTTP calls.
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
