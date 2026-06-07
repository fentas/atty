//! Discovery stub — `line_state.zig`'s tests live in two sibling
//! files (`line_state_input_tests.zig` for the keystroke/cursor/
//! uncertain/sync stripe and `line_state_commit_tests.zig` for the
//! lastCommitted / author / splice / bulk-append stripe), each
//! under ~700 LOC. Importing both keeps the existing
//! `test { _ = @import("line_state_tests.zig"); }` stub inside
//! `line_state.zig` valid without a multi-file source change.

test {
    _ = @import("line_state_input_tests.zig");
    _ = @import("line_state_commit_tests.zig");
}
