//! llm_dialog_mode_persists — exercise the mode-toggle redesign
//! end-to-end. Uses fixture responses to drive a deterministic
//! two-step dialog: exec a printf-with-OSC-133 then `done`.

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
