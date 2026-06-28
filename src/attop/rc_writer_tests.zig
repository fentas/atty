const std = @import("std");
const testing = std.testing;
const rc_writer = @import("rc_writer.zig");

const begin = rc_writer.begin;
const end = rc_writer.end;

test "buildBlock embeds the init path between the markers" {
    const b = try rc_writer.buildBlock(testing.allocator, "/home/u/.config/atty/init.bash", "bash");
    defer testing.allocator.free(b);
    try testing.expect(std.mem.indexOf(u8, b, begin) != null);
    try testing.expect(std.mem.indexOf(u8, b, end) != null);
    try testing.expect(std.mem.indexOf(u8, b, "export ATTY_SOURCE=\"/home/u/.config/atty/init.bash\"") != null);
    try testing.expect(std.mem.indexOf(u8, b, "[ -r \"$ATTY_SOURCE\" ] && . \"$ATTY_SOURCE\"") != null);
}

test "upsertBlock appends to an existing rc, preserving it" {
    const rc = "export PS1='$ '\nalias ll='ls -l'\n";
    const out = try rc_writer.upsertBlock(testing.allocator, rc, "/p/init.bash", "bash");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, rc)); // original kept verbatim
    try testing.expect(std.mem.indexOf(u8, out, begin) != null);
    try testing.expect(std.mem.indexOf(u8, out, "/p/init.bash") != null);
}

test "upsertBlock adds a separating newline when rc lacks a trailing one" {
    const rc = "export PS1='$ '"; // no trailing newline
    const out = try rc_writer.upsertBlock(testing.allocator, rc, "/p/init.bash", "bash");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "$ '\n# >>> atty >>>") != null); // newline inserted
}

test "upsertBlock is idempotent (apply twice == apply once)" {
    const rc = "line1\nline2\n";
    const once = try rc_writer.upsertBlock(testing.allocator, rc, "/p/init.zsh", "bash");
    defer testing.allocator.free(once);
    const twice = try rc_writer.upsertBlock(testing.allocator, once, "/p/init.zsh", "bash");
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings(once, twice);
    // exactly one block
    try testing.expectEqual(@as(usize, 1), count(once, begin));
    try testing.expectEqual(@as(usize, 1), count(twice, begin));
}

test "upsertBlock rewrites a changed init path in place, preserving surroundings" {
    const rc = "before\n";
    const v1 = try rc_writer.upsertBlock(testing.allocator, rc, "/old/init.bash", "bash");
    defer testing.allocator.free(v1);
    // add trailing content after the block to prove it's preserved on rewrite
    const with_tail = try std.fmt.allocPrint(testing.allocator, "{s}after-tail\n", .{v1});
    defer testing.allocator.free(with_tail);

    const v2 = try rc_writer.upsertBlock(testing.allocator, with_tail, "/new/init.zsh", "bash");
    defer testing.allocator.free(v2);
    try testing.expect(std.mem.indexOf(u8, v2, "/new/init.zsh") != null);
    try testing.expect(std.mem.indexOf(u8, v2, "/old/init.bash") == null); // old path gone
    try testing.expect(std.mem.startsWith(u8, v2, "before\n")); // leading preserved
    try testing.expect(std.mem.indexOf(u8, v2, "after-tail\n") != null); // trailing preserved
    try testing.expectEqual(@as(usize, 1), count(v2, begin)); // still one block
}

test "buildInitFile evaluates atty init for the given shell" {
    const f = try rc_writer.buildInitFile(testing.allocator, "zsh");
    defer testing.allocator.free(f);
    try testing.expect(std.mem.indexOf(u8, f, "eval \"$(atty init zsh)\"") != null);
}

test "fish gets fish syntax (set -gx / source), not posix" {
    const blk = try rc_writer.buildBlock(testing.allocator, "/p/init.fish", "fish");
    defer testing.allocator.free(blk);
    try testing.expect(std.mem.indexOf(u8, blk, "set -gx ATTY_SOURCE \"/p/init.fish\"") != null);
    try testing.expect(std.mem.indexOf(u8, blk, "and source \"$ATTY_SOURCE\"") != null);
    try testing.expect(std.mem.indexOf(u8, blk, "export ATTY_SOURCE") == null); // not posix

    const f = try rc_writer.buildInitFile(testing.allocator, "fish");
    defer testing.allocator.free(f);
    try testing.expect(std.mem.indexOf(u8, f, "atty init fish | source") != null);
    try testing.expect(std.mem.indexOf(u8, f, "eval \"$(") == null); // not the posix eval form
}

test "upsertBlock ignores a mid-line marker (preserves that line)" {
    // A user line that happens to contain the marker text mid-line must NOT be
    // treated as our block — its leading content stays, and a real block is
    // appended at the end.
    const rc = "echo keep-me # >>> atty >>>\n";
    const out = try rc_writer.upsertBlock(testing.allocator, rc, "/p/init.bash", "bash");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "echo keep-me # >>> atty >>>") != null); // line preserved
    try testing.expect(std.mem.indexOf(u8, out, "/p/init.bash") != null); // real block added
    try testing.expectEqual(@as(usize, 2), count(out, begin)); // the user's + ours
}

test "upsertBlock on an empty rc yields just the block" {
    const out = try rc_writer.upsertBlock(testing.allocator, "", "/p/init.bash", "bash");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, begin));
    try testing.expectEqual(@as(usize, 1), count(out, begin));
}

fn count(hay: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, needle)) |pos| {
        n += 1;
        i = pos + needle.len;
    }
    return n;
}
