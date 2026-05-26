//! Shared test helpers for the llm module's three sibling test
//! files (`llm_tests.zig`, `paint_tests.zig`, `hooks_tests.zig`).
//! Lives here so each test file imports the same definition
//! instead of carrying its own copy.

const std = @import("std");

/// Drain the worker thread + free everything `attach` allocated.
/// Test code must defer this after `var rt = try L.attach(...)`.
/// Walks the Runtime's owned heap (api_base, api_key, shell,
/// context_blob, os_info, captured_output, shared) regardless of
/// whether the worker thread ever ran.
pub fn shutdownAndFree(comptime L: type, rt: *L.Runtime, io: std.Io) void {
    if (rt.thread) |t| {
        {
            rt.shared.mutex.lockUncancelable(io);
            defer rt.shared.mutex.unlock(io);
            rt.shared.shutdown = true;
            rt.shared.cv.signal(io);
        }
        t.join();
    }
    if (rt.shared.res_buf) |slice| rt.allocator.free(slice);
    rt.allocator.destroy(rt.shared);
    rt.allocator.free(rt.api_base);
    rt.allocator.free(rt.api_key);
    rt.allocator.free(rt.shell);
    rt.allocator.free(rt.context_blob);
    rt.allocator.free(rt.os_info);
    rt.allocator.destroy(rt.captured_output);
    // Heap-owned overlay paint buffer — allocated by
    // paintChatOverlay; freed here so tests don't leak when they
    // exercise the open/close cycle without running detach.
    if (rt.chat_overlay_buf) |slice| rt.allocator.free(slice);
    // Same shape for the recall picker overlay's paint buffer +
    // its owned items list.
    if (rt.chat_recall_buf) |slice| rt.allocator.free(slice);
    if (rt.chat_recall_items.len > 0) {
        const chat_persist = @import("chat_persist.zig");
        chat_persist.freeDialogMetaList(rt.allocator, rt.chat_recall_items);
    }
    // Per-session NDJSON path — allocated by attach when
    // chat_persist_enabled is on (default). The path is an
    // `O_EXCL`-reserved file on disk; unlink before freeing so
    // test runs don't pollute the developer/CI XDG state dir.
    // After the file is gone, attempt to rmdir the dialogs dir
    // (best-effort: succeeds when no concurrent test left a
    // reservation behind, fails harmlessly otherwise). Otherwise
    // `zig build test` would leave `~/.local/state/atty/dialogs`
    // on every dev machine that runs the suite.
    if (rt.chat_persist_path.len > 0) {
        const chat_persist = @import("chat_persist.zig");
        const z = rt.allocator.dupeZ(u8, rt.chat_persist_path) catch null;
        if (z) |s| {
            defer rt.allocator.free(s);
            _ = chat_persist.unlinkPath(s.ptr);
        }
        rt.allocator.free(rt.chat_persist_path);
    }
    if (rt.chat_persist_dir.len > 0) {
        const dz = rt.allocator.dupeZ(u8, rt.chat_persist_dir) catch null;
        if (dz) |s| {
            defer rt.allocator.free(s);
            _ = std.c.rmdir(s.ptr);
        }
        rt.allocator.free(rt.chat_persist_dir);
    }
}
