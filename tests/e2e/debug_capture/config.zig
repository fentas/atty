//! debug_capture — atty built with the in-memory debug recorder enabled, so the
//! Alt+Shift+D capture writes a report + surfaces the outcome. report_dir is a
//! temp path so the test doesn't depend on HOME/XDG. The status bar is on so the
//! scenario exercises the realistic path: the outcome shows in the hint row
//! (above the footer), not inline in scrollback.
const atty = @import("atty");

pub const debug: atty.Debug = .{
    .enabled = true,
    .report_dir = "/tmp/atty-e2e-debug",
};

// Short hint TTL so the scenario can watch the row clear between the two
// captures — that's how it proves the SECOND (kitty CSI-u) binding fired
// rather than just re-reading the first capture's message.
pub const statusbar: atty.StatusBar = .{ .enabled = true, .hint_ttl_ms = 1500 };
