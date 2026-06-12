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

/// Max trust hashes to request from the daemon in one `trust_list`
/// reply. Bounds the response to the fixed `read_buf` (16 KiB): each
/// hash is ~67 bytes on the wire, so 200 ≈ 13 KiB leaves envelope
/// margin. Over-limit trusted commands re-prompt once this session and
/// re-mirror, so no trust is lost — only the cross-shell pre-seed.
const trust_list_limit = 200;

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
            error.Timeout => {
                // CRITICAL: close the fd on timeout, not just on I/O
                // error. The daemon may still be writing its reply
                // to our buffered fd — if we keep the connection
                // open, the next classify() will read the STALE
                // previous response instead of the fresh one,
                // causing a verdict mismatch (Safe→Block leak in
                // the worst case). Close-and-reconnect is the only
                // safe recovery.
                self.close();
                return Error.Timeout;
            },
            else => {
                self.close();
                return Error.Unavailable;
            },
        };

        // Close on parse failure (malformed / wrong type / id mismatch):
        // these signal a possible stream desync, so the next call must
        // reconnect rather than risk reading a misaligned reply.
        return parseClassifyResponse(self.read_buf[0..line_len], id) catch |e| {
            self.close();
            return e;
        };
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
        try self.readMutationResponse(id);
    }

    /// Parse the daemon's `{"type":"ok"}` vs
    /// `{"type":"error","message":...}` response envelope for
    /// mutation RPCs. Pre-fix the four mutation RPCs
    /// (setThreatLevel, sessionAddTrust, trustAdd,
    /// sessionAddUrlBlock) read the line and silently treated
    /// any well-formed response as success — daemon rejections
    /// (rate limit, auth, malformed input, sandbox /proc blocked)
    /// all landed atty-side as "success". `classifyOrErr` always
    /// parsed; the mutation paths now match.
    fn readMutationResponse(self: *Client, expected_id: u64) Error!void {
        const line_len = self.readLine() catch {
            self.close();
            return Error.Unavailable;
        };
        // Close on parse failure for the same desync reason as the
        // classify path — a malformed reply or id mismatch means the
        // next call should start from a clean reconnect.
        parseMutationResponse(self.read_buf[0..line_len], expected_id) catch |e| {
            self.close();
            return e;
        };
    }

    /// Pure-function variant of `readMutationResponse`'s parse —
    /// split out so tests can exercise the envelope handling
    /// without spinning up a real socket.
    ///
    /// Reads the response structurally (`scanObject`) so a `message`
    /// field that embeds the literal text `"type":"ok"` can never be
    /// mistaken for the envelope's own type, and validates the echoed
    /// `id` so a stale/desynced reply isn't accepted as this request's
    /// answer.
    ///
    ///   - `id` mismatch    → `Error.DaemonError`
    ///   - `"type":"ok"`    → success (no-op return)
    ///   - anything else    → `Error.DaemonError` (the daemon should
    ///                        emit `ok` for a successful mutation;
    ///                        `error` and every other shape are
    ///                        rejections / protocol violations).
    pub fn parseMutationResponse(body: []const u8, expected_id: u64) Error!void {
        const obj = try scanObject(body);
        try checkId(&obj, expected_id);
        const type_s = obj.get("type") orelse return Error.DaemonError;
        if (std.mem.eql(u8, type_s, "ok")) return;
        return Error.DaemonError;
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
        try self.readMutationResponse(id);
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
        try self.readMutationResponse(id);
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
        // Cap the reply to what our fixed `read_buf` (16 KiB) can hold:
        // each hash is ~67 bytes on the wire, so request at most
        // `trust_list_limit` entries (~13 KiB) to avoid LineTooLong on a
        // user with a large persistent trust set. The operator CLI omits
        // the limit and gets the full list.
        (w.print(
            "{{\"id\":{d},\"method\":\"trust_list\",\"limit\":{d}}}\n",
            .{ id, trust_list_limit },
        )) catch return Error.OutOfMemory;
        self.writeAll(self.write_buf[0..w.end]) catch {
            self.close();
            return Error.Unavailable;
        };
        const line_len = self.readLine() catch {
            self.close();
            return Error.Unavailable;
        };
        // Close on any parse/desync failure so the next daemon call
        // reconnects from a clean stream (same rationale as the classify
        // + mutation paths).
        parseTrustListBody(self.read_buf[0..line_len], id, allocator, target) catch |e| {
            self.close();
            return e;
        };
    }

    /// Pure-function body of `trustList` — split out so tests can drive
    /// the envelope + hash-extraction logic without a socket. Structural
    /// parse + id validation, same as the classify path: pre-this-PR
    /// trustList substring-scanned for `"type":"error"` and `"trust":[`,
    /// which (a) silently ignored a desynced reply and (b) could be
    /// confused by those literals inside another field.
    pub fn parseTrustListBody(
        body: []const u8,
        expected_id: u64,
        allocator: std.mem.Allocator,
        target: *trust_cache_mod.TrustCache,
    ) Error!void {
        const obj = try scanObject(body);
        try checkId(&obj, expected_id);
        const type_s = obj.get("type") orelse return Error.DaemonError;
        if (!std.mem.eql(u8, type_s, "trust_list")) return Error.DaemonError;
        // `trust` is the raw `["..",".."]` span; extract each 64-char hex
        // needle from WITHIN it so a hash-shaped string elsewhere can't
        // leak in. Absent array → nothing to seed.
        const arr = obj.get("trust") orelse return;
        var cursor: usize = 0;
        while (cursor < arr.len) {
            const open_quote = std.mem.indexOfScalarPos(u8, arr, cursor, '"') orelse break;
            if (open_quote + 1 + trust_cache_mod.hex_len > arr.len) break;
            const close_quote = open_quote + 1 + trust_cache_mod.hex_len;
            if (arr[close_quote] != '"') break;
            const hex_slice = arr[open_quote + 1 .. close_quote];
            _ = target.add(allocator, hex_slice) catch {};
            cursor = close_quote + 1;
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
        try self.readMutationResponse(id);
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

pub fn buildClassifyJson(
    w: *std.Io.Writer,
    id: u64,
    command: []const u8,
    ctx: Client.ClassifyContext,
) !void {
    try w.print("{{\"id\":{d},\"method\":\"classify\",\"command\":\"", .{id});
    try writeEscaped(w, command);
    try w.writeAll("\",\"context\":{");
    // Field order is incidental — the daemon parses by name
    // (serde_json on the Rust side ignores field order).
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
// Minimal STRUCTURAL JSON object reader, scoped to the daemon's
// one-object-per-line responses. We only need a handful of top-level
// fields, but extracting them by first-substring (`indexOf("\"verdict\":\"")`)
// is safe only by accident of serde's field order plus quote-escaping:
// `reason` / `matched` carry attacker-influenced command text, and
// reordering `ClassifyResult` in protocol.rs would silently let that text
// hijack the verdict. This reader walks the object so only depth-1 keys
// are reported (a key name nested inside a string value or sub-object is
// never confused for the real field), and the parse validates the echoed
// `id` so a stale/desynced reply can't be read as this request's answer.

const max_object_members = 16;

const ObjectMember = struct { key: []const u8, value: []const u8 };

/// Top-level members of one JSON object. String values are returned as
/// the raw inner bytes (escapes intact — callers display/hash them as-is,
/// matching the prior parser); object/array values are the whole bracketed
/// span; scalars are the verbatim token.
const ParsedObject = struct {
    members: [max_object_members]ObjectMember = undefined,
    len: usize = 0,

    fn get(self: *const ParsedObject, key: []const u8) ?[]const u8 {
        for (self.members[0..self.len]) |m| {
            if (std.mem.eql(u8, m.key, key)) return m.value;
        }
        return null;
    }
};

fn skipWs(buf: []const u8, i: usize) usize {
    var j = i;
    while (j < buf.len and (buf[j] == ' ' or buf[j] == '\t' or buf[j] == '\n' or buf[j] == '\r')) : (j += 1) {}
    return j;
}

/// Index of the closing quote of a JSON string whose opening quote is at
/// `open`. Honors `\` escapes. null on an unterminated string.
fn stringEnd(buf: []const u8, open: usize) ?usize {
    var i = open + 1;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\\') {
            i += 1;
            continue;
        }
        if (buf[i] == '"') return i;
    }
    return null;
}

/// Index of the closing bracket matching the `{`/`[` at `open`. Skips
/// nested strings (and their escapes) so brackets inside string values
/// don't unbalance the count, and requires each closer to match its
/// opener's type — `{]` / `[}` are rejected (`null`), not treated as
/// balanced. null on any unbalanced / mismatched / over-deep span.
fn balancedEnd(buf: []const u8, open: usize) ?usize {
    var stack: [16]u8 = undefined;
    var depth: usize = 0;
    var i = open;
    while (i < buf.len) : (i += 1) {
        switch (buf[i]) {
            '"' => i = stringEnd(buf, i) orelse return null,
            '{', '[' => {
                if (depth >= stack.len) return null;
                stack[depth] = if (buf[i] == '{') '}' else ']';
                depth += 1;
            },
            '}', ']' => {
                if (depth == 0 or stack[depth - 1] != buf[i]) return null;
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// True when `s` is a JSON literal that may appear unquoted as a value:
/// `true` / `false` / `null`, or a number. Rejects bare identifiers
/// (`ok`), leading `+`, and `inf`/`nan` (which `parseFloat` would
/// otherwise accept) by requiring the first byte to be `-` or a digit.
fn validScalar(s: []const u8) bool {
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "null")) {
        return true;
    }
    if (s.len == 0) return false;
    if (!(s[0] == '-' or (s[0] >= '0' and s[0] <= '9'))) return false;
    _ = std.fmt.parseFloat(f64, s) catch return false;
    return true;
}

/// True when everything after the closing `}` at `close` is whitespace.
/// A second object or junk appended to the line (`{...} {...}`) is a
/// desync / protocol violation, not a valid single-object response.
fn onlyTrailingWs(buf: []const u8, close: usize) bool {
    return skipWs(buf, close + 1) == buf.len;
}

/// Read a single top-level JSON object's members structurally.
/// `Error.DaemonError` on anything that isn't a well-formed object, that
/// carries more than `max_object_members` fields, or that has trailing
/// non-whitespace bytes after the top-level `}`.
fn scanObject(buf: []const u8) Error!ParsedObject {
    var obj: ParsedObject = .{};
    var i = skipWs(buf, 0);
    if (i >= buf.len or buf[i] != '{') return Error.DaemonError;
    i += 1;
    while (true) {
        i = skipWs(buf, i);
        if (i >= buf.len) return Error.DaemonError;
        if (buf[i] == '}') {
            if (!onlyTrailingWs(buf, i)) return Error.DaemonError;
            return obj;
        }
        if (buf[i] != '"') return Error.DaemonError;
        const key_end = stringEnd(buf, i) orelse return Error.DaemonError;
        const key = buf[i + 1 .. key_end];
        i = skipWs(buf, key_end + 1);
        if (i >= buf.len or buf[i] != ':') return Error.DaemonError;
        i = skipWs(buf, i + 1);
        if (i >= buf.len) return Error.DaemonError;
        var value: []const u8 = undefined;
        switch (buf[i]) {
            '"' => {
                const ve = stringEnd(buf, i) orelse return Error.DaemonError;
                value = buf[i + 1 .. ve];
                i = ve + 1;
            },
            '{', '[' => {
                const ve = balancedEnd(buf, i) orelse return Error.DaemonError;
                value = buf[i .. ve + 1];
                i = ve + 1;
            },
            else => {
                const start = i;
                while (i < buf.len and buf[i] != ',' and buf[i] != '}' and
                    buf[i] != ' ' and buf[i] != '\t' and buf[i] != '\n' and buf[i] != '\r') : (i += 1)
                {}
                if (i == start) return Error.DaemonError;
                value = buf[start..i];
                // A bare (unquoted) value must be a JSON literal — a
                // number (our `id`/`confidence`) or true/false/null.
                // Reject anything else (e.g. `{"type":ok}`) so malformed
                // input can't slip an unquoted token past the parser.
                if (!validScalar(value)) return Error.DaemonError;
            },
        }
        if (obj.len >= max_object_members) return Error.DaemonError;
        // Reject duplicate top-level keys: a security-sensitive message
        // with two `verdict`s (or `id`s) is ambiguous, so refuse it
        // rather than silently picking one.
        if (obj.get(key) != null) return Error.DaemonError;
        obj.members[obj.len] = .{ .key = key, .value = value };
        obj.len += 1;
        i = skipWs(buf, i);
        if (i >= buf.len) return Error.DaemonError;
        if (buf[i] == ',') {
            i += 1;
            continue;
        }
        if (buf[i] == '}') {
            if (!onlyTrailingWs(buf, i)) return Error.DaemonError;
            return obj;
        }
        return Error.DaemonError;
    }
}

/// Reject a reply whose echoed `id` doesn't match the request's. A
/// mismatch means a stale or out-of-order response — never the answer to
/// THIS call, so parsing it would risk a verdict mismatch.
fn checkId(obj: *const ParsedObject, expected_id: u64) Error!void {
    const id_s = obj.get("id") orelse return Error.DaemonError;
    const id = std.fmt.parseInt(u64, id_s, 10) catch return Error.DaemonError;
    if (id != expected_id) return Error.DaemonError;
}

/// Pulled out (and `pub`'d) so tests can round-trip without
/// standing up a daemon. Returns the parsed result OR a typed
/// error; the callers up the chain map the errors back into
/// fallback / arming decisions.
pub fn parseClassifyResponse(buf: []const u8, expected_id: u64) Error!ClassifyResult {
    const obj = try scanObject(buf);
    try checkId(&obj, expected_id);
    const type_s = obj.get("type") orelse return Error.DaemonError;
    if (!std.mem.eql(u8, type_s, "classify")) return Error.DaemonError;
    const verdict_s = obj.get("verdict") orelse return Error.DaemonError;
    const verdict = Verdict.fromString(verdict_s) orelse return Error.DaemonError;
    const cat_s = obj.get("category") orelse "none";
    const category = Category.fromString(cat_s) orelse .none;
    const reason = obj.get("reason") orelse "";
    const matched = obj.get("matched") orelse "";
    const confidence = blk: {
        const c = obj.get("confidence") orelse break :blk @as(f32, 0.0);
        break :blk std.fmt.parseFloat(f32, c) catch 0.0;
    };
    return .{
        .verdict = verdict,
        .category = category,
        .confidence = confidence,
        .reason = reason,
        .matched = matched,
    };
}

test {
    _ = @import("uds_client_tests.zig");
}
