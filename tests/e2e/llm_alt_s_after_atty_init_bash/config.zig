//! llm_alt_s_after_atty_init_bash — exercise the real
//! `atty init bash` shell-integration path end-to-end. Bare bash
//! is started with `--norc --noprofile`, then the scenario itself
//! runs `eval "$(atty init bash)"` to set up the OSC 133 hooks
//! exactly as a real user would. After that, Alt+S (via the
//! kitty kbd CSI-u encoding) must fire the dialog without
//! tripping the "needs OSC 133" gate.
//!
//! Fixture replies drive the dialog without any real HTTP — same
//! pattern as `llm_exec_dialog_happy_path`, just with the PS1
//! provisioning routed through `atty init bash` instead of
//! manually inlined.

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
