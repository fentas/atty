//! `atty debug anonymize` / `to-cast` — scrub a captured report for sharing.
//! `anonymize` scrubs the RAW report JSON in place (stream data is stored as
//! printable ASCII, so the redaction replacements stay JSON-safe); `to-cast`
//! parses + scrubs decoded bytes into an asciinema cast. This is the sharing
//! path that covers material the ephemeral recorder itself can't exclude
//! (e.g. `subprocess.incognito_targets`).

const std = @import("std");
const replay = @import("debug_replay.zig");

pub const ScrubOpts = struct {
    home: []const u8 = "",
    user: []const u8 = "",
    host: []const u8 = "",
};

// base64/base64url token chars — NOT '=': it's usually an assignment delimiter
// (so `tok=eyJ…` lets the JWT matcher see the `eyJ` boundary), and trailing `==`
// padding is harmless to leave behind.
fn isB64(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '_' or c == '-';
}
fn isLocalChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '%' or c == '+' or c == '-';
}
fn isDomainChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '-';
}

/// local@domain.tld → matched length, else 0.
fn matchEmail(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and isLocalChar(s[i])) i += 1;
    if (i == 0 or i >= s.len or s[i] != '@') return 0;
    const dstart = i + 1;
    var j = dstart;
    while (j < s.len and isDomainChar(s[j])) j += 1;
    const domain = s[dstart..j];
    const dot = std.mem.lastIndexOfScalar(u8, domain, '.') orelse return 0;
    const tld = domain[dot + 1 ..];
    if (tld.len < 2) return 0;
    for (tld) |c| if (!std.ascii.isAlphabetic(c)) return 0;
    return j;
}

/// d.d.d.d (1-3 digits each) → matched length, else 0.
fn matchIpv4(s: []const u8) usize {
    var i: usize = 0;
    var octet: usize = 0;
    while (octet < 4) : (octet += 1) {
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i]) and i - start < 3) i += 1;
        if (i == start) return 0;
        if (octet < 3) {
            if (i >= s.len or s[i] != '.') return 0;
            i += 1;
        }
    }
    // Reject if it runs into a longer dotted-number (e.g. a version 1.2.3.4.5).
    if (i < s.len and (s[i] == '.' or std.ascii.isDigit(s[i]))) return 0;
    return i;
}

/// eyJ… base64url with >=2 dots and >=20 chars (a JWT) → matched length, else 0.
fn matchJwt(s: []const u8) usize {
    if (!std.mem.startsWith(u8, s, "eyJ")) return 0;
    var i: usize = 0;
    var dots: usize = 0;
    while (i < s.len and (isB64(s[i]) or s[i] == '.')) : (i += 1) {
        if (s[i] == '.') dots += 1;
    }
    if (i >= 20 and dots >= 2) return i;
    return 0;
}

/// A run of >=20 base64/hex chars (opaque token) → matched length, else 0. Dots
/// are allowed *inside* the run so a dotted token (or a JWT reached mid-run, e.g.
/// `blob/eyJ….eyJ….sig`) is redacted whole rather than leaking a short segment.
/// Must start on a token char, and a trailing dot is excluded.
fn matchToken(s: []const u8) usize {
    if (s.len == 0 or !isB64(s[0])) return 0;
    var i: usize = 0;
    while (i < s.len and (isB64(s[i]) or s[i] == '.')) i += 1;
    while (i > 0 and s[i - 1] == '.') i -= 1;
    return if (i >= 20) i else 0;
}

