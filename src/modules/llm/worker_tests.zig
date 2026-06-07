//! Discovery stub — the worker module's tests live in two sibling
//! files (`worker_subprocess_tests.zig` for the subprocess provider
//! + timeout + JSON-field stripe, and `worker_stream_tests.zig` for
//! stream-json parsing, session id capture, and provider/ModeMask
//! resolution), each under ~700 LOC. Importing both keeps the
//! existing `test { _ = @import("worker_tests.zig"); }` hook inside
//! `worker.zig` valid without a multi-file source change.

test {
    _ = @import("worker_subprocess_tests.zig");
    _ = @import("worker_stream_tests.zig");
}
