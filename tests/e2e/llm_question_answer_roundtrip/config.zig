//! llm_question_answer_roundtrip — fixture answers Alt+S with a
//! `.question` action, then `.done` after receiving the user's
//! typed answer. Pins the awaiting-question state machine + the
//! `.replace_commit` Ctrl+U redirect on Enter.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.llm.configure(.{
        .provider = .{ .http = .{ .api_base = "http://localhost:0", .model = "fixture-model" } },
        .fixture_responses = &.{
            \\```question
            \\which folder?
            \\```
            ,
            \\```done
            \\got it
            \\```
            ,
        },
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
