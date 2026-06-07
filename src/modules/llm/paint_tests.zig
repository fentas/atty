//! Discovery stub — paint module tests live in three topic-focused
//! siblings (panel toggles + cursor snapshots → `paint_panel_tests.zig`,
//! overlay/inline turn rendering + scroll → `paint_render_tests.zig`,
//! chrome + long-content + observation → `paint_chrome_tests.zig`).
//! Each stays under 1k LOC. The pre-existing `paint_width_tests.zig`
//! sibling continues to host the width-budget tests independently.
//! Importing all three keeps the `test { _ = @import("paint_tests.zig"); }`
//! hook inside `paint.zig` intact.

test {
    _ = @import("paint_panel_tests.zig");
    _ = @import("paint_render_tests.zig");
    _ = @import("paint_chrome_tests.zig");
}
