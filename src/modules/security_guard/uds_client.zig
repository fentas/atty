//! UDS client for atty-guard. Sends classify / threat-level RPCs
//! over the Unix domain socket, parses JSON-line replies, surfaces
//! errors to the caller.
//!
//! Connection is LAZY (opens on first use) and STICKY (kept open
//! across calls — atty's session is one connection). Reconnect on
//! any I/O error. Read timeout caps the worst-case keystroke
//! latency at `Client.read_timeout_ms` (50ms default).
//!
//! The sidecar is OPTIONAL — when its socket is missing the client
//! short-circuits to `error.Unavailable` and the caller (the
//! `security_guard` module) falls back to its in-proc patterns.
//! Failure to talk to the daemon never crashes atty.

const std = @import("std");
const patterns = @import("patterns.zig");
const trust_cache_mod = @import("trust_cache.zig");

pub const Verdict = enum {
    safe,
    warn,
    block,

    pub fn fromString(s: []const u8) ?Verdict {
        if (std.mem.eql(u8, s, "safe")) return .safe;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "block")) return .block;
        return null;
    }
};

pub const Category = enum {
    none,
    curl_pipe_sh,
    npm_unsafe_install,
    bash_c_base64,
    pid_high_threat,

    pub fn fromString(s: []const u8) ?Category {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "curl_pipe_sh")) return .curl_pipe_sh;
        if (std.mem.eql(u8, s, "npm_unsafe_install")) return .npm_unsafe_install;
        if (std.mem.eql(u8, s, "bash_c_base64")) return .bash_c_base64;
        if (std.mem.eql(u8, s, "pid_high_threat")) return .pid_high_threat;
        return null;
    }

    /// Map daemon-side category back to the in-proc `patterns.Category`
    /// so the existing trust-cache hash logic stays usable for
    /// daemon-flagged matches too. Returns null when no in-proc
    /// equivalent exists (e.g. `pid_high_threat` is sidecar-only).
    pub fn toLocal(self: Category) ?patterns.Category {
        return switch (self) {
            .none, .pid_high_threat => null,
            .curl_pipe_sh => .curl_pipe_sh,
            .npm_unsafe_install => .npm_unsafe_install,
            .bash_c_base64 => .bash_c_base64,
        };
    }
};

/// Parsed classify result. Strings are sliced from the response
/// buffer the client owns until the next call.
pub const ClassifyResult = struct {
    verdict: Verdict,
    category: Category,
    confidence: f32,
    reason: []const u8,
    matched: []const u8,
};

pub const Error = error{
    /// Sidecar socket isn't reachable. Caller falls back to in-proc
    /// patterns.
    Unavailable,
    /// Daemon returned malformed JSON or an `error` envelope.
    DaemonError,
    /// Read timed out before a full response line arrived.
    Timeout,
    OutOfMemory,
};

