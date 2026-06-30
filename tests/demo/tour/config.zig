//! atty_demo:tour — the complete experience for the showcase GIF: status bar +
//! history ghost-text + inline #: AI command generation, all with the footer
//! visible. NOT a regression test; the e2e runner builds atty against this and
//! records the cast that scripts/gen-demo-gifs.sh turns into a GIF.
//!
//! The LLM provider is a deterministic FIXTURE (no network/Ollama): the worker
//! replays `fixture_responses` in order, so the AI turn is reproducible. The
//! `#:` exec mode needs OSC 133, which the scenario installs by sourcing atty's
//! real shell-integration snippet — so the suggested command is clean (a plain
//! `echo`), not the marker-emitting printf the e2e fixtures use.
const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{ .path = "/tmp/atty-demo-tour" }),
    atty.modules.llm.configure(.{
        .provider = .{ .http = .{ .api_base = "http://localhost:0", .model = "fixture-model" } },
        .fixture_responses = &.{
            \\I'll print a greeting for you.
            \\```exec
            \\echo "Hello from atty's AI assistant"
            \\```
            ,
            \\```done
            \\greeting printed
            \\```
            ,
        },
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
