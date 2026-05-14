//! Keymap — kitty-keyboard CSI-u encode/decode helpers.
//!
//! atty pushes the kitty keyboard disambiguate flag at startup so the
//! terminal sends distinct CSI-u sequences for keys that would
//! otherwise collide with control bytes (Ctrl+Shift+I vs Tab,
//! Ctrl+R vs DC2 in a way bash readline misreads, …). Bash itself
//! does NOT speak the protocol, so this file's translators run
//! between the terminal and the shell: detect CSI-u shapes, fold
//! them back to legacy bytes when possible, drop the ones that
//! don't have a legacy form (so they don't leak as mojibake into
//! the password reader / readline).
//!
//! Lives separately from `../keymap.zig` so the public Action +
//! Binding types stay uncrowded by ~150 lines of byte twiddling.

const std = @import("std");

/// Kitty keyboard protocol — disambiguate-flag push/pop bytes. atty
/// emits the push on startup (so terminals like Ghostty/kitty/foot
/// send CSI-u for keys that would otherwise collide with control
/// bytes — Ctrl+Shift+I vs Tab, …) and the pop on exit. Terminals
/// that don't speak the protocol silently ignore these bytes.
pub const kitty_kbd_push = "\x1B[>1u";
pub const kitty_kbd_pop = "\x1B[<u";

/// Translate a kitty-keyboard CSI-u sequence back to its legacy
/// single-byte encoding (or short escape sequence), if one exists.
///
/// **Why this is critical.** With the kitty kbd disambiguate flag
/// (`\x1b[>1u`) pushed, terminals like Ghostty emit CSI-u for keys
/// that previously had a single-byte encoding:
///
///     Ctrl+C           →  \x1b[99;5u    (legacy: \x03)
///     Ctrl+R           →  \x1b[114;5u   (legacy: \x12)
///     Esc              →  \x1b[27u      (legacy: \x1b)
///     Tab              →  \x1b[9u       (legacy: \t)
///     Enter            →  \x1b[13u      (legacy: \r)
///     Backspace        →  \x1b[127u     (legacy: \x7f)
///
/// The shell (bash readline) expects the legacy form — it does NOT
/// speak the kitty kbd protocol. So the proxy must translate before
/// forwarding. Without translation, Ctrl+C in a Ghostty-on-atty
/// session does nothing: atty drops the unmapped CSI-u, no bytes
/// reach the shell.
///
/// Returns null when:
///   - `input` isn't a CSI-u sequence at all (caller forwards as-is)
///   - it's CSI-u but the key has no legacy form (Ctrl+9, F-keys,
///     Ctrl+Shift+Right, Ctrl+Alt+letter, …) — caller drops to
///     avoid mojibake echo. Note that **Shift+Tab IS translated**
///     to its legacy `\x1b[Z` form by the kc==9+shift branch below.
///
/// `out` is caller-owned scratch storage for the translated bytes.
/// A 4-byte buffer is enough for every translation this function
/// produces today.
pub fn csiUToLegacy(input: []const u8, out: []u8) ?[]const u8 {
    if (!isCsiU(input)) return null;

    // Body = the digits/semicolons between `ESC [` and `u`.
    const body = input[2 .. input.len - 1];

    // Format: `<keycode>[ ; <modifier> [ : <text-as-codepoints> ] ]`.
    // The `:` form appears under the "Report associated text" flag,
    // which we don't push — but we tolerate it defensively.
    var kc: u32 = 0;
    var mod: u32 = 1;
    if (std.mem.indexOfScalar(u8, body, ';')) |semi| {
        kc = std.fmt.parseInt(u32, body[0..semi], 10) catch return null;
        const after = body[semi + 1 ..];
        const mod_end = std.mem.indexOfScalar(u8, after, ':') orelse after.len;
        mod = std.fmt.parseInt(u32, after[0..mod_end], 10) catch return null;
    } else {
        kc = std.fmt.parseInt(u32, body, 10) catch return null;
    }

    // Modifier encoding (kitty kbd): 1=none, 2=shift, 3=alt, 4=alt+shift,
    // 5=ctrl, 6=ctrl+shift, 7=ctrl+alt, 8=ctrl+alt+shift.
    const has_ctrl = (mod == 5 or mod == 6 or mod == 7 or mod == 8);
    const has_shift = (mod == 2 or mod == 4 or mod == 6 or mod == 8);
    const has_alt = (mod == 3 or mod == 4 or mod == 7 or mod == 8);

    // --- Unmodified named keys → their legacy single bytes ---------------
    if (mod == 1 or mod == 0) switch (kc) {
        9 => return writeOne(out, '\t'),
        13 => return writeOne(out, '\r'),
        27 => return writeOne(out, 0x1b),
        127 => return writeOne(out, 0x7f),
        else => {},
    };

    // --- Ctrl + lowercase letter → 0x01..0x1A control byte ---------------
    // Bash readline's default key bindings live here:
    //   Ctrl+A = beginning-of-line, Ctrl+C = abort,
    //   Ctrl+D = EOF/exit, Ctrl+E = end-of-line,
    //   Ctrl+R = reverse-i-search, Ctrl+U = unix-line-discard, …
    if (has_ctrl and !has_alt and kc >= 'a' and kc <= 'z') {
        return writeOne(out, @intCast(kc - 'a' + 1));
    }

    // --- Alt + ASCII char → ESC <char> (xterm metaSendsEscape) -----------
    if (has_alt and !has_ctrl and !has_shift and kc < 128) {
        if (out.len < 2) return null;
        out[0] = 0x1b;
        out[1] = @intCast(kc);
        return out[0..2];
    }

    // Shift+Tab has a well-known legacy form. Other modifier-bearing
    // keys (Ctrl+Shift+letter for example) intentionally fall through
    // to null — those are atty's binding territory (Ctrl+Shift+I,
    // Ctrl+Shift+D) and a matching binding handles them at the
    // call-site before this translator runs.
    if (kc == 9 and has_shift and !has_ctrl and !has_alt) {
        return writeBytes(out, "\x1b[Z");
    }

    return null;
}

