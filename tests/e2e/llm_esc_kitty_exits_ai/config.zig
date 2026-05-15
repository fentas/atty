//! llm_esc_kitty_exits_ai — same fixture as llm_esc_exits_ai;
//! sibling test pins the CSI-u Esc form (kitty-kbd default).

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
