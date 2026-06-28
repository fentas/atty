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

// Save/restore an arbitrary env var around a test that mutates it.
const EnvSave = struct { name: [*:0]const u8, val: ?[:0]u8 };
fn saveEnv(name: [*:0]const u8) EnvSave {
    const cur = std.c.getenv(name);
    return .{ .name = name, .val = if (cur) |c| testing.allocator.dupeZ(u8, std.mem.span(c)) catch null else null };
}
fn restoreEnv(s: EnvSave) void {
    if (s.val) |v| {
        _ = setenv(s.name, v.ptr, 1);
        testing.allocator.free(v);
    } else {
        _ = unsetenv(s.name);
    }
}

// Save/restore $PATH around a test that mutates it. Allocator-owned (no
// fixed buffer) so a long real PATH is preserved exactly, not truncated to
// null — which would otherwise leave $PATH unset after the test.
fn savePath() ?[:0]u8 {
    const cur = std.c.getenv("PATH") orelse return null;
    return testing.allocator.dupeZ(u8, std.mem.span(cur)) catch null;
}
fn restorePath(saved: ?[:0]u8) void {
    if (saved) |s| {
        _ = setenv("PATH", s.ptr, 1);
        testing.allocator.free(s);
    } else {
        _ = unsetenv("PATH");
    }
}

test "attyOnPath finds an executable atty on PATH" {
    const saved = savePath();
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
    const saved = savePath();
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
    const saved = savePath();
    defer restorePath(saved);

    _ = setenv("PATH", "/nonexistent-atty-test-dir", 1);
    try testing.expect(!caps.attyOnPath());
}

test "attyOnPath is false on an empty PATH" {
    const saved = savePath();
    defer restorePath(saved);

    _ = setenv("PATH", "", 1);
    try testing.expect(!caps.attyOnPath());
}

test "shellIntegrated true when ATTY_SOURCE is set" {
    const save = saveEnv("ATTY_SOURCE");
    defer restoreEnv(save);
    _ = setenv("ATTY_SOURCE", "/home/u/.config/atty/init.bash", 1);
    try testing.expect(caps.shellIntegrated());
}

test "shellIntegrated true when the rc carries the atty marker" {
    const save_src = saveEnv("ATTY_SOURCE");
    defer restoreEnv(save_src);
    const save_home = saveEnv("HOME");
    defer restoreEnv(save_home);
    const save_shell = saveEnv("SHELL");
    defer restoreEnv(save_shell);
    _ = unsetenv("ATTY_SOURCE"); // force the rc-scan path

    var tmpl = "/tmp/atty-home-XXXXXX".*;
    const dir = mkdtemp(&tmpl) orelse return error.MkdtempFailed;
    defer _ = rmdir(dir);
    var fbuf: [256]u8 = undefined;
    const rc = try std.fmt.bufPrintZ(&fbuf, "{s}/.bashrc", .{std.mem.span(dir)});
    const fd = open(rc.ptr, O_CREAT | O_WRONLY, 0o644);
    try testing.expect(fd >= 0);
    const body = caps.rc_marker ++ "\nexport ATTY_SOURCE=x\n# <<< atty <<<\n";
    _ = std.c.write(fd, body.ptr, body.len);
    _ = std.c.close(fd);
    defer _ = unlink(rc.ptr);

    _ = setenv("HOME", dir, 1);
    _ = setenv("SHELL", "/bin/bash", 1);
    try testing.expect(caps.shellIntegrated());
}

test "shellIntegrated true for a hand-wired rc (eval atty init)" {
    const save_src = saveEnv("ATTY_SOURCE");
    defer restoreEnv(save_src);
    const save_home = saveEnv("HOME");
    defer restoreEnv(save_home);
    const save_shell = saveEnv("SHELL");
    defer restoreEnv(save_shell);
    _ = unsetenv("ATTY_SOURCE");

    var tmpl = "/tmp/atty-home-XXXXXX".*;
    const dir = mkdtemp(&tmpl) orelse return error.MkdtempFailed;
    defer _ = rmdir(dir);
    var fbuf: [256]u8 = undefined;
    const rc = try std.fmt.bufPrintZ(&fbuf, "{s}/.bashrc", .{std.mem.span(dir)});
    const fd = open(rc.ptr, O_CREAT | O_WRONLY, 0o644);
    try testing.expect(fd >= 0);
    const body = "eval \"$(atty init bash)\"\n"; // the canonical manual integration
    _ = std.c.write(fd, body.ptr, body.len);
    _ = std.c.close(fd);
    defer _ = unlink(rc.ptr);

    _ = setenv("HOME", dir, 1);
    _ = setenv("SHELL", "/bin/bash", 1);
    try testing.expect(caps.shellIntegrated());
}

test "shellIntegrated false with no ATTY_SOURCE and an unmarked rc" {
    const save_src = saveEnv("ATTY_SOURCE");
    defer restoreEnv(save_src);
    const save_home = saveEnv("HOME");
    defer restoreEnv(save_home);
    const save_shell = saveEnv("SHELL");
    defer restoreEnv(save_shell);
    _ = unsetenv("ATTY_SOURCE");

    var tmpl = "/tmp/atty-home-XXXXXX".*;
    const dir = mkdtemp(&tmpl) orelse return error.MkdtempFailed;
    defer _ = rmdir(dir);
    var fbuf: [256]u8 = undefined;
    const rc = try std.fmt.bufPrintZ(&fbuf, "{s}/.bashrc", .{std.mem.span(dir)});
    const fd = open(rc.ptr, O_CREAT | O_WRONLY, 0o644);
    try testing.expect(fd >= 0);
    _ = std.c.write(fd, "export PS1='$ '\n".ptr, 15);
    _ = std.c.close(fd);
    defer _ = unlink(rc.ptr);

    _ = setenv("HOME", dir, 1);
    _ = setenv("SHELL", "/bin/bash", 1);
    try testing.expect(!caps.shellIntegrated());
}

test "shellName maps $SHELL to bash/zsh/fish (default bash)" {
    const save = saveEnv("SHELL");
    defer restoreEnv(save);
    _ = setenv("SHELL", "/usr/bin/zsh", 1);
    try testing.expectEqualStrings("zsh", caps.shellName());
    _ = setenv("SHELL", "/usr/bin/fish", 1);
    try testing.expectEqualStrings("fish", caps.shellName());
    _ = setenv("SHELL", "/bin/bash", 1);
    try testing.expectEqualStrings("bash", caps.shellName());
    _ = unsetenv("SHELL");
    try testing.expectEqualStrings("bash", caps.shellName()); // unset → default
}
