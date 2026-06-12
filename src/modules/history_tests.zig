//! Tests for `modules/history.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("history.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const m = @import("../module.zig");
const Allocator = std.mem.Allocator;
const lib = @import("_lib.zig");
const nowMs = lib.nowMs;
const format = @import("history/format.zig");

// Re-binds of pub decls so test bodies stay short.
const Config = mod.Config;
const configure = mod.configure;
const Format = mod.Format;
const Match = mod.Match;

// ===========================================================================
// Tests
// ===========================================================================

// Pull in the format-helper tests via the sibling file so
// `unit_tests.zig`'s single `_ = @import("modules/history.zig")`
// line discovers them.
test {
    _ = format;
}

test "configure exposes Runtime + hooks" {
    const H = configure(.{});
    try testing.expect(@hasDecl(H, "Runtime"));
    try testing.expect(@hasDecl(H, "onLineCommit"));
    try testing.expect(@hasDecl(H, "provideGhostText"));
    try testing.expectEqualStrings("history", H.name);
}

test "ring evicts oldest at capacity" {
    const H = configure(.{ .capacity = 3 });
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    try H.pushEntry(&rt, "one");
    try H.pushEntry(&rt, "two");
    try H.pushEntry(&rt, "three");
    try H.pushEntry(&rt, "four"); // evicts "one"

    try testing.expectEqual(@as(usize, 3), rt.entries.items.len);
    try testing.expectEqualStrings("two", rt.entries.items[0]);
    try testing.expectEqualStrings("four", rt.entries.items[2]);
}

test "findSuggestion returns the most recent prefix match" {
    const H = configure(.{});
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    try H.pushEntry(&rt, "git status");
    try H.pushEntry(&rt, "git push origin");
    try H.pushEntry(&rt, "ls -la");

    const got = H.findSuggestion(&rt, "git ") orelse return error.TestFailed;
    try testing.expectEqualStrings("git push origin", got);
}

test "onLineCommit pushes into the ring" {
    const H = configure(.{});
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""), // empty path = no file I/O
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    var line: @import("../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    try H.onLineCommit(&rt, &ctx, "ls -la");
    try H.onLineCommit(&rt, &ctx, "git status");
    try testing.expectEqual(@as(usize, 2), rt.entries.items.len);
    try testing.expectEqualStrings("git status", rt.entries.items[1]);
}

test "findSuggestion ignores entries equal to query (no useful trailing)" {
    const H = configure(.{});
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    try H.pushEntry(&rt, "ls");
    try testing.expectEqual(@as(?[]const u8, null), H.findSuggestion(&rt, "ls"));
}

test "deleteHistoryMatch removes every matching ring entry" {
    const H = configure(.{});
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        // Empty path → file write path is a no-op, ring is the
        // only thing we test here.
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    try H.pushEntry(&rt, "ls");
    try H.pushEntry(&rt, "rm -rf /tmp/secret");
    try H.pushEntry(&rt, "echo hi");
    try H.pushEntry(&rt, "rm -rf /tmp/secret"); // duplicate
    try H.pushEntry(&rt, "ls -la");

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var line: @import("../line_state.zig").LineState = .{};
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    try H.deleteHistoryMatch(&rt, &ctx, "rm -rf /tmp/secret");

    // Both duplicates gone, other entries preserved in order.
    try testing.expectEqual(@as(usize, 3), rt.entries.items.len);
    try testing.expectEqualStrings("ls", rt.entries.items[0]);
    try testing.expectEqualStrings("echo hi", rt.entries.items[1]);
    try testing.expectEqualStrings("ls -la", rt.entries.items[2]);
}

test "deleteHistoryMatch is a no-op for an empty query" {
    const H = configure(.{});
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    try H.pushEntry(&rt, "ls");

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var line: @import("../line_state.zig").LineState = .{};
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    try H.deleteHistoryMatch(&rt, &ctx, "");
    try testing.expectEqual(@as(usize, 1), rt.entries.items.len);
}

