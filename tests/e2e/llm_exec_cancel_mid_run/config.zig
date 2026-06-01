//! llm_exec_cancel_mid_run — Ctrl+Shift+X cancels the dialog after
//! the suggesting state has landed a command on the prompt. Without
//! this scenario the cancel path could drift — e.g. forget to wipe
//! the suggested command, leave the FIFO turn buffer populated, or
//! fail to reset `dialog_state` so a stray subsequent Enter would
//! resume the dead loop.
//!
//! Fixture returns one `exec` reply; the test cancels before user
//! Enter. We snapshot the post-cancel prompt to assert the line
//! got wiped via the queued Ctrl+U and AI mode is fully off.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.llm.configure(.{
        .provider = .{ .http = .{ .api_base = "http://localhost:0", .model = "fixture-model" } },
        .fixture_responses = &.{
            \\{"action":"exec","command":"echo never","description":"shouldn't run"}
            ,
        },
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
