//! Per-user trust cache. Line-delimited file of 64-char SHA-256
//! hex digests. Each digest = SHA256("<category>:<matched-substring>").
//!
//! Storage shape (one line per trusted match):
//!   <64-hex-digit hash>
//!
//! Anything that doesn't parse as 64 hex digits is skipped (rather
//! than rejecting the whole file) — preserves users who hand-edit
//! the file.

const std = @import("std");
const patterns = @import("patterns.zig");

pub const hex_len: usize = 64;

pub const TrustCache = struct {
    entries: std.ArrayList([hex_len]u8) = .empty,
    loaded: bool = false,

    pub fn load(self: *TrustCache, allocator: std.mem.Allocator, path_unexpanded: []const u8) !void {
        if (self.loaded) return;
        self.loaded = true;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = expandTilde(path_unexpanded, &path_buf) catch return;

        // Cap file size — a trust cache larger than this is
        // almost certainly corrupted or a DoS vector; bail rather
        // than load megabytes of "trusted" hashes.
        const max_bytes: usize = 1 << 20; // 1 MiB
        const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY });
        if (fd < 0) return;
        defer _ = std.c.close(fd);

        var buf = try allocator.alloc(u8, max_bytes);
        defer allocator.free(buf);
        var read_total: usize = 0;
        while (read_total < buf.len) {
            const n = std.c.read(fd, buf.ptr + read_total, buf.len - read_total);
            if (n <= 0) break;
            read_total += @intCast(n);
        }

        var it = std.mem.splitScalar(u8, buf[0..read_total], '\n');
        while (it.next()) |raw| {
            const trimmed = std.mem.trimEnd(u8, raw, " \r\t");
            if (trimmed.len != hex_len) continue;
            if (!isHex(trimmed)) continue;
            var entry: [hex_len]u8 = undefined;
            @memcpy(&entry, trimmed);
            try self.entries.append(allocator, entry);
        }
    }

    pub fn deinit(self: *TrustCache, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn contains(self: *const TrustCache, hash: []const u8) bool {
        if (hash.len != hex_len) return false;
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, &e, hash)) return true;
        }
        return false;
    }

    /// Adds `hash` to the in-memory list if not already present.
    /// Returns true when newly added.
    pub fn add(self: *TrustCache, allocator: std.mem.Allocator, hash: []const u8) !bool {
        if (hash.len != hex_len) return false;
        if (self.contains(hash)) return false;
        var entry: [hex_len]u8 = undefined;
        @memcpy(&entry, hash);
        try self.entries.append(allocator, entry);
        return true;
    }

    /// Best-effort write — creates parent dirs as needed. Errors
    /// returned (caller logs / swallows). Atomic via tmp+rename so
    /// a crash mid-write leaves the previous cache intact.
    pub fn persist(self: *const TrustCache, path_unexpanded: []const u8) !void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try expandTilde(path_unexpanded, &path_buf);

        // mkdir -p the parent.
        if (std.fs.path.dirname(path)) |dir| {
            mkdirP(dir) catch {};
        }

        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len + 4 > tmp_buf.len) return error.PathTooLong;
        const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{path}) catch return error.PathTooLong;

        var path_z_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path}) catch return error.PathTooLong;

        const fd = std.c.open(tmp.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return error.FileOpenFailed;
        var ok = true;
        for (self.entries.items) |e| {
            const w1 = std.c.write(fd, &e, hex_len);
            if (w1 != @as(isize, @intCast(hex_len))) {
                ok = false;
                break;
            }
            const nl: u8 = '\n';
            const w2 = std.c.write(fd, @as([*]const u8, @ptrCast(&nl)), 1);
            if (w2 != 1) {
                ok = false;
                break;
            }
        }
        _ = std.c.close(fd);
        if (!ok) return error.WriteFailed;
        if (std.c.rename(tmp.ptr, path_z.ptr) != 0) return error.RenameFailed;
    }
};

/// Compute SHA256("<category>:<matched>") and write the hex digest
/// into `out` (must be at least `hex_len`). Returns the slice of
/// `out` that was written.
pub fn hashCategoryMatch(
    category: patterns.Category,
    matched: []const u8,
    out: []u8,
) []const u8 {
    std.debug.assert(out.len >= hex_len);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const tag: []const u8 = switch (category) {
        .curl_pipe_sh => "curl_pipe_sh",
        .npm_unsafe_install => "npm_unsafe_install",
        .bash_c_base64 => "bash_c_base64",
    };
    hasher.update(tag);
    hasher.update(":");
    hasher.update(matched);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex_alpha = "0123456789abcdef";
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        out[i * 2] = hex_alpha[digest[i] >> 4];
        out[i * 2 + 1] = hex_alpha[digest[i] & 0x0F];
    }
    return out[0..hex_len];
}

fn isHex(s: []const u8) bool {
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) return false;
    }
    return true;
}

/// Expand a leading `~` to `$HOME`. Returns the expanded path
/// written into `out` (NULL-terminated for C interop). Falls
/// through unchanged when no leading tilde.
fn expandTilde(path: []const u8, out: []u8) ![:0]u8 {
    if (path.len > 0 and path[0] == '~') {
        const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
        const home = std.mem.span(home_ptr);
        return std.fmt.bufPrintZ(out, "{s}{s}", .{ home, path[1..] }) catch error.PathTooLong;
    }
    return std.fmt.bufPrintZ(out, "{s}", .{path}) catch error.PathTooLong;
}

fn mkdirP(dir: []const u8) !void {
    var path_z_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{dir}) catch return error.PathTooLong;
    // Read errno from the actual mkdir return value (not from a
    // literal sentinel — passing `-1` works in practice but masks
    // the syscall contract: errno is only meaningful when the
    // return was the error sentinel, which is what `errno(rc)`
    // checks for. See std.posix.errno.
    const rc = std.c.mkdir(dir_z.ptr, 0o755);
    if (rc == 0) return;
    const e = std.posix.errno(rc);
    if (e == .EXIST) return;
    if (std.fs.path.dirname(dir)) |parent| {
        if (parent.len < dir.len) {
            try mkdirP(parent);
            const rc2 = std.c.mkdir(dir_z.ptr, 0o755);
            if (rc2 == 0) return;
            const e2 = std.posix.errno(rc2);
            if (e2 == .EXIST) return;
        }
    }
    return error.MkdirFailed;
}

test {
    _ = @import("trust_cache_tests.zig");
}
