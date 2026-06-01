//! llm_dialog_mode_persists — exercise the mode-toggle redesign
//! end-to-end. Uses fixture responses to drive a deterministic
//! two-step dialog: exec a printf-with-OSC-133 then `done`.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.llm.configure(.{
        .provider = .{ .http = .{ .api_base = "http://localhost:0", .model = "fixture-model" } },
        .fixture_responses = &.{
            \\emit ok with markers
            \\```exec
            \\printf '\033]133;C\007ok\033]133;D;0\007'
            \\```
            ,
            \\```done
            \\all set
            \\```
            ,
        },
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
