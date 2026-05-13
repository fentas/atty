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
    _ = @import("ghost_list.zig");
    _ = @import("osc133.zig");
    _ = @import("pty.zig");
    _ = @import("terminal.zig");
    _ = @import("keymap.zig");
    _ = @import("style.zig");
    _ = @import("statusbar.zig");
    _ = @import("status_text.zig");
    _ = @import("args.zig");
    _ = @import("modules/_lib.zig");
    _ = @import("modules/atuin.zig");
    _ = @import("modules/llm.zig");
    _ = @import("modules/guardrail.zig");
    _ = @import("modules/history.zig");
    _ = @import("test/e2e/vt.zig");
    _ = @import("test/e2e/dsl.zig");
    _ = @import("test/e2e/snapshot.zig");
}