test "loadRecent populates the ring from an existing file" {
    // Write three lines to a temp path, then ask history.attach to
    // load them. Run inside a fresh /tmp file unique to this test so
    // we don't collide with the user's real history or with the e2e
    // scenarios that use their own fixed paths.
    const path = "/tmp/atty-unit-history-load.txt";

    // Write the file.
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);
    _ = std.c.unlink(path_z.ptr); // ensure clean slate
    const fd = std.c.open(
        path_z.ptr,
        @bitCast(std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }),
        @as(std.c.mode_t, 0o600),
    );
    try testing.expect(fd >= 0);
    const payload = "echo one\necho two\necho three\n";
    _ = std.c.write(fd, payload.ptr, payload.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path_z.ptr);

    const H = configure(.{ .path = path, .format = .plain });
    var rt = try H.attach(testing.allocator, std.Io.failing);
    defer H.detach(&rt, std.Io.failing);

    try testing.expectEqual(@as(usize, 3), rt.entries.items.len);
    try testing.expectEqualStrings("echo one", rt.entries.items[0]);
    try testing.expectEqualStrings("echo three", rt.entries.items[2]);
}

test "provideGhostList returns newest-first prefix matches, skipping the inline ghost and dupes" {
    const H = configure(.{});
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    // Push entries oldest → newest. With duplicates.
    try H.pushEntry(&rt, "git log");
    try H.pushEntry(&rt, "git commit -m foo");
    try H.pushEntry(&rt, "git push origin master");
    try H.pushEntry(&rt, "git commit -m foo"); // dup
    try H.pushEntry(&rt, "git status");

    var line: @import("../line_state.zig").LineState = .{};
    _ = line.applyInput("git ");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    const got = (try H.provideGhostList(&rt, &ctx)).?;

    // Inline ghost would have been "git status" (newest match).
    // The list starts after, newest-first, deduped:
    //   - "git commit -m foo" appears TWICE in the ring; the newer
    //     instance is the 4th push (after "git push origin master"),
    //     so the newest-first walk hits it before "git push" and
    //     dedupe drops the older copy at position 1.
    //   - "git push origin master" is older than the dup, so it
    //     ranks below "git commit -m foo".
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("git commit -m foo", got[0]);
    try testing.expectEqualStrings("git push origin master", got[1]);
    try testing.expectEqualStrings("git log", got[2]);
}

test "provideGhostList returns null on empty query / uncertain line" {
    const H = configure(.{});
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);
    try H.pushEntry(&rt, "anything");

    var line: @import("../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    // Empty line: null.
    try testing.expectEqual(@as(?[]const []const u8, null), try H.provideGhostList(&rt, &ctx));

    // Mark uncertain (simulate arrow key): still null even with a typed prefix.
    _ = line.applyInput("a");
    _ = line.applyInput("\x1b[A"); // up arrow → uncertain
    try testing.expect(line.uncertain);
    try testing.expectEqual(@as(?[]const []const u8, null), try H.provideGhostList(&rt, &ctx));
}

test "provideGhostList caps at 9 entries (matches Ctrl+1..Ctrl+9 / Esc+1..9 default bindings)" {
    const H = configure(.{ .capacity = 32 });
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var buf: [32]u8 = undefined;
        const entry = try std.fmt.bufPrint(&buf, "x cmd-{d}", .{i});
        try H.pushEntry(&rt, entry);
    }

    var line: @import("../line_state.zig").LineState = .{};
    _ = line.applyInput("x ");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    const got = (try H.provideGhostList(&rt, &ctx)).?;
    try testing.expectEqual(@as(usize, 9), got.len);
}

