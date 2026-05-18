//! Tests for `module.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("module.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const LineState = @import("line_state.zig").LineState;
const subprocess_mod = @import("subprocess.zig");

// Re-binds of pub decls so test bodies stay short.
const Action = mod.Action;
const Author = mod.Author;
const Context = mod.Context;
const Error = mod.Error;

// ===========================================================================
// Tests
// ===========================================================================

test "subprocessCwd: null tracker → fallback" {
    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    var ctx = Context{
        .allocator = testing.allocator,
        .io = undefined,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/home/me", ctx.subprocessCwd(&buf, "/home/me"));
}

test "subprocessCwd: empty tracker → fallback" {
    var tr = subprocess_mod.Tracker.init();
    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    var ctx = Context{
        .allocator = testing.allocator,
        .io = undefined,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
        .subprocess = &tr,
    };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/home/me", ctx.subprocessCwd(&buf, "/home/me"));
}

test "subprocessCwd: ssh frame → ssh:// URI" {
    var tr = subprocess_mod.Tracker.init();
    tr.onCommandStart("ssh foo@bar", testing.allocator, null);
    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    var ctx = Context{
        .allocator = testing.allocator,
        .io = undefined,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
        .subprocess = &tr,
    };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("ssh://foo@bar/?", ctx.subprocessCwd(&buf, "/home/me"));
}

test "subprocessCwd: ssh frame with OSC 7 cwd → ssh://host/path (no double slash)" {
    var tr = subprocess_mod.Tracker.init();
    tr.onCommandStart("ssh foo@bar", testing.allocator, null);
    tr.onRemoteCwd("file://bar/srv/app");
    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    var ctx = Context{
        .allocator = testing.allocator,
        .io = undefined,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
        .subprocess = &tr,
    };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("ssh://foo@bar/srv/app", ctx.subprocessCwd(&buf, "/home/me"));
}

test "subprocessCwd: kind=.none frame falls back" {
    var tr = subprocess_mod.Tracker.init();
    tr.onCommandStart("ls -la", testing.allocator, null);
    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    var ctx = Context{
        .allocator = testing.allocator,
        .io = undefined,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
        .subprocess = &tr,
    };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/home/me", ctx.subprocessCwd(&buf, "/home/me"));
}
