//! atty_demo:tour — the FULL feature set in one take for the README hero:
//! status-bar footer, click-to-open paths (mouse_links), history ghost-text +
//! pick-list, the guardrail + security_guard safety gates, and inline #: AI.
//! Deterministic: llm uses a fixture provider; security_guard runs in-proc
//! Tier-1 (no daemon); mouse_links uses EDITOR=echo.
const atty = @import("atty");

pub const modules = .{
    atty.modules.mouse_links.configure(.{ .editor = "echo" }),
    // Before guardrail: both match `curl|sh`, first-match wins — security_guard
    // should own that one. daemon empty → in-proc Tier-1.
    atty.modules.security_guard.configure(.{ .enabled = true, .daemon_socket_path = "" }),
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{ .path = "/tmp/atty-demo-tour" }),
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

pub const mouse: atty.Mouse = .{ .enabled = true };
pub const ghost: atty.Ghost = .{ .list_count = 3 };
pub const statusbar: atty.StatusBar = .{ .enabled = true, .base_text = "atty" };