fn writeOne(out: []u8, b: u8) ?[]const u8 {
    if (out.len < 1) return null;
    out[0] = b;
    return out[0..1];
}

fn writeBytes(out: []u8, s: []const u8) ?[]const u8 {
    if (out.len < s.len) return null;
    @memcpy(out[0..s.len], s);
    return out[0..s.len];
}

/// True if `input` is a kitty-keyboard CSI-u sequence: `ESC [`
/// followed by digit / `;` / `:` parameters, terminated by `u`.
/// Used by the proxy to drop unmapped kitty-protocol keys so they
/// don't reach the shell as mojibake when the protocol is enabled.
pub fn isCsiU(input: []const u8) bool {
    if (input.len < 4) return false; // min: `ESC [ <digit> u`
    if (input[0] != 0x1B or input[1] != '[') return false;
    if (input[input.len - 1] != 'u') return false;
    for (input[2 .. input.len - 1]) |b| {
        switch (b) {
            '0'...'9', ';', ':' => {},
            else => return false,
        }
    }
    return true;
}

/// If `bytes` begins with a well-formed CSI-u sequence, return its
/// length (including the `u` terminator). Returns null otherwise.
///
/// Used by the byte-stream translator below to peel CSI-u sequences
/// off the front of a multi-keystroke `read()` buffer. `isCsiU`
/// validates the WHOLE slice — this finds the *boundary* so the
/// caller can split mixed input (`password<Enter><Ctrl+C>` arriving
/// as one read in raw mode, paste with embedded protocol sequences,
/// …).
pub fn csiULen(bytes: []const u8) ?usize {
    if (bytes.len < 4) return null;
    if (bytes[0] != 0x1B or bytes[1] != '[') return null;
    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        switch (bytes[i]) {
            '0'...'9', ';', ':' => {},
            'u' => return i + 1,
            else => return null,
        }
    }
    return null; // ran out of bytes before terminator → not yet a CSI-u
}

/// Byte-stream CSI-u translator for the password-redaction fast path
/// (and any other site where a multi-key `read()` may carry an
/// embedded CSI-u sequence).
///
/// Walks `input` front-to-back. When a CSI-u sequence is detected at
/// the current cursor, run `csiUToLegacy` against it and write the
/// translated bytes to `writer` (or drop them, if the key has no
/// legacy form — e.g. Ctrl+9, F-keys). Non-CSI-u runs are written
/// verbatim in one chunk per run, so the common case (`password\r`
/// arriving as a single `read()`) is a single write.
///
/// `writer` is a Writer; in the proxy this points at pty.master via
/// a thin shim. Returns the writer's error type unchanged so the
/// caller can `try` it directly.
pub fn translateCsiUStream(
    input: []const u8,
    enabled: bool,
    writer: anytype,
) !void {
    if (!enabled) {
        try writer.writeAll(input);
        return;
    }
    var i: usize = 0;
    var run_start: usize = 0;
    while (i < input.len) {
        if (input[i] == 0x1B and i + 1 < input.len and input[i + 1] == '[') {
            if (csiULen(input[i..])) |seq_len| {
                if (run_start < i) try writer.writeAll(input[run_start..i]);
                var legacy_buf: [8]u8 = undefined;
                if (csiUToLegacy(input[i .. i + seq_len], &legacy_buf)) |legacy| {
                    try writer.writeAll(legacy);
                } // else: drop (no legacy form — Ctrl+9, F-keys, …)
                i += seq_len;
                run_start = i;
                continue;
            }
        }
        i += 1;
    }
    if (run_start < input.len) try writer.writeAll(input[run_start..]);
}

