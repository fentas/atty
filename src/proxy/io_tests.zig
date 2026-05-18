//! Tests for `proxy/io.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("io.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const posix = std.posix;

// Re-binds of pub decls so test bodies stay short.
const containsEnter = mod.containsEnter;
const PtmWriter = mod.PtmWriter;
const writeAll = mod.writeAll;
const writeFully = mod.writeFully;

// ===========================================================================
// Tests
// ===========================================================================

test "containsEnter: CR detected" {
    try testing.expect(containsEnter("abc\r"));
    try testing.expect(containsEnter("\rabc"));
}

test "containsEnter: LF detected" {
    try testing.expect(containsEnter("abc\n"));
}

test "containsEnter: plain bytes return false" {
    try testing.expect(!containsEnter("abcdef"));
    try testing.expect(!containsEnter(""));
}

test "containsEnter: CSI byte alone is not Enter" {
    // 0x1B is ESC, the lead byte for CSI — must not falsely
    // register as Enter.
    try testing.expect(!containsEnter("\x1B[A"));
}

test "writeFully: empty input is a no-op (no syscall, no error)" {
    // Guards the fast path: writing zero bytes shouldn't enter the
    // retry loop at all, otherwise an empty paint cycle would still
    // pay a syscall per iteration.
    try writeFully(-1, "");
}

test "writeFully: write to a pipe whose reader closed returns error.WriteFailed (no spin)" {
    // EPIPE must surface as error.WriteFailed so callers can shut
    // down rather than retrying. The errno gate is the only thing
    // between a broken pipe and an unbounded write-syscall loop.

    // SIG_IGN locally so the kernel's default SIGPIPE disposition
    // (terminate) doesn't kill the test runner — the production
    // disposition is set in proxy.installSignalHandlers, but unit
    // tests run outside that path. The defer restore guarantees
    // every other test in this binary observes default SIGPIPE
    // before and after this one runs.
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var prev: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.PIPE, &sa, &prev);
    defer std.posix.sigaction(std.posix.SIG.PIPE, &prev, null);

    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.pipe2(&fds, .{});
    try testing.expectEqual(@as(c_int, 0), rc);
    _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    try testing.expectError(error.WriteFailed, writeFully(fds[1], "x"));
}
