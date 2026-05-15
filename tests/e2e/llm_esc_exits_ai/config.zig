//! llm_esc_exits_ai — bare Esc cancels an in-progress AI dialog.
//! Same fixture as llm_exec_cancel_mid_run but the test fires Esc
//! instead of Ctrl+Shift+X. Both keys converge in `onAction` →
//! `llm_exec_cancel`, so the scenario pins the new Esc binding
//! actually reaches the cancel flow.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.llm.configure(.{
        .api_base = "http://localhost:0",
        .model = "fixture-model",
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