test "deleteHistoryMatch rewrites the on-disk file atomically" {
    // The in-memory ring filter is the visible behaviour, but the
    // atomic rewrite (write-temp + rename) is the durability story.
    // If the file isn't rewritten the deleted entry comes back on
    // the next atty session — that's the user-facing regression.
    const path = "/tmp/atty-unit-history-delete-roundtrip.txt";
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);
    _ = std.c.unlink(path_z.ptr);
    const fd = std.c.open(
        path_z.ptr,
        @bitCast(std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }),
        @as(std.c.mode_t, 0o600),
    );
    try testing.expect(fd >= 0);
    const payload = "keep one\nDELETE-ME\nkeep two\nDELETE-ME\n";
    _ = std.c.write(fd, payload.ptr, payload.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path_z.ptr);

    const H = configure(.{ .path = path, .format = .plain });
    var rt = try H.attach(testing.allocator, std.Io.failing);
    defer H.detach(&rt, std.Io.failing);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var line: @import("../line_state.zig").LineState = .{};
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    try H.deleteHistoryMatch(&rt, &ctx, "DELETE-ME");

    // Ring: 4 → 2.
    try testing.expectEqual(@as(usize, 2), rt.entries.items.len);

    // File: re-read and confirm the on-disk content matches.
    const rd_fd = std.c.open(path_z.ptr, @bitCast(std.c.O{ .ACCMODE = .RDONLY }), @as(std.c.mode_t, 0));
    try testing.expect(rd_fd >= 0);
    defer _ = std.c.close(rd_fd);
    var buf: [256]u8 = undefined;
    const n = std.c.read(rd_fd, &buf, buf.len);
    try testing.expect(n > 0);
    const disk = buf[0..@as(usize, @intCast(n))];
    try testing.expect(std.mem.indexOf(u8, disk, "DELETE-ME") == null);
    try testing.expect(std.mem.indexOf(u8, disk, "keep one") != null);
    try testing.expect(std.mem.indexOf(u8, disk, "keep two") != null);
}

test "loadRecent seeds from the tail on a file larger than the 1 MiB cap" {
    const path = "/tmp/atty-unit-history-tail.txt";
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);
    _ = std.c.unlink(path_z.ptr);
    const fd = std.c.open(
        path_z.ptr,
        @bitCast(std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }),
        @as(std.c.mode_t, 0o600),
    );
    try testing.expect(fd >= 0);
    defer _ = std.c.unlink(path_z.ptr);

    // ~120k lines × ~14 bytes ≈ 1.7 MiB — comfortably over the 1 MiB
    // cap so the head is dropped and only the tail is read.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var n: usize = 0;
    while (n < 120_000) : (n += 1) {
        var lb: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&lb, "cmd{d:0>9}\n", .{n}) catch unreachable;
        try buf.appendSlice(testing.allocator, s);
    }
    _ = std.c.write(fd, buf.items.ptr, buf.items.len);
    _ = std.c.close(fd);

    const H = configure(.{ .path = path, .format = .plain });
    var rt = try H.attach(testing.allocator, std.Io.failing);
    defer H.detach(&rt, std.Io.failing);

    // Ring filled to capacity with the NEWEST lines: last line present,
    // first line (oldest) absent — the regression was the reverse.
    try testing.expect(rt.entries.items.len == 5_000);
    try testing.expectEqualStrings("cmd000119999", rt.entries.items[rt.entries.items.len - 1]);
    for (rt.entries.items) |e| try testing.expect(!std.mem.eql(u8, e, "cmd000000000"));
}