test "csiUToLegacy: Ctrl+letter combos become their 0x01..0x1A control byte" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "\x01", csiUToLegacy("\x1b[97;5u", &out).?);
    try std.testing.expectEqualSlices(u8, "\x03", csiUToLegacy("\x1b[99;5u", &out).?);
    try std.testing.expectEqualSlices(u8, "\x04", csiUToLegacy("\x1b[100;5u", &out).?);
    try std.testing.expectEqualSlices(u8, "\x05", csiUToLegacy("\x1b[101;5u", &out).?);
    try std.testing.expectEqualSlices(u8, "\x12", csiUToLegacy("\x1b[114;5u", &out).?);
    try std.testing.expectEqualSlices(u8, "\x15", csiUToLegacy("\x1b[117;5u", &out).?);
    try std.testing.expectEqualSlices(u8, "\x1a", csiUToLegacy("\x1b[122;5u", &out).?);
}

test "csiUToLegacy: named keys with legacy single-byte encodings" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "\t", csiUToLegacy("\x1b[9u", &out).?);
    try std.testing.expectEqualSlices(u8, "\r", csiUToLegacy("\x1b[13u", &out).?);
    try std.testing.expectEqualSlices(u8, "\x1b", csiUToLegacy("\x1b[27u", &out).?);
    try std.testing.expectEqualSlices(u8, "\x7f", csiUToLegacy("\x1b[127u", &out).?);
}

test "csiUToLegacy: Shift+Tab → \\x1b[Z" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "\x1b[Z", csiUToLegacy("\x1b[9;2u", &out).?);
}

test "csiUToLegacy: Alt+letter → ESC + letter (xterm metaSendsEscape)" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "\x1bf", csiUToLegacy("\x1b[102;3u", &out).?);
}

test "csiUToLegacy: keys with no legacy form return null (caller drops)" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), csiUToLegacy("\x1b[57;5u", &out));
    try std.testing.expectEqual(@as(?[]const u8, null), csiUToLegacy("\x1b[99;7u", &out));
}

test "csiUToLegacy: Ctrl+Shift+letter folds to the same control byte as Ctrl+letter" {
    // Rationale: in classic terminal mode, Ctrl+Shift+C and Ctrl+C
    // both send 0x03 — the shift bit doesn't propagate through a
    // control-byte encoding. Under kitty kbd they get distinct CSI-u
    // sequences, but if a user's binding doesn't catch them the
    // shell should still see the same bytes a non-kitty terminal
    // would have produced. Note: the proxy's binding-match runs
    // BEFORE this translator, so atty's own Ctrl+Shift+I /
    // Ctrl+Shift+D bindings still take precedence — this case only
    // triggers when no binding matched.
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "\x03", csiUToLegacy("\x1b[99;6u", &out).?);
    try std.testing.expectEqualSlices(u8, "\x1a", csiUToLegacy("\x1b[122;6u", &out).?);
}

test "csiUToLegacy: non-CSI-u input returns null without touching `out`" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), csiUToLegacy("\x03", &out));
    try std.testing.expectEqual(@as(?[]const u8, null), csiUToLegacy("\x1b[C", &out));
    try std.testing.expectEqual(@as(?[]const u8, null), csiUToLegacy("abc", &out));
}

test "csiUToLegacy: malformed CSI-u (non-numeric) returns null safely" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), csiUToLegacy("\x1b[abc;5u", &out));
    try std.testing.expectEqual(@as(?[]const u8, null), csiUToLegacy("\x1b[99;xyu", &out));
}

test "isCsiU recognises kitty-protocol CSI-u shapes" {
    try std.testing.expect(isCsiU("\x1B[105;6u"));
    try std.testing.expect(isCsiU("\x1B[57;5u"));
    try std.testing.expect(isCsiU("\x1B[27u"));
    try std.testing.expect(isCsiU("\x1B[1;5:2u"));
}

