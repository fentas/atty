//! .e2e script parser.
//!
//! Grammar (one directive per line, # introduces a comment):
//!
//!   cols <int>
//!   rows <int>
//!   timeout_ms <int>            # default 5000, caps wait_for + wait_stable
//!   env KEY=VALUE
//!   spawn <argv...>             # argv0 is the binary (token-split, no quoting yet)
//!                               # if argv0 is "$ATTY", harness substitutes the binary
//!   type "string" [pattern]     # quoted; \n \r \t \\ \" \xNN supported.
//!                               # optional cadence: instant (default) | fast |
//!                               # consistent | slow | irregular | random —
//!                               # paces keystrokes so a recording animates.
//!   send "string" [pattern]     # alias of type (same optional cadence)
//!   key Enter|Tab|Up|Down|Left|Right|Escape|Backspace|^C|^D|^L|^[
//!   click <col> <row>          # left-button SGR-1006 press at 1-based col,row
//!                               # (1..65535; needs config.mouse.enabled)
//!   sleep <ms>
//!   wait_for "substring"        # block until grid contains substring (timeout_ms)
//!   wait_for_count "substring" N  # block until substring appears >= N times
//!                               # (for an async paint whose text also exists
//!                               # elsewhere — e.g. a ghost completing a
//!                               # command still shown in scrollback)
//!   wait_for_absent "substring" # block until substring is GONE (inverse of
//!                               # wait_for — e.g. after a `clear` that must
//!                               # wipe a prior line before the snapshot)
//!   wait_stable [quiet_ms]      # block until output is quiet for quiet_ms
//!                               # (default 150), capped at timeout_ms — a
//!                               # deterministic alternative to sleep before
//!                               # a snapshot
//!   expect_substr "substring"
//!   expect_no_substr "substring"
//!   snapshot <name>             # name must be [A-Za-z0-9_-]+
//!   exit                        # close child stdin, wait for exit
//!   exit_code <int>             # assert final exit code
//!
//! Anything else is a parse error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const typing = @import("typing");

pub const Kind = enum {
    set_cols,
    set_rows,
    set_timeout_ms,
    set_env,
    dsr_reply,
    spawn,
    type_str,
    key,
    click,
    sleep,
    wait_for,
    wait_for_count,
    wait_for_absent,
    wait_stable,
    expect_substr,
    expect_no_substr,
    snapshot,
    exit,
    exit_code,
};

pub const Cmd = struct {
    kind: Kind,
    line: u32,
    // payload — interpretation depends on kind
    int_arg: i64 = 0,
    // for click: col in int_arg, row here
    int_arg2: i64 = 0,
    str_arg: []const u8 = "",
    // for set_env: KEY in str_arg, VALUE here
    str_arg2: []const u8 = "",
    // for spawn: parsed argv tokens
    argv: []const []const u8 = &.{},
};

pub const Script = struct {
    cmds: []Cmd,
    // Backing storage we need to free.
    text: []u8,
    argv_storage: [][]const u8,
    allocator: Allocator,

    pub fn deinit(self: *Script) void {
        self.allocator.free(self.cmds);
        self.allocator.free(self.text);
        self.allocator.free(self.argv_storage);
        self.* = undefined;
    }
};

pub const ParseError = error{
    UnknownDirective,
    BadInteger,
    BadString,
    BadEnv,
    BadSnapshotName,
    EmptyArgv,
    UnknownKey,
    OutOfMemory,
};