/// Scrub `input` in a single pass — literal env replacements (home → `~`, user
/// → `USER`, host → `HOST`) and pattern redaction (email / IPv4 / JWT / token).
///
/// `in_json` selects escape handling. When true (anonymize scrubs the raw report
/// JSON) the scan is escape-aware: a `\` starts a JSON escape (`\n \r \t \" \\
/// \uXXXX`) that is emitted verbatim and skipped whole — so neither an env
/// replacement nor a token redaction can start inside an escape and corrupt it
/// (e.g. a hex USER mangling a unicode escape, or a token after `\n` orphaning the `\`).
/// When false (to-cast scrubs decoded bytes) `\` is an ordinary byte.
pub fn scrub(alloc: std.mem.Allocator, input: []const u8, opts: ScrubOpts, in_json: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) {
        if (in_json and input[i] == '\\') {
            try out.append(alloc, '\\');
            i += 1;
            if (i < input.len) {
                if (input[i] == 'u' and i + 5 <= input.len) {
                    try out.appendSlice(alloc, input[i .. i + 5]); // u + 4 hex
                    i += 5;
                } else {
                    try out.append(alloc, input[i]);
                    i += 1;
                }
            }
            continue;
        }
        const rest = input[i..];
        // Literal env replacements — home first (it usually contains the user);
        // >=2 for home (a path), >=3 for user/host to avoid mangling tiny names.
        if (opts.home.len >= 2 and std.mem.startsWith(u8, rest, opts.home)) {
            try out.appendSlice(alloc, "~");
            i += opts.home.len;
            continue;
        }
        if (opts.user.len >= 3 and std.mem.startsWith(u8, rest, opts.user)) {
            try out.appendSlice(alloc, "USER");
            i += opts.user.len;
            continue;
        }
        if (opts.host.len >= 3 and std.mem.startsWith(u8, rest, opts.host)) {
            try out.appendSlice(alloc, "HOST");
            i += opts.host.len;
            continue;
        }
        const em = matchEmail(rest);
        if (em > 0) {
            try out.appendSlice(alloc, "[EMAIL]");
            i += em;
            continue;
        }
        const ip = matchIpv4(rest);
        if (ip > 0) {
            try out.appendSlice(alloc, "[IP]");
            i += ip;
            continue;
        }
        const jw = matchJwt(rest);
        if (jw > 0) {
            try out.appendSlice(alloc, "[REDACTED]");
            i += jw;
            continue;
        }
        const tk = matchToken(rest);
        if (tk > 0) {
            try out.appendSlice(alloc, "[REDACTED]");
            i += tk;
            continue;
        }
        try out.append(alloc, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

// ── asciinema cast escaping (UTF-8 convention: escape control + " \, pass the
// rest through, matching how the e2e casts are written). ───────────────────
fn escapeByte(alloc: std.mem.Allocator, out: *std.ArrayList(u8), c: u8) !void {
    var b: [8]u8 = undefined;
    // `\u00XX` is 6 bytes into an 8-byte buffer — it cannot fail.
    try out.appendSlice(alloc, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch unreachable);
}

fn castEscape(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => {
                try out.appendSlice(alloc, "\\\"");
                i += 1;
            },
            '\\' => {
                try out.appendSlice(alloc, "\\\\");
                i += 1;
            },
            '\n' => {
                try out.appendSlice(alloc, "\\n");
                i += 1;
            },
            '\r' => {
                try out.appendSlice(alloc, "\\r");
                i += 1;
            },
            '\t' => {
                try out.appendSlice(alloc, "\\t");
                i += 1;
            },
            else => if (c < 0x20) {
                try escapeByte(alloc, out, c);
                i += 1;
            } else if (c < 0x80) {
                try out.append(alloc, c);
                i += 1;
            } else {
                // High byte: pass a whole valid UTF-8 sequence through (a cast is
                // a UTF-8 recording), but escape an invalid byte so the JSON
                // stays parseable.
                const n = std.unicode.utf8ByteSequenceLength(c) catch {
                    try escapeByte(alloc, out, c);
                    i += 1;
                    continue;
                };
                if (i + n <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + n])) {
                    try out.appendSlice(alloc, s[i .. i + n]);
                    i += n;
                } else {
                    try escapeByte(alloc, out, c);
                    i += 1;
                }
            },
        }
    }
}

// ── env + IO helpers ───────────────────────────────────────────────────────
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

fn env(name: [*:0]const u8) []const u8 {
    if (getenv(name)) |v| return std.mem.sliceTo(v, 0);
    return "";
}

/// Default scrub options from the environment.
pub fn envOpts() ScrubOpts {
    return .{ .home = env("HOME"), .user = env("USER"), .host = env("HOSTNAME") };
}

fn writeStdout(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.c.write(std.posix.STDOUT_FILENO, bytes[off..].ptr, bytes.len - off);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return;
        }
        if (rc == 0) return;
        off += @intCast(rc);
    }
}

fn writeStderr(bytes: []const u8) void {
    _ = std.c.write(std.posix.STDERR_FILENO, bytes.ptr, bytes.len);
}

