//! llm_exec_no_osc133 — Alt+S without OSC 133 integration aborts
//! with a "needs OSC 133" hard-error notification. This is the
//! contract that protects dialog mode from getting stuck: without
//! `;C` / `;D`, atty can't tell when each step's command finished
//! and the loop would hang.
//!
//! PS1 here is the plain default — no embedded markers. After
//! `clear`, atty's per-runtime `osc133_capture.active` stays
//! false. Alt+S inspects that flag and latches the error.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.llm.configure(.{
        .api_base = "http://localhost:0",
        .model = "fixture-model",
        // Single fixture entry — Alt+S must NOT consume it, the
        // hard-error path should fire BEFORE any request.
        .fixture_responses = &.{
            \\{"action":"done","reason":"unreachable"}
            ,
        },
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