pub fn parse(allocator: Allocator, source: []const u8) ParseError!Script {
    const text = try allocator.dupe(u8, source);
    errdefer allocator.free(text);

    var cmds: std.ArrayList(Cmd) = .empty;
    errdefer cmds.deinit(allocator);

    var argv_pool: std.ArrayList([]const u8) = .empty;
    errdefer argv_pool.deinit(allocator);

    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        line_no += 1;
        const line = trim(raw_line);
        if (line.len == 0 or line[0] == '#') continue;

        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const head = line[0..sp];
        const tail = trim(if (sp < line.len) line[sp + 1 ..] else "");

        if (eq(head, "cols")) {
            try cmds.append(allocator, .{ .kind = .set_cols, .line = line_no, .int_arg = try parseInt(tail) });
        } else if (eq(head, "rows")) {
            try cmds.append(allocator, .{ .kind = .set_rows, .line = line_no, .int_arg = try parseInt(tail) });
        } else if (eq(head, "timeout_ms")) {
            try cmds.append(allocator, .{ .kind = .set_timeout_ms, .line = line_no, .int_arg = try parseInt(tail) });
        } else if (eq(head, "env")) {
            const eqp = std.mem.indexOfScalar(u8, tail, '=') orelse return ParseError.BadEnv;
            try cmds.append(allocator, .{
                .kind = .set_env,
                .line = line_no,
                .str_arg = tail[0..eqp],
                .str_arg2 = tail[eqp + 1 ..],
            });
        } else if (eq(head, "spawn")) {
            const argv_start = argv_pool.items.len;
            try tokenizeArgv(allocator, tail, &argv_pool);
            if (argv_pool.items.len == argv_start) return ParseError.EmptyArgv;
            try cmds.append(allocator, .{
                .kind = .spawn,
                .line = line_no,
                .int_arg = @intCast(argv_start),
                .argv = &.{}, // patched after pool stabilises
            });
        } else if (eq(head, "type") or eq(head, "send")) {
            // type "string" [pattern] — split the quoted string from an optional
            // trailing cadence word (default instant = send all at once).
            if (tail.len < 2 or tail[0] != '"') return ParseError.BadString;
            var j: usize = 1;
            while (j < tail.len and tail[j] != '"') : (j += 1) {
                if (tail[j] == '\\' and j + 1 < tail.len) j += 1;
            }
            if (j >= tail.len) return ParseError.BadString;
            const str = try parseString(tail[0 .. j + 1]);
            const rest = std.mem.trim(u8, tail[j + 1 ..], " \t");
            const pat: i64 = if (rest.len == 0)
                @intFromEnum(typing.Pattern.instant)
            else
                @intFromEnum(typing.Pattern.fromName(rest) orelse return ParseError.BadString);
            try cmds.append(allocator, .{ .kind = .type_str, .line = line_no, .str_arg = str, .int_arg = pat });
        } else if (eq(head, "key")) {
            try cmds.append(allocator, .{ .kind = .key, .line = line_no, .str_arg = tail });
        } else if (eq(head, "click")) {
            // click <col> <row> — a left-button SGR-1006 press at 1-based col,row.
            const gap = std.mem.indexOfScalar(u8, tail, ' ') orelse return ParseError.BadInteger;
            const col = try parseInt(trim(tail[0..gap]));
            const row = try parseInt(trim(tail[gap + 1 ..]));
            // SGR-1006 coordinates are 1-based u16 — reject out-of-range so we
            // never emit a sequence the mouse parser would discard.
            if (col < 1 or col > 65535 or row < 1 or row > 65535) return ParseError.BadInteger;
            try cmds.append(allocator, .{ .kind = .click, .line = line_no, .int_arg = col, .int_arg2 = row });
        } else if (eq(head, "dsr_reply")) {
            // dsr_reply on|off — make the harness answer DSR-6n cursor queries
            // like a real terminal. Off by default (the harness is otherwise a
            // pure scraper; replying changes what the child reads and would
            // churn every existing golden). Needed for cursor-query round-trips.
            const on = eq(tail, "on") or eq(tail, "true") or eq(tail, "1");
            if (!on and !(eq(tail, "off") or eq(tail, "false") or eq(tail, "0"))) return ParseError.UnknownDirective;
            try cmds.append(allocator, .{ .kind = .dsr_reply, .line = line_no, .int_arg = if (on) 1 else 0 });
        } else if (eq(head, "sleep")) {
            try cmds.append(allocator, .{ .kind = .sleep, .line = line_no, .int_arg = try parseInt(tail) });
        } else if (eq(head, "wait_for")) {
            try cmds.append(allocator, .{ .kind = .wait_for, .line = line_no, .str_arg = try parseString(tail) });
        } else if (eq(head, "wait_for_count")) {
            // wait_for_count "substr" N — block until substr appears ≥ N times.
            // Deterministic wait for an async paint whose text also exists
            // elsewhere on screen (e.g. a ghost completing a command in
            // scrollback): the count rises only when the new copy lands.
            const close = std.mem.lastIndexOfScalar(u8, tail, '"') orelse return ParseError.BadString;
            const needle = try parseString(tail[0 .. close + 1]);
            const n = try parseInt(trim(tail[close + 1 ..]));
            try cmds.append(allocator, .{ .kind = .wait_for_count, .line = line_no, .str_arg = needle, .int_arg = n });
        } else if (eq(head, "wait_for_absent")) {
            try cmds.append(allocator, .{ .kind = .wait_for_absent, .line = line_no, .str_arg = try parseString(tail) });
        } else if (eq(head, "wait_stable")) {
            // Pump until the screen is quiet for `quiet_ms` (default 150) —
            // a deterministic alternative to `sleep` before a snapshot.
            try cmds.append(allocator, .{ .kind = .wait_stable, .line = line_no, .int_arg = if (tail.len == 0) 150 else try parseInt(tail) });
        } else if (eq(head, "expect_substr")) {
            try cmds.append(allocator, .{ .kind = .expect_substr, .line = line_no, .str_arg = try parseString(tail) });
        } else if (eq(head, "expect_no_substr")) {
            try cmds.append(allocator, .{ .kind = .expect_no_substr, .line = line_no, .str_arg = try parseString(tail) });
        } else if (eq(head, "snapshot")) {
            if (!validSnapshotName(tail)) return ParseError.BadSnapshotName;
            try cmds.append(allocator, .{ .kind = .snapshot, .line = line_no, .str_arg = tail });
        } else if (eq(head, "exit")) {
            try cmds.append(allocator, .{ .kind = .exit, .line = line_no });
        } else if (eq(head, "exit_code")) {
            try cmds.append(allocator, .{ .kind = .exit_code, .line = line_no, .int_arg = try parseInt(tail) });
        } else {
            return ParseError.UnknownDirective;
        }
    }

    const argv_storage = try argv_pool.toOwnedSlice(allocator);
    errdefer allocator.free(argv_storage);

    // Patch spawn entries to point into argv_storage.
    var cmd_items = cmds.items;
    for (cmd_items, 0..) |c, i| {
        if (c.kind != .spawn) continue;
        const start: usize = @intCast(c.int_arg);
        // Find next spawn (or pool end) to bound this slice.
        var end: usize = argv_storage.len;
        for (cmd_items[i + 1 ..]) |later| {
            if (later.kind == .spawn) {
                end = @intCast(later.int_arg);
                break;
            }
        }
        cmd_items[i].argv = argv_storage[start..end];
    }

    const cmds_owned = try cmds.toOwnedSlice(allocator);
    return .{
        .cmds = cmds_owned,
        .text = text,
        .argv_storage = argv_storage,
        .allocator = allocator,
    };
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn parseInt(s: []const u8) ParseError!i64 {
    if (s.len == 0) return ParseError.BadInteger;
    return std.fmt.parseInt(i64, s, 10) catch ParseError.BadInteger;
}

