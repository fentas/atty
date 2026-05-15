//! llm_exec_auto_fires — same fixture/setup as
//! llm_exec_dialog_happy_path, exercises Alt+Shift+S instead of
//! Alt+S. Pins the auto-submit timer: the user never types `\r`;
//! the proxy fires Enter after `cfg.auto_delay_ms`.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.llm.configure(.{
        .api_base = "http://localhost:0",
        .model = "fixture-model",
        .fixture_responses = &.{
            \\{"action":"exec","command":"printf '\\033]133;C\\007ok\\033]133;D;0\\007'","description":"emit ok with markers"}
            ,
            \\{"action":"done","reason":"all set"}
            ,
        },
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
