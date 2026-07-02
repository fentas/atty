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

const debug_recorder = @import("../debug_recorder.zig");

extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn dup(fd: c_int) c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;

const TeeSink = struct {
    data: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    fn cb(self: *TeeSink, ts: i64, s: debug_recorder.Stream, d: []const u8) void {
        _ = ts;
        if (s != .term) return;
        self.data.appendSlice(self.alloc, d) catch {};
    }
};

test "writeFully tees STDOUT into the recorder byte-exactly, and no other fd" {
    var r = try debug_recorder.Recorder.init(testing.allocator, 4096);
    defer r.deinit();
    mod.recorder = &r;
    defer mod.recorder = null;

    // A non-STDOUT fd (pipe) must NOT be teed as `term`.
    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try mod.writeFully(fds[1], "pipe-bytes");

    // STDOUT IS teed. Redirect fd 1 to /dev/null so the test stays quiet.
    const O_WRONLY: c_int = @bitCast(posix.O{ .ACCMODE = .WRONLY });
    const devnull = open("/dev/null", O_WRONLY);
    if (devnull < 0) return error.OpenFailed;
    const saved = dup(posix.STDOUT_FILENO);
    defer {
        _ = dup2(saved, posix.STDOUT_FILENO);
        _ = std.c.close(saved);
        _ = std.c.close(devnull);
    }
    _ = dup2(devnull, posix.STDOUT_FILENO);
    try mod.writeFully(posix.STDOUT_FILENO, "term-bytes");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var sink = TeeSink{ .data = &buf, .alloc = testing.allocator };
    r.forEach(&sink, TeeSink.cb);
    // Only the STDOUT write is present — the pipe write was not teed.
    try testing.expectEqualStrings("term-bytes", buf.items);
}
