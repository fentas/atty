//! atty_demo:llm — focused inline #: AI command generation for the LLM docs
//! page. NOT a regression test. Deterministic fixture provider (no network);
//! the scenario sources atty's real OSC 133 integration so the suggested
//! command is clean (`uname -sm`), not the marker-emitting printf the e2e
//! fixtures use.
const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.llm.configure(.{
        .provider = .{ .http = .{ .api_base = "http://localhost:0", .model = "fixture-model" } },
        .fixture_responses = &.{
            \\I'll print the kernel name and architecture.
            \\```exec
            \\uname -sm
            \\```
            ,
            \\```done
            \\printed the kernel info
            \\```
            ,
        },
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
