const std = @import("std");
const testing = std.testing;
const rc_apply = @import("rc_apply.zig");
const rc_writer = @import("rc_writer.zig");

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
const O_CREAT: c_int = 0o100;
const O_WRONLY: c_int = 0o1;
const O_RDONLY: c_int = 0;

fn seed(path: []const u8, bytes: []const u8) !void {
    var z: [512]u8 = undefined;
    const zp = try std.fmt.bufPrintZ(&z, "{s}", .{path});
    const fd = open(zp.ptr, O_WRONLY | O_CREAT, 0o644);
    try testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    _ = std.c.write(fd, bytes.ptr, bytes.len);
}

fn readBack(path: []const u8) ?[]u8 {
    var z: [512]u8 = undefined;
    const zp = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return null;
    const fd = open(zp.ptr, O_RDONLY, 0);
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(testing.allocator);
    var c: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &c) catch break;
        if (n == 0) break;
        list.appendSlice(testing.allocator, c[0..n]) catch return null;
    }
    return list.toOwnedSlice(testing.allocator) catch null;
}

fn countMarkers(hay: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, rc_writer.begin)) |pos| {
        n += 1;
        i = pos + rc_writer.begin.len;
    }
    return n;
}

test "wireShell writes the init file, upserts the rc, backs it up, idempotent" {
    var tmpl = "/tmp/atty-rcw-XXXXXX".*;
    const dir = mkdtemp(&tmpl) orelse return error.MkdtempFailed;
    const ds = std.mem.span(dir);

    var rcbuf: [256]u8 = undefined;
    const rc_path = try std.fmt.bufPrint(&rcbuf, "{s}/.bashrc", .{ds});
    try seed(rc_path, "export PS1='$ '\n");

    var cfgbuf: [256]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfgbuf, "{s}/.config/atty", .{ds}); // exercises mkdirP

    try rc_apply.wireShell(testing.allocator, cfg, "bash", rc_path);

    // init file exists with the self-updating eval line
    var ipbuf: [256]u8 = undefined;
    const init_path = try std.fmt.bufPrint(&ipbuf, "{s}/init.bash", .{cfg});
    const init = readBack(init_path) orelse return error.NoInit;
    defer testing.allocator.free(init);
    try testing.expect(std.mem.indexOf(u8, init, "eval \"$(atty init bash)\"") != null);

    // rc: original preserved + exactly one block referencing the init path
    const rc = readBack(rc_path) orelse return error.NoRc;
    defer testing.allocator.free(rc);
    try testing.expect(std.mem.indexOf(u8, rc, "export PS1='$ '") != null);
    try testing.expect(std.mem.indexOf(u8, rc, init_path) != null);
    try testing.expectEqual(@as(usize, 1), countMarkers(rc));

    // backup holds the pre-edit rc verbatim
    var bakbuf: [256]u8 = undefined;
    const bak = try std.fmt.bufPrint(&bakbuf, "{s}.atty.bak", .{rc_path});
    const bakc = readBack(bak) orelse return error.NoBak;
    defer testing.allocator.free(bakc);
    try testing.expectEqualStrings("export PS1='$ '\n", bakc);

    // re-run → still exactly one block (idempotent on disk)
    try rc_apply.wireShell(testing.allocator, cfg, "bash", rc_path);
    const rc2 = readBack(rc_path) orelse return error.NoRc2;
    defer testing.allocator.free(rc2);
    try testing.expectEqual(@as(usize, 1), countMarkers(rc2));
}

test "wireShell aborts on a read error, leaving the target untouched" {
    var tmpl = "/tmp/atty-rcw3-XXXXXX".*;
    const dir = mkdtemp(&tmpl) orelse return error.MkdtempFailed;
    const ds = std.mem.span(dir);

    // rc_path points at a DIRECTORY → open succeeds, read fails (EISDIR) → a
    // genuine read error, NOT "absent". wireShell must abort, not blank it.
    var rcbuf: [256]u8 = undefined;
    const rc_dir = try std.fmt.bufPrintZ(&rcbuf, "{s}/as-a-dir", .{ds});
    try testing.expect(mkdir(rc_dir.ptr, 0o755) == 0);
    var cfgbuf: [256]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfgbuf, "{s}/cfg", .{ds});

    try testing.expectError(error.ReadFailed, rc_apply.wireShell(testing.allocator, cfg, "bash", rc_dir));

    // aborted before backup → no .atty.bak
    var bakbuf: [256]u8 = undefined;
    const bak = try std.fmt.bufPrint(&bakbuf, "{s}.atty.bak", .{rc_dir});
    try testing.expect(readBack(bak) == null);
}

test "wireShell creates the rc when it does not exist (no backup)" {
    var tmpl = "/tmp/atty-rcw2-XXXXXX".*;
    const dir = mkdtemp(&tmpl) orelse return error.MkdtempFailed;
    const ds = std.mem.span(dir);

    var rcbuf: [256]u8 = undefined;
    const rc_path = try std.fmt.bufPrint(&rcbuf, "{s}/.zshrc", .{ds}); // does not exist yet
    var cfgbuf: [256]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfgbuf, "{s}/cfg", .{ds});

    try rc_apply.wireShell(testing.allocator, cfg, "zsh", rc_path);

    const rc = readBack(rc_path) orelse return error.NoRc;
    defer testing.allocator.free(rc);
    try testing.expectEqual(@as(usize, 1), countMarkers(rc));
    try testing.expect(std.mem.indexOf(u8, rc, "init.zsh") != null);

    // no .atty.bak (there was nothing to back up)
    var bakbuf: [256]u8 = undefined;
    const bak = try std.fmt.bufPrint(&bakbuf, "{s}.atty.bak", .{rc_path});
    try testing.expect(readBack(bak) == null);
}
