//! statusbar_visible — atty built with the status bar enabled so we
//! can verify the prompt lands at row 1 and the bar at the bottom.
//!
//! This config exists solely for the matching e2e scenario; the
//! e2e runner picks it up via tests/e2e/<name>/config.zig and
//! rebuilds atty against it into a scenario-private prefix.

const atty = @import("atty");

// Default modules — dependency-free. We're only testing the proxy's
// statusbar plumbing here, not any specific module.
pub const modules = .{
    atty.modules.guardrail.configure(.{}),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