pub const Client = struct {
    socket_path: []const u8,
    fd: i32 = -1,
    next_id: u64 = 1,
    /// 16 KiB caps a single daemon response. The hot signal is
    /// `matched` (the substring that tripped the daemon); long
    /// URLs inside `curl|sh` matches are real, so 4 KiB was tight
    /// in practice. Beyond 16 KiB the daemon is either misbehaving
    /// or attacking us; `readLine` returns LineTooLong, the caller
    /// closes the fd, and the in-proc patterns kick in as fallback.
    read_buf: [16384]u8 = undefined,
    /// 4 KiB is plenty for the request side — atty's committed
    /// line is bounded by readline's edit buffer (typically 4096)
    /// and the context blob is small.
    write_buf: [4096]u8 = undefined,
    /// Read timeout per request. Caps the worst-case keystroke
    /// stall when the daemon is slow / wedged. Caller should
    /// re-validate at call time if it wants different bounds.
    read_timeout_ms: u32 = 50,

    pub fn init(socket_path: []const u8) Client {
        return .{ .socket_path = socket_path };
    }

    pub fn deinit(self: *Client) void {
        self.close();
    }

    /// Closes the underlying fd if open. Safe to call repeatedly.
    pub fn close(self: *Client) void {
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
    }

    /// Probe whether the daemon is reachable WITHOUT performing a
    /// classify. Returns true on connect success (and keeps the
    /// connection open for subsequent calls). False on any I/O
    /// error.
    pub fn health(self: *Client) bool {
        const result = self.classifyOrErr("__atty_health_ping__", .{}) catch return false;
        _ = result;
        return true;
    }

    pub const ClassifyContext = struct {
        pid: ?u32 = null,
        shell: ?[]const u8 = null,
        incognito: bool = false,
    };

    /// Classify a typed command. Returns the daemon's verdict on
    /// success or `error.Unavailable` when the socket is gone.
    /// The returned slices reference `read_buf`; they're valid
    /// until the next `classify` call.
    pub fn classifyOrErr(
        self: *Client,
        command: []const u8,
        ctx: ClassifyContext,
    ) Error!ClassifyResult {
        try self.ensureConnected();

        const id = self.next_id;
        self.next_id +%= 1;

        var w: std.Io.Writer = .fixed(&self.write_buf);
        // Hand-rolled JSON to avoid pulling std.json into the hot
        // path. Escape only the bare-minimum chars; atty's
        // committed-line bytes are NOT shell-escaped here, that's
        // the daemon's job to interpret. The whole serialisation
        // block can only fail one way — buffer overflow — which
        // we map to `OutOfMemory` (semantically "request too big
        // for our 4 KiB write buffer").
        buildClassifyJson(&w, id, command, ctx) catch return Error.OutOfMemory;

        self.writeAll(self.write_buf[0..w.end]) catch {
            self.close();
            return Error.Unavailable;
        };

        const line_len = self.readLine() catch |e| switch (e) {
            error.Timeout => return Error.Timeout,
            else => {
                self.close();
                return Error.Unavailable;
            },
        };

        return parseClassifyResponse(self.read_buf[0..line_len]);
    }

    pub fn setThreatLevel(self: *Client, pid: u32, level: ThreatLevel) Error!void {
        try self.ensureConnected();
        const level_s: []const u8 = switch (level) {
            .low => "low",
            .high => "high",
            .critical => "critical",
        };
        var w: std.Io.Writer = .fixed(&self.write_buf);
        const id = self.next_id;
        self.next_id +%= 1;
        (w.print(
            "{{\"id\":{d},\"method\":\"set_threat_level\",\"pid\":{d},\"level\":\"{s}\"}}\n",
            .{ id, pid, level_s },
        )) catch return Error.OutOfMemory;
        self.writeAll(self.write_buf[0..w.end]) catch {
            self.close();
            return Error.Unavailable;
        };
        const line_len = self.readLine() catch {
            self.close();
            return Error.Unavailable;
        };
        // We don't parse the body — daemon returns `{"type":"ok"}`
        // on success. Any well-formed line is treated as success
        // here; the in-proc fallback handles cases where the daemon
        // closed mid-write.
        _ = line_len;
    }

    pub const ThreatLevel = enum { low, high, critical };

    /// Best-effort mirror of an `[a]llow always` keystroke
    /// to the daemon. atty's session_trust set is authoritative for
    /// the runtime check; this RPC just lets `atty-guard session
    /// list` show the operator what they trusted in this session.
    /// Errors are silently dropped: the local trust takes effect
    /// regardless of daemon reachability.
    pub fn sessionAddTrust(self: *Client, hash: []const u8) Error!void {
        try self.ensureConnected();
        var w: std.Io.Writer = .fixed(&self.write_buf);
        const id = self.next_id;
        self.next_id +%= 1;
        (w.print(
            "{{\"id\":{d},\"method\":\"session_add_trust\",\"hash\":\"{s}\"}}\n",
            .{ id, hash },
        )) catch return Error.OutOfMemory;
        self.writeAll(self.write_buf[0..w.end]) catch {
            self.close();
            return Error.Unavailable;
        };
        _ = self.readLine() catch {
            self.close();
            return Error.Unavailable;
        };
    }

    /// Canonical persistence path for `[t]rust permanently`.
    /// Writes the hash into the daemon's per-UID
    /// `commands.trusted.txt`. A fresh atty session (or another
    /// atty proxy under the same UID) picks it up at first Enter
    /// via the daemon's trust list. The atty-side `rt.trust`
    /// HashSet is also populated locally so the SAME atty session's
    /// next Enter short-circuits the banner without a UDS round-trip.
    ///
    /// `hash` is provably `[0-9a-f]{64}` by construction — see
    /// security_guard/trust_cache.zig::hashCategoryMatch which
    /// writes from a fixed `"0123456789abcdef"` lookup. Raw
    /// interpolation into JSON is safe; if the hash format ever
    /// changes (e.g. to BLAKE3 or base64), the JSON escaper from
    /// `sessionAddUrlBlock` should be reused here.
    pub fn trustAdd(self: *Client, hash: []const u8) Error!void {
        try self.ensureConnected();
        var w: std.Io.Writer = .fixed(&self.write_buf);
        const id = self.next_id;
        self.next_id +%= 1;
        (w.print(
            "{{\"id\":{d},\"method\":\"trust_add\",\"hash\":\"{s}\"}}\n",
            .{ id, hash },
        )) catch return Error.OutOfMemory;
        self.writeAll(self.write_buf[0..w.end]) catch {
            self.close();
            return Error.Unavailable;
        };
        _ = self.readLine() catch {
            self.close();
            return Error.Unavailable;
        };
    }

    /// Fetch the caller's persistent trust hashes from the daemon
    /// + merge them into `target`. Called once per atty session
    /// after the first successful daemon classify (lazy seed) so a
    /// SECOND atty proxy under the same UID picks up trust hashes
    /// set on a different shell. Errors are non-fatal — banner [t]
    /// in THIS session still works (adds to rt.trust locally +
    /// mirrors via trustAdd), so the worst case is "cross-shell
    /// trust hashes unavailable this session," not "trust check
    /// fails."
    pub fn trustList(
        self: *Client,
        allocator: std.mem.Allocator,
        target: *trust_cache_mod.TrustCache,
    ) Error!void {
        try self.ensureConnected();
        var w: std.Io.Writer = .fixed(&self.write_buf);
        const id = self.next_id;
        self.next_id +%= 1;
        (w.print("{{\"id\":{d},\"method\":\"trust_list\"}}\n", .{id})) catch return Error.OutOfMemory;
        self.writeAll(self.write_buf[0..w.end]) catch {
            self.close();
            return Error.Unavailable;
        };
        const line_len = self.readLine() catch {
            self.close();
            return Error.Unavailable;
        };
        // Parse minimal: scan for "trust":[...] array, extract each
        // 64-char hex needle, add to target. Avoids pulling in a
        // full JSON parser for what is a known-shape response.
        const body = self.read_buf[0..line_len];
        const trust_at = std.mem.indexOf(u8, body, "\"trust\":[") orelse return;
        const arr_start = trust_at + "\"trust\":[".len;
        var cursor: usize = arr_start;
        while (cursor < body.len) {
            const open_quote = std.mem.indexOfScalarPos(u8, body, cursor, '"') orelse break;
            if (open_quote + 1 + trust_cache_mod.hex_len > body.len) break;
            const close_quote = open_quote + 1 + trust_cache_mod.hex_len;
            if (body[close_quote] != '"') break;
            const hex_slice = body[open_quote + 1 .. close_quote];
            _ = target.add(allocator, hex_slice) catch {};
            cursor = close_quote + 1;
            // Stop at closing `]`.
            if (cursor < body.len and body[cursor] == ']') break;
        }
    }

    /// Best-effort mirror of a `[B]lock host forever`
    /// keystroke to the daemon. Same trade-off as
    /// `sessionAddTrust`: local block is authoritative, daemon
    /// receives a copy for `atty-guard session list` visibility +
    /// future `sudo atty-guard session write` persistence.
    /// `host` is escaped per RFC 8259 before interpolation —
    /// `"` and `\` and control chars are common enough in
    /// real shell input that JSON injection would otherwise be a
    /// real corruption path.
    pub fn sessionAddUrlBlock(self: *Client, host: []const u8) Error!void {
        try self.ensureConnected();
        var w: std.Io.Writer = .fixed(&self.write_buf);
        const id = self.next_id;
        self.next_id +%= 1;
        (w.print(
            "{{\"id\":{d},\"method\":\"session_add_url_block\",\"host\":\"",
            .{id},
        )) catch return Error.OutOfMemory;
        writeJsonStringEscaped(&w, host) catch return Error.OutOfMemory;
        (w.writeAll("\"}\n")) catch return Error.OutOfMemory;
        self.writeAll(self.write_buf[0..w.end]) catch {
            self.close();
            return Error.Unavailable;
        };
        _ = self.readLine() catch {
            self.close();
            return Error.Unavailable;
        };
    }

    /// RFC 8259 minimal JSON-string escaper: `"`, `\`, control
    /// chars (`< 0x20`). Other bytes pass through (we don't
    /// re-encode non-ASCII; UTF-8 is already valid JSON).
    fn writeJsonStringEscaped(w: *std.Io.Writer, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => {
                    if (c < 0x20) {
                        // \uXXXX escape for any other control char.
                        const hex_chars = "0123456789abcdef";
                        try w.writeAll("\\u00");
                        try w.writeByte(hex_chars[(c >> 4) & 0x0F]);
                        try w.writeByte(hex_chars[c & 0x0F]);
                    } else {
                        try w.writeByte(c);
                    }
                },
            }
        }
    }

    // --- internals -----------------------------------------------------

    fn ensureConnected(self: *Client) Error!void {
        if (self.fd >= 0) return;
        const fd = std.c.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        if (fd < 0) return Error.Unavailable;
        errdefer _ = std.c.close(fd);

        var addr: std.posix.sockaddr.un = std.mem.zeroes(std.posix.sockaddr.un);
        addr.family = std.posix.AF.UNIX;
        // Bound the path copy. std.posix.sockaddr.un.path is 108 bytes
        // — anything longer than that won't fit and we treat the
        // sidecar as unreachable.
        if (self.socket_path.len >= addr.path.len) return Error.Unavailable;
        @memcpy(addr.path[0..self.socket_path.len], self.socket_path);
        addr.path[self.socket_path.len] = 0;

        const addr_len: std.posix.socklen_t = @intCast(@sizeOf(@TypeOf(addr)));
        const rc = std.c.connect(fd, @ptrCast(&addr), addr_len);
        if (rc != 0) return Error.Unavailable;

        // Set a recv timeout so reads can't wedge a keystroke
        // indefinitely if the daemon is stuck.
        var tv: std.posix.timeval = .{
            .sec = @intCast(self.read_timeout_ms / 1000),
            .usec = @intCast((self.read_timeout_ms % 1000) * 1000),
        };
        _ = std.c.setsockopt(
            fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            @ptrCast(&tv),
            @sizeOf(@TypeOf(tv)),
        );

        self.fd = fd;
    }

    fn writeAll(self: *Client, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(self.fd, bytes.ptr + off, bytes.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    fn readLine(self: *Client) !usize {
        var off: usize = 0;
        while (off < self.read_buf.len) {
            const n = std.c.read(self.fd, self.read_buf[off..].ptr, self.read_buf.len - off);
            if (n == 0) return error.ConnectionClosed;
            if (n < 0) {
                const e = std.posix.errno(n);
                // EAGAIN is also EWOULDBLOCK on Linux (single
                // value); the recv timeout we set surfaces here.
                if (e == .AGAIN) return error.Timeout;
                return error.ReadFailed;
            }
            const new_off = off + @as(usize, @intCast(n));
            for (off..new_off) |i| {
                if (self.read_buf[i] == '\n') return i;
            }
            off = new_off;
        }
        return error.LineTooLong;
    }
};

fn buildClassifyJson(
    w: *std.Io.Writer,
    id: u64,
    command: []const u8,
    ctx: Client.ClassifyContext,
) !void {
    try w.print("{{\"id\":{d},\"method\":\"classify\",\"command\":\"", .{id});
    try writeEscaped(w, command);
    try w.writeAll("\",\"context\":{");
    var first = true;
    if (ctx.pid) |pid| {
        try w.print("\"pid\":{d}", .{pid});
        first = false;
    }
    if (ctx.shell) |sh| {
        if (!first) try w.writeAll(",");
        try w.writeAll("\"shell\":\"");
        try writeEscaped(w, sh);
        try w.writeAll("\"");
        first = false;
    }
    if (ctx.incognito) {
        if (!first) try w.writeAll(",");
        try w.writeAll("\"incognito\":true");
    }
    try w.writeAll("}}\n");
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x07, 0x0B, 0x0C, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
}

// ---------------------------------------------------------------------------
// Bare-minimum JSON pull parser scoped to the daemon's response
// shape. Robust enough to extract the fields we care about; not
// a general parser. Falls back to `error.DaemonError` on anything
// it doesn't recognise.

/// Pulled out (and `pub`'d) so tests can round-trip without
/// standing up a daemon. Returns the parsed result OR a typed
/// error; the callers up the chain map the errors back into
/// fallback / arming decisions.
pub fn parseClassifyResponse(buf: []const u8) Error!ClassifyResult {
    // Look for "type":"classify" first to reject other envelope shapes.
    if (std.mem.indexOf(u8, buf, "\"type\":\"classify\"") == null) {
        if (std.mem.indexOf(u8, buf, "\"type\":\"error\"") != null) {
            return Error.DaemonError;
        }
        return Error.DaemonError;
    }
    const verdict_s = extractString(buf, "\"verdict\":\"") orelse return Error.DaemonError;
    const verdict = Verdict.fromString(verdict_s) orelse return Error.DaemonError;
    const cat_s = extractString(buf, "\"category\":\"") orelse "none";
    const category = Category.fromString(cat_s) orelse .none;
    const reason = extractString(buf, "\"reason\":\"") orelse "";
    const matched = extractString(buf, "\"matched\":\"") orelse "";
    const confidence = extractFloat(buf, "\"confidence\":") orelse 0.0;
    return .{
        .verdict = verdict,
        .category = category,
        .confidence = confidence,
        .reason = reason,
        .matched = matched,
    };
}

fn extractString(buf: []const u8, prefix: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, buf, prefix) orelse return null;
    const start = at + prefix.len;
    // Find unescaped closing quote.
    var i = start;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\\') {
            i += 1;
            continue;
        }
        if (buf[i] == '"') return buf[start..i];
    }
    return null;
}

fn extractFloat(buf: []const u8, prefix: []const u8) ?f32 {
    const at = std.mem.indexOf(u8, buf, prefix) orelse return null;
    var i = at + prefix.len;
    const start = i;
    while (i < buf.len) : (i += 1) {
        const c = buf[i];
        if (!(c == '-' or c == '+' or c == '.' or (c >= '0' and c <= '9') or c == 'e' or c == 'E')) break;
    }
    return std.fmt.parseFloat(f32, buf[start..i]) catch null;
}

test {
    _ = @import("uds_client_tests.zig");
}
