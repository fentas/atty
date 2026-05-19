//! Tests for `keymap/csiu.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("csiu.zig");

// Re-binds of pub decls so test bodies stay short.
const csiULen = mod.csiULen;
const csiUToLegacy = mod.csiUToLegacy;
const isCsiU = mod.isCsiU;
const kitty_kbd_pop = mod.kitty_kbd_pop;
const kitty_kbd_push = mod.kitty_kbd_push;
const translateCsiUStream = mod.translateCsiUStream;

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

test "csiUToLegacy: unmodified printable ASCII translates to its literal byte" {
    // xterm.js (VS Code / Windsurf integrated terminals) over-
    // reports under kitty kbd flag 1 and emits CSI-u for printable
    // ASCII too. Without translation, the unmapped-drop path
    // silently swallows Space → typed line never grows. Regression
    // for issue #123.
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, " ", csiUToLegacy("\x1b[32u", &out).?);
    try std.testing.expectEqualSlices(u8, "a", csiUToLegacy("\x1b[97u", &out).?);
    try std.testing.expectEqualSlices(u8, "Z", csiUToLegacy("\x1b[90u", &out).?);
    try std.testing.expectEqualSlices(u8, "5", csiUToLegacy("\x1b[53u", &out).?);
    try std.testing.expectEqualSlices(u8, "!", csiUToLegacy("\x1b[33u", &out).?);
    try std.testing.expectEqualSlices(u8, "~", csiUToLegacy("\x1b[126u", &out).?);
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

test "isModifiedVtCsi: kitty kbd modifier-augmented VT-style sequences" {
    const isModifiedVtCsi = mod.isModifiedVtCsi;
    // Ctrl+Insert / Ctrl+Delete / Ctrl+PageUp etc. — what Windsurf
    // emits for Super+V paste and similar bindings.
    try std.testing.expect(isModifiedVtCsi("\x1b[2;5~")); // Ctrl+Insert
    try std.testing.expect(isModifiedVtCsi("\x1b[3;5~")); // Ctrl+Delete
    try std.testing.expect(isModifiedVtCsi("\x1b[5;5~")); // Ctrl+PageUp
    try std.testing.expect(isModifiedVtCsi("\x1b[5;6~")); // Ctrl+Shift+PageUp
    try std.testing.expect(isModifiedVtCsi("\x1b[15;3~")); // Alt+F5
}

test "isModifiedVtCsi: unmodified VT-style sequences pass through" {
    const isModifiedVtCsi = mod.isModifiedVtCsi;
    // Plain Insert/Delete/PageUp without a modifier param — those
    // are legacy bash-readable shapes; don't drop them.
    try std.testing.expect(!isModifiedVtCsi("\x1b[2~"));
    try std.testing.expect(!isModifiedVtCsi("\x1b[3~"));
    try std.testing.expect(!isModifiedVtCsi("\x1b[5~"));
    try std.testing.expect(!isModifiedVtCsi("\x1b[6~"));
    // Explicit `<n>;1~` (modifier "1" = none) is semantically the
    // unmodified form too — let it pass.
    try std.testing.expect(!isModifiedVtCsi("\x1b[2;1~"));
}

test "isModifiedVtCsi: rejects malformed + non-VT shapes" {
    const isModifiedVtCsi = mod.isModifiedVtCsi;
    try std.testing.expect(!isModifiedVtCsi(""));
    try std.testing.expect(!isModifiedVtCsi("~"));
    try std.testing.expect(!isModifiedVtCsi("\x1b[~"));
    try std.testing.expect(!isModifiedVtCsi("\x1b[2;5u")); // CSI-u, not VT
    try std.testing.expect(!isModifiedVtCsi("\x1b[2;5;3~")); // 2 semicolons
    try std.testing.expect(!isModifiedVtCsi("\x1b[A")); // CSI-letter, no `~`
    try std.testing.expect(!isModifiedVtCsi("hello"));
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
