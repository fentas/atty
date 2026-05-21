//! Comptime-baked strings shared by `llm.zig` and `llm/hooks.zig`.
//! Pulled into their own file so the two callers can both import
//! them without a circular dependency between the implementation
//! file and its hooks sibling.

const types = @import("types.zig");
const prompts = @import("prompts.zig");

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

        /// Dialog-mode system prompt. atty's fenced-action protocol
        /// (`prompts.prompt_dialog`) is ALWAYS prepended so the
        /// parser contract holds. User's `cfg.dialog_system_prompt`,
        /// when set, appends after a blank line as additional domain
        /// context — never replaces the action protocol.
        pub const effective_dialog_system_prompt: []const u8 = if (cfg.dialog_system_prompt.len > 0)
            prompts.prompt_dialog ++ "\n\n" ++ cfg.dialog_system_prompt
        else
            prompts.prompt_dialog;
    };
}
