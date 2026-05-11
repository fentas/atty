//! Unit test entry — distinct from src/root.zig so the test executable
//! doesn't collide with the `atty` module's compilation.
//!
//! We deliberately *do not* pull in proxy.zig here: proxy depends on
//! the user's config.zig, which is wired only into the binary build.
//! End-to-end proxy behaviour is covered by the integration test.

test {
    _ = @import("module.zig");
    _ = @import("dispatch.zig");
    _ = @import("line_state.zig");
    _ = @import("ansi.zig");
    _ = @import("ghost.zig");
    _ = @import("pty.zig");
    _ = @import("terminal.zig");
    _ = @import("modules/atuin.zig");
    _ = @import("modules/guardrail.zig");
}
