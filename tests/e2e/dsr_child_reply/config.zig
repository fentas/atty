//! dsr_child_reply — statusbar on so atty actively tracks the cursor with its
//! own DSR-6n queries; that's the state in which it used to swallow a
//! foreground child's cursor reply (the atuin Ctrl+R hang).
const atty = @import("atty");

pub const statusbar: atty.StatusBar = .{ .enabled = true };
