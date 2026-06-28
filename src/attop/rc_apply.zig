//! attop shell-integration writer — the FILESYSTEM half of wizard 3b (the
//! pure block math lives in rc_writer.zig). `wireShell` is the only effectful
//! entry point and is invoked solely from the confirm-gated Setup action, so
//! attop never touches a user's rc without an explicit `y`.
//!
//! Order is chosen so a crash mid-way can't corrupt the rc: write the init
//! file first, BACK UP the rc (rc.atty.bak) before editing, then overwrite the
//! rc with the upserted content. The backup + idempotent block mean the worst
//! case is a recoverable, re-runnable state.
//!
//! libc fs (std.fs is io-threaded in 0.16; this mirrors caps.zig's libc reads).

const std = @import("std");
const rc_writer = @import("rc_writer.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 0o1;
const O_CREAT: c_int = 0o100;
const O_TRUNC: c_int = 0o1000;

pub const Error = error{ WriteFailed, OutOfMemory };

/// Wire the shell: write `<config_dir>/init.<shell>`, back up `rc_path`, and
/// upsert the managed block into it. Idempotent (safe to re-run). `config_dir`
/// and its ancestors are created as needed. Paths are taken explicitly so the
/// whole effect is exercisable against a tmp dir in tests.
pub fn wireShell(
    allocator: std.mem.Allocator,
    config_dir: []const u8,
    shell: []const u8,
    rc_path: []const u8,
) Error!void {
    mkdirP(config_dir);

    var pbuf: [4096]u8 = undefined;
    const init_path = std.fmt.bufPrint(&pbuf, "{s}/init.{s}", .{ config_dir, shell }) catch return error.WriteFailed;

    const init_body = try rc_writer.buildInitFile(allocator, shell);
    defer allocator.free(init_body);
    try writeFile(init_path, init_body);

    // Read the current rc (absent → empty), back it up, then upsert + write.
    const rc_content = readFileAlloc(allocator, rc_path) orelse "";
    defer if (rc_content.len > 0) allocator.free(rc_content);

    if (rc_content.len > 0) {
        var bbuf: [4096]u8 = undefined;
        const bak = std.fmt.bufPrint(&bbuf, "{s}.atty.bak", .{rc_path}) catch return error.WriteFailed;
        try writeFile(bak, rc_content);
    }

    const new_rc = try rc_writer.upsertBlock(allocator, rc_content, init_path);
    defer allocator.free(new_rc);
    try writeFile(rc_path, new_rc);
}

/// mkdir each path component (best-effort; EEXIST and friends are ignored —
/// the subsequent writeFile surfaces a genuinely unusable dir).
fn mkdirP(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    var i: usize = 1; // a leading '/' is the root; skip it
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const seg = path[0..i];
            const z = std.fmt.bufPrintZ(&buf, "{s}", .{seg}) catch return;
            _ = mkdir(z.ptr, 0o755);
        }
    }
}

fn writeFile(path: []const u8, bytes: []const u8) Error!void {
    var zbuf: [4096]u8 = undefined;
    const zpath = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return error.WriteFailed;
    const fd = open(zpath.ptr, O_WRONLY | O_CREAT | O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return error.WriteFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var zbuf: [4096]u8 = undefined;
    const zpath = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return null;
    const fd = open(zpath.ptr, O_RDONLY);
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &chunk) catch break;
        if (n == 0) break;
        list.appendSlice(allocator, chunk[0..n]) catch return null;
    }
    return list.toOwnedSlice(allocator) catch null;
}

test {
    _ = @import("rc_apply_tests.zig");
}
