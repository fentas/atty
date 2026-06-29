//! Tiny runtime file helpers over libc (`std.fs.cwd()` is gone in 0.16; runtime
//! file ops go through `std.c.*`). Used by the recorder + snapshotter modules
//! so their pure render/compare cores stay free of IO concerns.

const std = @import("std");
const Allocator = std.mem.Allocator;

const wr_flags: std.c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
const rd_flags: std.c.O = .{ .ACCMODE = .RDONLY };

/// Write `bytes` to `path` (created/truncated, 0644). Best-effort parent
/// `mkdir` (one level) so a golden/output dir need not pre-exist.
pub fn writeFile(path: [:0]const u8, bytes: []const u8) !void {
    mkdirParent(path);
    const fd = std.c.open(path.ptr, wr_flags, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (rc <= 0) return error.WriteFailed;
        off += @intCast(rc);
    }
}

/// Read all of `path` into an allocation, or `error.FileNotFound` if absent.
pub fn readFileAlloc(allocator: Allocator, path: [:0]const u8, max: usize) ![]u8 {
    const fd = std.c.open(path.ptr, rd_flags, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (list.items.len < max) {
        const rc = std.c.read(fd, &buf, buf.len);
        if (rc < 0) return error.ReadFailed;
        if (rc == 0) break;
        try list.appendSlice(allocator, buf[0..@intCast(rc)]);
    }
    return list.toOwnedSlice(allocator);
}

/// Best-effort `mkdir -p` of `path`'s parent directory (so a nested golden /
/// output dir need not pre-exist). All errors, including EEXIST, are ignored.
fn mkdirParent(path: [:0]const u8) void {
    const end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (end == 0) return; // parent is "/" — exists
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (end >= buf.len) return;
    @memcpy(buf[0..end], path[0..end]);
    // mkdir each path component in turn ("/a", "/a/b", …) by NUL-terminating
    // at each separator; std.c.mkdir reads up to the first NUL.
    var i: usize = 1;
    while (i <= end) : (i += 1) {
        if (i == end or buf[i] == '/') {
            buf[i] = 0;
            _ = std.c.mkdir(&buf, @as(std.c.mode_t, 0o755));
            if (i < end) buf[i] = '/';
        }
    }
}