fn validSnapshotName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// Parse a quoted string in place. Modifies `text` to decode escapes,
/// returning a slice into the buffer.
fn parseString(s: []const u8) ParseError![]u8 {
    if (s.len < 2 or s[0] != '"' or s[s.len - 1] != '"') return ParseError.BadString;
    const inner = @constCast(s[1 .. s.len - 1]);
    var w: usize = 0;
    var r: usize = 0;
    while (r < inner.len) : (r += 1) {
        const c = inner[r];
        if (c != '\\') {
            inner[w] = c;
            w += 1;
            continue;
        }
        r += 1;
        if (r >= inner.len) return ParseError.BadString;
        switch (inner[r]) {
            'n' => inner[w] = '\n',
            'r' => inner[w] = '\r',
            't' => inner[w] = '\t',
            '\\' => inner[w] = '\\',
            '"' => inner[w] = '"',
            '0' => inner[w] = 0,
            'e' => inner[w] = 0x1B,
            'x' => {
                if (r + 2 >= inner.len) return ParseError.BadString;
                const hi = hexDigit(inner[r + 1]) orelse return ParseError.BadString;
                const lo = hexDigit(inner[r + 2]) orelse return ParseError.BadString;
                inner[w] = (hi << 4) | lo;
                r += 2;
            },
            else => return ParseError.BadString,
        }
        w += 1;
    }
    return inner[0..w];
}