test "deleteHistoryMatch preserves original zsh timestamps of kept lines" {
    const path = "/tmp/atty-unit-history-ts.txt";
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);
    _ = std.c.unlink(path_z.ptr);
    const fd = std.c.open(
        path_z.ptr,
        @bitCast(std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }),
        @as(std.c.mode_t, 0o600),
    );
    try testing.expect(fd >= 0);
    const payload = ": 1700000000:0;keep one\n: 1700000001:0;DELETE-ME\n: 1700000002:0;keep two\n";
    _ = std.c.write(fd, payload.ptr, payload.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path_z.ptr);

    const H = configure(.{ .path = path, .format = .zsh_extended });
    var rt = try H.attach(testing.allocator, std.Io.failing);
    defer H.detach(&rt, std.Io.failing);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var line: @import("../line_state.zig").LineState = .{};
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };
    try H.deleteHistoryMatch(&rt, &ctx, "DELETE-ME");

    const rd_fd = std.c.open(path_z.ptr, @bitCast(std.c.O{ .ACCMODE = .RDONLY }), @as(std.c.mode_t, 0));
    try testing.expect(rd_fd >= 0);
    defer _ = std.c.close(rd_fd);
    var rbuf: [256]u8 = undefined;
    const rn = std.c.read(rd_fd, &rbuf, rbuf.len);
    try testing.expect(rn > 0);
    const disk = rbuf[0..@as(usize, @intCast(rn))];
    // Verbatim copy: original timestamps survive, deleted line gone.
    try testing.expect(std.mem.indexOf(u8, disk, ": 1700000000:0;keep one") != null);
    try testing.expect(std.mem.indexOf(u8, disk, ": 1700000002:0;keep two") != null);
    try testing.expect(std.mem.indexOf(u8, disk, "DELETE-ME") == null);
}

test "deleteHistoryMatch removes an on-disk entry that aged out of the ring" {
    const path = "/tmp/atty-unit-history-beyond-ring.txt";
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);
    _ = std.c.unlink(path_z.ptr);
    const fd = std.c.open(
        path_z.ptr,
        @bitCast(std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }),
        @as(std.c.mode_t, 0o600),
    );
    try testing.expect(fd >= 0);
    const payload = "old-secret\nb\nc\nd\n";
    _ = std.c.write(fd, payload.ptr, payload.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path_z.ptr);

    // capacity 2 → ring holds only the 2 newest (c, d); "old-secret"
    // aged out of the ring but is still on disk.
    const H = configure(.{ .path = path, .format = .plain, .capacity = 2 });
    var rt = try H.attach(testing.allocator, std.Io.failing);
    defer H.detach(&rt, std.Io.failing);
    try testing.expect(rt.entries.items.len == 2);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var line: @import("../line_state.zig").LineState = .{};
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };
    try H.deleteHistoryMatch(&rt, &ctx, "old-secret");

    const rd_fd = std.c.open(path_z.ptr, @bitCast(std.c.O{ .ACCMODE = .RDONLY }), @as(std.c.mode_t, 0));
    try testing.expect(rd_fd >= 0);
    defer _ = std.c.close(rd_fd);
    var rbuf: [256]u8 = undefined;
    const rn = std.c.read(rd_fd, &rbuf, rbuf.len);
    try testing.expect(rn > 0);
    const disk = rbuf[0..@as(usize, @intCast(rn))];
    try testing.expect(std.mem.indexOf(u8, disk, "old-secret") == null);
    try testing.expect(std.mem.indexOf(u8, disk, "b\n") != null);
    try testing.expect(std.mem.indexOf(u8, disk, "d\n") != null);
}

test "loadRecent strips zsh extended-history prefixes on load" {
    const path = "/tmp/atty-unit-history-zsh.txt";
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);
    _ = std.c.unlink(path_z.ptr);
    const fd = std.c.open(
        path_z.ptr,
        @bitCast(std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }),
        @as(std.c.mode_t, 0o600),
    );
    try testing.expect(fd >= 0);
    const payload = ": 1700000000:0;echo zsh-style\n: 1700000001:0;ls\n";
    _ = std.c.write(fd, payload.ptr, payload.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path_z.ptr);

    const H = configure(.{ .path = path, .format = .zsh_extended });
    var rt = try H.attach(testing.allocator, std.Io.failing);
    defer H.detach(&rt, std.Io.failing);

    try testing.expectEqual(@as(usize, 2), rt.entries.items.len);
    try testing.expectEqualStrings("echo zsh-style", rt.entries.items[0]);
    try testing.expectEqualStrings("ls", rt.entries.items[1]);
}
