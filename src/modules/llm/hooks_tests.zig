//! Discovery stub — hooks-side tests live in four siblings, each
//! roughly 970-1060 LOC (a marginal overrun in basics/action/retry
//! is acceptable to keep cluster topics intact rather than splitting
//! sanitize/clear/action/retry stripes).
//!
//!   - `hooks_basics_tests.zig` — sanitizeForStatus + clear-sequence
//!     detectors + chat overlay/inline toggle gates + key-swallow
//!     into chat buffers + cursor + kill commands.
//!
//!   - `hooks_action_tests.zig` — Alt+Enter / paste / Alt+M cycle /
//!     persistent dialog mode toggles / scroll page / refocus
//!     latch / chat exec continuation / exec-no-return regressions.
//!
//!   - `hooks_retry_tests.zig` — clamp/recovery on terminal-size
//!     overflows, retry banner UX, dialogResetSoft preservation.
//!
//!   - `hooks_recall_tests.zig` — chat recall picker overlay,
//!     persistence flows, OSC 133 cursor invalidation.
//!
//! Importing all four keeps the `test { _ = @import("hooks_tests.zig"); }`
//! hook inside `hooks.zig` intact without source-side changes.

test {
    _ = @import("hooks_basics_tests.zig");
    _ = @import("hooks_action_tests.zig");
    _ = @import("hooks_retry_tests.zig");
    _ = @import("hooks_recall_tests.zig");
}