/// Tokenise `spawn` arguments: whitespace-separated, but `"..."` groups
/// a run of bytes into one token (escapes processed by parseString).
/// Quoted spans are unescaped in place inside the backing buffer.
fn tokenizeArgv(allocator: Allocator, tail: []const u8, pool: *std.ArrayList([]const u8)) ParseError!void {
    var i: usize = 0;
    while (i < tail.len) {
        while (i < tail.len and (tail[i] == ' ' or tail[i] == '\t')) i += 1;
        if (i >= tail.len) break;
        if (tail[i] == '"') {
            const start = i; // include opening quote
            i += 1;
            while (i < tail.len and tail[i] != '"') {
                if (tail[i] == '\\' and i + 1 < tail.len) i += 2 else i += 1;
            }
            if (i >= tail.len) return ParseError.BadString;
            i += 1; // include closing quote
            const decoded = try parseString(tail[start..i]);
            try pool.append(allocator, decoded);
        } else {
            const start = i;
            while (i < tail.len and tail[i] != ' ' and tail[i] != '\t') i += 1;
            try pool.append(allocator, tail[start..i]);
        }
    }
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Translate a symbolic key name into the bytes to send to the PTY.
pub fn keyBytes(name: []const u8) ?[]const u8 {
    if (eq(name, "Enter")) return "\r";
    if (eq(name, "Tab")) return "\t";
    if (eq(name, "Backspace")) return "\x7f";
    if (eq(name, "Escape") or eq(name, "Esc") or eq(name, "^[")) return "\x1b";
    if (eq(name, "Up")) return "\x1b[A";
    if (eq(name, "Down")) return "\x1b[B";
    if (eq(name, "Right")) return "\x1b[C";
    if (eq(name, "Left")) return "\x1b[D";
    if (eq(name, "^C")) return "\x03";
    if (eq(name, "^D")) return "\x04";
    if (eq(name, "^L")) return "\x0c";
    if (eq(name, "^U")) return "\x15";
    if (eq(name, "^W")) return "\x17";
    return null;
}

/// SGR-1006 left-button PRESS at 1-based `col`,`row` — the event modules'
/// `onMouseClick` act on (press only, today). A single sequence so atty's
/// intercept consumes the whole read cleanly; a trailing release in the same
/// read would be parsed-past and leak to the shell. Pure so the byte shape is
/// unit-testable; `buf` needs ~18 bytes for u16-bounded coords.
pub fn clickBytes(col: i64, row: i64, buf: []u8) std.fmt.BufPrintError![]const u8 {
    return std.fmt.bufPrint(buf, "\x1b[<0;{d};{d}M", .{ col, row });
}

// ─── tests ────────────────────────────────────────────────────────────────

// ===========================================================================
// Tests — extracted to `dsl_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("dsl_tests.zig");
}
