//! attop shell-integration writer — the FILESYSTEM half of wizard 3b (the
//! pure block math lives in rc_writer.zig). `wireShell` is the only effectful
//! entry point and is invoked solely from the confirm-gated Setup action, so
//! attop never touches a user's rc without an explicit `y`.
//!
//! Safety properties (it edits the user's rc):
//!  - A read failure (permissions, I/O, a directory) is NEVER mistaken for an
//!    empty rc — only ENOENT (the file genuinely doesn't exist) is treated as
//!    empty. Any other error aborts BEFORE the rc is touched, so a transient
//!    failure can't blank the file.
//!  - Every write is atomic: write a sibling `.atty.tmp` then rename(2) over
//!    the target (atomic on the same fs), so a crash mid-write never leaves a
//!    half-written rc.
//!  - The rc is backed up to `.atty.bak` before it's replaced.
//!  - The managed block is idempotent (rc_writer), so re-running never dupes.
//!
//! libc fs (std.fs is io-threaded in 0.16; mirrors caps.zig); read/write
//! retry EINTR (attop installs a SIGWINCH handler).

const std = @import("std");
const rc_writer = @import("rc_writer.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 0o1;
const O_CREAT: c_int = 0o100;
const O_TRUNC: c_int = 0o1000;

pub const Error = error{ ReadFailed, WriteFailed, OutOfMemory };

fn errnoIs(e: std.c.E) bool {
    return std.c._errno().* == @intFromEnum(e);
}

/// Wire the shell: write `<config_dir>/init.<shell>`, back up `rc_path`, and
/// upsert the managed block into it. Idempotent (safe to re-run). Aborts
/// without touching the rc if it exists but can't be read.
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
    try writeFileAtomic(init_path, init_body);

    // ENOENT → first-time (null, not owned). Any other read error → abort
    // here, before the rc is written, so a failed read can't be read as
    // "empty". Free whatever readFile allocated regardless of length (a 0-byte
    // rc returns an owned empty slice — len can't double as the ownership flag).
    const maybe_rc = try readFile(allocator, rc_path);
    defer if (maybe_rc) |rc| allocator.free(rc);
    const rc_content: []const u8 = maybe_rc orelse "";

    if (rc_content.len > 0) {
        var bbuf: [4096]u8 = undefined;
        const bak = std.fmt.bufPrint(&bbuf, "{s}.atty.bak", .{rc_path}) catch return error.WriteFailed;
        try writeFileAtomic(bak, rc_content);
    }

    const new_rc = try rc_writer.upsertBlock(allocator, rc_content, init_path, shell);
    defer allocator.free(new_rc);
    try writeFileAtomic(rc_path, new_rc);
}

/// Read a file fully. null iff it doesn't exist (ENOENT); any other failure is
/// an error (NOT silently empty — that would let a transient read failure
/// blank the rc).
fn readFile(allocator: std.mem.Allocator, path: []const u8) Error!?[]u8 {
    var zbuf: [4096]u8 = undefined;
    const zp = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return error.ReadFailed;
    const fd = open(zp.ptr, O_RDONLY);
    if (fd < 0) return if (errnoIs(.NOENT)) null else error.ReadFailed;
    defer _ = std.c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n < 0) {
            if (errnoIs(.INTR)) continue;
            return error.ReadFailed; // e.g. EISDIR / EIO
        }
        if (n == 0) break;
        try list.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return try list.toOwnedSlice(allocator);
}

/// Write `bytes` to `path` atomically: a sibling `.atty.tmp` then rename(2).
fn writeFileAtomic(path: []const u8, bytes: []const u8) Error!void {
    var tbuf: [4096]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tbuf, "{s}.atty.tmp", .{path}) catch return error.WriteFailed;
    {
        const fd = open(tmp.ptr, O_WRONLY | O_CREAT | O_TRUNC, @as(c_uint, 0o644));
        if (fd < 0) return error.WriteFailed;
        defer _ = std.c.close(fd);
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
            if (n < 0) {
                if (errnoIs(.INTR)) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }
    var zbuf: [4096]u8 = undefined;
    const zpath = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return error.WriteFailed;
    if (rename(tmp.ptr, zpath.ptr) != 0) return error.WriteFailed;
}

/// mkdir each path component (best-effort; EEXIST ignored — a genuinely
/// unusable dir surfaces as a WriteFailed at the subsequent write).
fn mkdirP(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    var i: usize = 1; // a leading '/' is the root; skip it
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const z = std.fmt.bufPrintZ(&buf, "{s}", .{path[0..i]}) catch return;
            _ = mkdir(z.ptr, 0o755);
        }
    }
}

test {
    _ = @import("rc_apply_tests.zig");
}
