//! debug_capture — atty built with the in-memory debug recorder enabled, so the
//! Alt+Shift+D capture writes a report + prints the toast. report_dir is a temp
//! path so the test doesn't depend on HOME/XDG.
const atty = @import("atty");

pub const debug: atty.Debug = .{
    .enabled = true,
    .report_dir = "/tmp/atty-e2e-debug",
};