test "isCsiU rejects non-CSI-u sequences" {
    try std.testing.expect(!isCsiU("\x1B[C"));
    try std.testing.expect(!isCsiU("\x1B[1;5C"));
    try std.testing.expect(!isCsiU("\t"));
    try std.testing.expect(!isCsiU("\x1B[2J"));
    try std.testing.expect(!isCsiU("u"));
    try std.testing.expect(!isCsiU("\x1B[abc;6u"));
}

test "isCsiU lets bare Ctrl+C through (not a CSI-u sequence)" {
    // The CSI-u drop is the second gate after match — if a key
    // doesn't match any binding AND looks like CSI-u, we drop it.
    // Bare \x03 isn't CSI-u shaped, so isCsiU returns false and
    // the byte falls through to the pty.master write.
    try std.testing.expect(!isCsiU("\x03"));
    try std.testing.expect(!isCsiU("\x04"));
}

test "csiULen finds the boundary of an embedded CSI-u sequence" {
    try std.testing.expectEqual(@as(?usize, 7), csiULen("\x1b[99;5u"));
    try std.testing.expectEqual(@as(?usize, 7), csiULen("\x1b[99;5utrailing"));
    try std.testing.expectEqual(@as(?usize, 4), csiULen("\x1b[9u"));
    try std.testing.expectEqual(@as(?usize, null), csiULen("\x1b[99;5"));
    try std.testing.expectEqual(@as(?usize, null), csiULen("\x1b[Cdef"));
    try std.testing.expectEqual(@as(?usize, null), csiULen("abc"));
    try std.testing.expectEqual(@as(?usize, null), csiULen("\x1b["));
}

const TestWriter = struct {
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }
};

test "translateCsiUStream: pure CSI-u → legacy bytes (single-key fast path)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try translateCsiUStream("\x1b[99;5u", true, TestWriter{ .buf = &buf, .allocator = std.testing.allocator });
    try std.testing.expectEqualSlices(u8, "\x03", buf.items);
}

test "translateCsiUStream: non-CSI-u byte stream passes through unchanged" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try translateCsiUStream("hunter2\r", true, TestWriter{ .buf = &buf, .allocator = std.testing.allocator });
    try std.testing.expectEqualSlices(u8, "hunter2\r", buf.items);
}

test "translateCsiUStream: mixed run — password chars + embedded Ctrl+C" {
    // Regression scenario (Copilot review on PR #9, src/proxy.zig:390):
    // a single `read()` returned `pass\x1b[99;5u\r` (paste-style or
    // burst typing). The earlier fast-path checked `isCsiU(input)`
    // on the WHOLE slice — failed because it wasn't pure CSI-u — and
    // forwarded the raw kitty-protocol bytes to the password reader.
    // The stream translator splits the input into runs and translates
    // each CSI-u sequence individually.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try translateCsiUStream("pass\x1b[99;5u\r", true, TestWriter{ .buf = &buf, .allocator = std.testing.allocator });
    try std.testing.expectEqualSlices(u8, "pass\x03\r", buf.items);
}

test "translateCsiUStream: two CSI-u sequences back-to-back" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try translateCsiUStream("\x1b[117;5u\x1b[99;5u", true, TestWriter{ .buf = &buf, .allocator = std.testing.allocator });
    try std.testing.expectEqualSlices(u8, "\x15\x03", buf.items);
}

test "translateCsiUStream: CSI-u with no legacy form is dropped" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try translateCsiUStream("ab\x1b[57;5ucd", true, TestWriter{ .buf = &buf, .allocator = std.testing.allocator });
    try std.testing.expectEqualSlices(u8, "abcd", buf.items);
}

test "translateCsiUStream: disabled → bytes pass through unchanged" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try translateCsiUStream("\x1b[99;5u-but-disabled", false, TestWriter{ .buf = &buf, .allocator = std.testing.allocator });
    try std.testing.expectEqualSlices(u8, "\x1b[99;5u-but-disabled", buf.items);
}

test "translateCsiUStream: unterminated CSI-u at end is forwarded verbatim" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try translateCsiUStream("ok\x1b[99;5", true, TestWriter{ .buf = &buf, .allocator = std.testing.allocator });
    try std.testing.expectEqualSlices(u8, "ok\x1b[99;5", buf.items);
}

test "translateCsiUStream: bare ESC (no `[`) is forwarded as-is" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try translateCsiUStream("\x1bf", true, TestWriter{ .buf = &buf, .allocator = std.testing.allocator });
    try std.testing.expectEqualSlices(u8, "\x1bf", buf.items);
}
