//! dsr_child_reply — statusbar on so atty actively tracks the cursor with its
//! own DSR-6n queries; that is the state in which a child's cursor reply could
//! plausibly be consumed by atty's interceptor, so it is the interesting one to
//! pin the contract under.
const atty = @import("atty");

pub const statusbar: atty.StatusBar = .{ .enabled = true };
