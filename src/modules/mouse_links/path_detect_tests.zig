const std = @import("std");
const testing = std.testing;
const mod = @import("path_detect.zig");

const find = mod.find;
const Options = mod.Options;
const Hit = mod.Hit;

const default_opts: Options = .{};

fn expectHit(line: []const u8, click_col: u16, want_path: []const u8, want_line: ?u32, want_col: ?u32) !void {
    const hit = find(line, click_col, default_opts) orelse {
        std.debug.print("no hit for col={d} in {s}\n", .{ click_col, line });
        return error.TestExpectedHit;
    };
    try testing.expectEqualStrings(want_path, hit.path);
    try testing.expectEqual(want_line, hit.line);
    try testing.expectEqual(want_col, hit.col);
}

fn expectMiss(line: []const u8, click_col: u16) !void {
    if (find(line, click_col, default_opts) != null) {
        std.debug.print("expected miss but got hit at col={d} in {s}\n", .{ click_col, line });
        return error.TestExpectedMiss;
    }
}

test "absolute path no suffix" {
    try expectHit("/usr/share/zoneinfo", 5, "/usr/share/zoneinfo", null, null);
}

test "absolute path with line and col" {
    try expectHit("/abs/foo.zig:42:7", 6, "/abs/foo.zig", 42, 7);
}

test "compiler trailing colon stripped" {
    try expectHit("/abs/foo.zig:42:7: error: x", 8, "/abs/foo.zig", 42, 7);
}

test "relative path accepted" {
    try expectHit("src/proxy.zig:101 error here", 5, "src/proxy.zig", 101, null);
}

test "relative path rejected when option off" {
    const hit = find("src/proxy.zig:42", 5, .{ .accept_relative = false });
    try testing.expect(hit == null);
}

test "dot relative" {
    try expectHit("./build.zig", 2, "./build.zig", null, null);
}

test "double-dot relative" {
    try expectHit("../atty/src/main.zig:13", 6, "../atty/src/main.zig", 13, null);
}

test "tilde home" {
    try expectHit("~/dotfiles/init.lua:9:1", 3, "~/dotfiles/init.lua", 9, 1);
}

test "double quoted path with space" {
    try expectHit("\"src/with space/x.md\":5", 6, "src/with space/x.md", 5, null);
}

test "single quoted" {
    try expectHit("'src/foo.zig'", 4, "src/foo.zig", null, null);
}

test "parens wrapper" {
    try expectHit("(src/foo.zig:42)", 4, "src/foo.zig", 42, null);
}

test "angle bracket wrapper" {
    try expectHit("<src/foo.zig>", 4, "src/foo.zig", null, null);
}

test "trailing comma" {
    try expectHit("see src/foo.zig, line 42", 5, "src/foo.zig", null, null);
}

test "trailing period in prose" {
    try expectHit("touched build.zig.", 9, "build.zig", null, null);
}

test "url rejected — http" {
    try expectMiss("https://example.com/foo", 5);
}

test "url rejected — file scheme" {
    try expectMiss("file:///etc/hosts", 5);
}

test "email rejected" {
    try expectMiss("a.user@example.com", 5);
}

test "all digits rejected" {
    try expectMiss("12345", 2);
}

test "bare word with no slash or extension rejected" {
    try expectMiss("foo", 1);
}

test "known bare filename — Makefile" {
    try expectHit("see Makefile for details", 6, "Makefile", null, null);
}

test "known bare filename — Dockerfile" {
    try expectHit("Dockerfile", 1, "Dockerfile", null, null);
}

test "known extension without slash" {
    try expectHit("README.md", 3, "README.md", null, null);
}

test "click on column past line length" {
    try expectMiss("src/foo.zig", 100);
}

test "click on whitespace next to token" {
    try expectHit("see src/foo.zig", 4, "src/foo.zig", null, null);
}

test "click on whitespace surrounded by spaces" {
    try expectMiss("   ", 2);
}

test "empty line" {
    try expectMiss("", 1);
}

test "col 0 rejected" {
    try expectMiss("src/foo.zig", 0);
}

test "very large line number parses" {
    try expectHit("src/foo.zig:9999999", 5, "src/foo.zig", 9999999, null);
}

test "overflow line number folds to no suffix" {
    // 11+ digits aren't accepted as a line number — the whole `:N`
    // is treated as part of the path candidate.
    const hit = find("src/foo.zig:12345678901", 5, default_opts) orelse return error.TestExpectedHit;
    try testing.expectEqualStrings("src/foo.zig:12345678901", hit.path);
    try testing.expectEqual(@as(?u32, null), hit.line);
}

test "trailing semicolon stripped" {
    try expectHit("see src/foo.zig:7;", 5, "src/foo.zig", 7, null);
}

test "click on line number digits returns hit with suffix" {
    try expectHit("src/foo.zig:42:7", 14, "src/foo.zig", 42, 7);
}

test "no path-shape — bare colon n" {
    try expectMiss(":42", 1);
}

test "path with dot in directory" {
    try expectHit("/var/log/syslog.1", 5, "/var/log/syslog.1", null, null);
}

test "build.zig recognised" {
    try expectHit("build.zig", 3, "build.zig", null, null);
}

test "deep relative with line" {
    try expectHit("a/b/c/d/e.toml:99", 6, "a/b/c/d/e.toml", 99, null);
}

test "ignore wrapper without matching close" {
    // Unmatched leading `"` is left as part of the run; isPathShape
    // still passes via has_slash, but the quote stays in the path.
    // Acceptable behaviour — caller should sanitise quotes if they
    // matter for $EDITOR argv.
    try expectHit("\"src/foo.zig", 5, "\"src/foo.zig", null, null);
}

test "tab as separator" {
    try expectHit("src/a.zig\tsrc/b.zig", 12, "src/b.zig", null, null);
}