const usage =
    \\usage: atty debug anonymize <report.json>   scrub secrets → stdout
    \\       atty debug to-cast   <report.json> [--stream in|shell|term]
    \\                                           scrubbed asciinema cast → stdout
    \\
    \\  Scrubs $HOME→~, $USER→USER, $HOSTNAME→HOST, emails→[EMAIL], IPv4→[IP],
    \\  and JWT / long token runs → [REDACTED]. Review the output before sharing.
    \\
;

/// CLI for `atty debug anonymize|to-cast …`. `argv` is the tokens after `debug`.
pub fn run(gpa: std.mem.Allocator, argv: []const []const u8) u8 {
    if (argv.len == 0) return 2;
    const verb = argv[0];
    const want_cast = std.mem.eql(u8, verb, "to-cast");
    if (!want_cast and !std.mem.eql(u8, verb, "anonymize")) {
        writeStderr("error: unknown debug verb\n\n");
        writeStderr(usage);
        return 2;
    }

    var path: ?[]const u8 = null;
    var stream: replay.Stream = .term;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--stream")) {
            i += 1;
            if (i >= argv.len) {
                writeStderr("error: --stream needs a value\n");
                return 2;
            }
            stream = replay.Stream.fromName(argv[i]) orelse {
                writeStderr("error: --stream must be in|shell|term\n");
                return 2;
            };
        } else if (std.mem.startsWith(u8, a, "--stream=")) {
            stream = replay.Stream.fromName(a["--stream=".len..]) orelse {
                writeStderr("error: --stream must be in|shell|term\n");
                return 2;
            };
        } else if (a.len > 0 and a[0] == '-') {
            writeStderr("error: unknown flag: ");
            writeStderr(a);
            writeStderr("\n");
            return 2;
        } else if (path == null) {
            path = a;
        } else {
            writeStderr("error: unexpected extra argument\n");
            return 2;
        }
    }
    const report_path = path orelse {
        writeStderr("error: needs a <report.json> path\n\n");
        writeStderr(usage);
        return 2;
    };

    const json = replay.readFile(gpa, report_path) catch {
        writeStderr("error: cannot read report: ");
        writeStderr(report_path);
        writeStderr("\n");
        return 1;
    };
    defer gpa.free(json);

    if (want_cast) return runToCast(gpa, json, stream);
    return runAnonymize(gpa, json);
}

fn runAnonymize(gpa: std.mem.Allocator, json: []const u8) u8 {
    // Scrub the raw JSON directly — replacements are JSON-safe, so the result
    // stays valid JSON while ASCII secrets in the stream data are redacted.
    const scrubbed = scrub(gpa, json, envOpts(), true) catch return 1; // raw JSON → escape-aware
    defer gpa.free(scrubbed);
    writeStdout(scrubbed);
    return 0;
}

fn runToCast(gpa: std.mem.Allocator, json: []const u8, stream: replay.Stream) u8 {
    var report = replay.parse(gpa, json) catch {
        writeStderr("error: not a valid atty debug report\n");
        return 1;
    };
    defer report.deinit();
    const opts = envOpts();

    // Fall back to a sane size when the report didn't capture one (0 → 80x24).
    const width: u16 = if (report.cols > 0) report.cols else 80;
    const height: u16 = if (report.rows > 0) report.rows else 24;

    var hdr: [160]u8 = undefined;
    writeStdout(std.fmt.bufPrint(
        &hdr,
        "{{\"version\":2,\"width\":{d},\"height\":{d},\"timestamp\":0,\"env\":{{\"TERM\":\"xterm-256color\",\"SHELL\":\"/bin/sh\"}}}}\n",
        .{ width, height },
    ) catch return 1);

    // Stream one event at a time — a report may be tens of MB, so don't buffer
    // the whole (escaped, larger) cast in memory.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    for (report.events) |ev| {
        if (ev.stream != stream) continue;
        const clean = scrub(gpa, ev.data, opts, false) catch return 1; // decoded bytes → `\` is literal
        defer gpa.free(clean);
        line.clearRetainingCapacity();
        var pre: [48]u8 = undefined;
        line.appendSlice(gpa, std.fmt.bufPrint(&pre, "[{d:.3}, \"o\", \"", .{ev.t}) catch return 1) catch return 1;
        castEscape(gpa, &line, clean) catch return 1;
        line.appendSlice(gpa, "\"]\n") catch return 1;
        writeStdout(line.items);
    }
    return 0;
}

test {
    _ = @import("debug_anonymize_tests.zig");
}
