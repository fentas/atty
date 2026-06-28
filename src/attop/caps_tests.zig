const std = @import("std");
const testing = std.testing;
const caps = @import("caps.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn rmdir(path: [*:0]const u8) c_int;
const O_CREAT: c_int = 0o100;
const O_WRONLY: c_int = 0o1;

// Save/restore $PATH around a test that mutates it.
fn savePath(buf: []u8) ?[:0]const u8 {
    const cur = std.c.getenv("PATH") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}", .{std.mem.span(cur)}) catch null;
}
fn restorePath(saved: ?[:0]const u8) void {
    if (saved) |s| _ = setenv("PATH", s.ptr, 1) else _ = unsetenv("PATH");
}

test "attyOnPath finds an executable atty on PATH" {
    var save_buf: [4096]u8 = undefined;
    const saved = savePath(&save_buf);
    defer restorePath(saved);

    // A unique temp dir + an executable file named `atty` in it (all via
    // libc — 0.16's std.fs.createFile is io-threaded, awkward in a unit test).
    var tmpl = "/tmp/atty-caps-XXXXXX".*;
    const dir = mkdtemp(&tmpl) orelse return error.MkdtempFailed;
    defer _ = rmdir(dir); // registered before any `try` so the dir can't leak
    var fbuf: [256]u8 = undefined;
    const fpath = try std.fmt.bufPrintZ(&fbuf, "{s}/atty", .{std.mem.span(dir)});
    const fd = open(fpath.ptr, O_CREAT | O_WRONLY, 0o755);
    try testing.expect(fd >= 0);
    _ = std.c.close(fd);
    defer _ = unlink(fpath.ptr);

    _ = setenv("PATH", dir, 1);
    try testing.expect(caps.attyOnPath());
}

test "attyOnPath is false for a present-but-non-executable atty" {
    var save_buf: [4096]u8 = undefined;
    const saved = savePath(&save_buf);
    defer restorePath(saved);

    var tmpl = "/tmp/atty-caps-XXXXXX".*;
    const dir = mkdtemp(&tmpl) orelse return error.MkdtempFailed;
    defer _ = rmdir(dir);
    var fbuf: [256]u8 = undefined;
    const fpath = try std.fmt.bufPrintZ(&fbuf, "{s}/atty", .{std.mem.span(dir)});
    const fd = open(fpath.ptr, O_CREAT | O_WRONLY, 0o644); // no execute bits
    try testing.expect(fd >= 0);
    _ = std.c.close(fd);
    defer _ = unlink(fpath.ptr);

    _ = setenv("PATH", dir, 1);
    try testing.expect(!caps.attyOnPath()); // present but not executable → not "installed"
}

test "attyOnPath is false when atty is not on PATH" {
    var save_buf: [4096]u8 = undefined;
    const saved = savePath(&save_buf);
    defer restorePath(saved);

    _ = setenv("PATH", "/nonexistent-atty-test-dir", 1);
    try testing.expect(!caps.attyOnPath());
}

test "attyOnPath is false on an empty PATH" {
    var save_buf: [4096]u8 = undefined;
    const saved = savePath(&save_buf);
    defer restorePath(saved);

    _ = setenv("PATH", "", 1);
    try testing.expect(!caps.attyOnPath());
}
