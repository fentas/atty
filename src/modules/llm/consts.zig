//! Comptime-baked strings shared by `llm.zig` and `llm/hooks.zig`.
//! Pulled into their own file so the two callers can both import
//! them without a circular dependency between the implementation
//! file and its hooks sibling.

const types = @import("types.zig");

pub fn Module(comptime cfg: types.Config) type {
    return struct {
        /// Comptime-built notification for inert mode. For HTTP
        /// transport mentions the configured env-var names so users
        /// who renamed them see THEIR names rather than the upstream
        /// defaults. For subprocess transport this is unused — the
        /// subprocess path is never inert at attach time (CLI
        /// availability surfaces as a per-request error instead).
        pub const inert_error_msg: []const u8 = switch (cfg.provider) {
            .http => |http| "no endpoint set — export $" ++
                http.api_base_env ++ " / $" ++ http.api_base_fallback_env ++
                ", or set Config.provider.http.api_base in config.zig",
            .subprocess => "subprocess provider in use — this shouldn't render",
        };

        /// Dialog-mode system prompt. Locks the model into a strict
        /// JSON-envelope response so we can parse `action` /
        /// `command` / `description` / `reason` reliably. The
        /// instruction set is deliberately terse — every line spent
        /// on prose costs tokens that should go to the user's
        /// task.
        pub const effective_dialog_system_prompt: []const u8 = if (cfg.dialog_system_prompt.len > 0)
            cfg.dialog_system_prompt
        else
            \\You are an interactive shell assistant running inside atty, a PTY proxy that wraps the user's shell. You receive a task and step-by-step OBSERVATIONS from previously executed commands. Reply ONLY with a JSON object on a single line. Allowed shapes:
            \\{"action":"exec","command":"<single-line shell command>","description":"<one short sentence>"}
            \\{"action":"done","reason":"<one short sentence>"}
            \\{"action":"question","question":"<short question>","choices":["<opt1>","<opt2>"]}
            \\Optional advisory flag for any of the above shapes: add `"open_chat": true` when the user would benefit from following up in atty's chat surface — e.g. you finished but the reason is a long explanation the user might want to react to, or the question expects a free-form clarification rather than a one-token answer. Use sparingly; the flag is a request, not a guarantee (user policy may auto-open, notify, or ignore it).
            \\The user can be talking to you from one of two chat surfaces (Alt+C inline panel above the statusbar, or Alt+Shift+C full overlay) — both route through the same dialog state and the same `action=exec` injection path, so a command you return WILL land at the user's shell prompt regardless of which surface they used. Treat chat input as conversational follow-up to the running dialog.
            \\Never wrap the JSON in markdown fences. Never add prose around it. The command must be a single line, runnable as-is in the user's shell.
        ;
    };
}
