//! Keymap — proxy-level key bindings, dwm `keys[]` style.
//!
//! The terminal sends one or more bytes per keypress (`\x1b[C` for
//! right-arrow, `\x06` for Ctrl-F, …). When the proxy reads stdin and
//! the bytes match a `Binding.bytes`, the corresponding `Action` runs
//! instead of the original keystroke being forwarded to the shell.
//!
//! atty defines the closed set of `Action`s; user configs assemble
//! the bindings list. Modifier keys are baked into the byte sequence
//! itself — `\x1b[1;5C` is Ctrl-Right, etc. — so there's no separate
//! modifier field to bookkeep.
//!
//! Why this lives at the proxy and not on a module: the trigger ("this
//! key was pressed") and the payload ("the ghost text from whichever
//! module won the gather race") are decoupled. A single accept key
//! shouldn't have to know whether atuin or history provided the
//! suggestion.

const std = @import("std");

pub const Action = enum {
    /// Replace the keystroke with the bytes of the currently-visible
    /// ghost suggestion (i.e. accept fish-style autosuggestion).
    /// No-op when no ghost is showing or the line is in an uncertain
    /// state.
    ghost_accept,
    /// Flip incognito mode on/off. While on: line commits aren't
    /// recorded (no atuin / history writes); the status bar prepends
    /// a 🔒 segment; a one-line stderr toast announces the flip.
    incognito_toggle,
    /// Delete every history entry that matches the current line.
    /// Fires `deleteHistoryMatch` on every module that implements it
    /// (today: history; atuin's CLI doesn't expose match-delete in a
    /// portable way), then sends Ctrl+U to the shell so the prompt
    /// clears, and flashes a transient status-bar message.
    delete_history_match,
};

pub const Binding = struct {
    /// The raw bytes the terminal emits for the key. Matched against
    /// the entire stdin read — terminals send most named keys as a
    /// single read, but the match is byte-exact so chunked reads (rare)
    /// won't trigger.
    bytes: []const u8,
    action: Action,
};

/// Comptime name → byte-sequence lookup, so user configs read like
/// `key("Right")` instead of `"\x1b[C"`. Unknown names error at compile
/// time, so typos break the build rather than silently no-op.
///
/// Recognised forms:
///
///   - **Named keys:** `Right`, `Left`, `Up`, `Down`, `Home`, `End`,
///     `PageUp`, `PageDown`, `Insert`, `Delete`, `Tab`, `Enter`,
///     `Backspace`, `Esc`, `Shift+Tab`, `Ctrl+Right`, `Ctrl+Left`,
///     `Ctrl+Up`, `Ctrl+Down`, `F1`–`F12`.
///   - **Ctrl + letter:** `Ctrl+A` .. `Ctrl+Z` (case-insensitive) →
///     ASCII 0x01..0x1A.
///   - **Alt + single ASCII char:** `Alt+f` → `ESC f`. xterm-style.
///
/// Not handled (because terminals don't have a portable sequence):
///
///   - `Super+…` / `Win+…` / `Cmd+…` — most terminals send nothing.
///     Some (kitty/foot/Ghostty) emit kitty-keyboard-protocol bytes
///     when the protocol is negotiated; not encodable as a static
///     constant.
///   - `Ctrl+Tab`, `Ctrl+Enter`, `Ctrl+Backspace` — typically
///     indistinguishable from the unmodified key.
///   - **Chord sequences** (Emacs `Ctrl+X Ctrl+S`) — would need a
///     stateful matcher; the current key handler matches one read.
///
/// For any of these, you can still set `.bytes` to a raw byte literal
/// if your terminal does emit something distinct.
pub fn key(comptime name: []const u8) []const u8 {
    // Plain named keys.
    if (comptime std.mem.eql(u8, name, "Right")) return "\x1b[C";
    if (comptime std.mem.eql(u8, name, "Left")) return "\x1b[D";
    if (comptime std.mem.eql(u8, name, "Up")) return "\x1b[A";
    if (comptime std.mem.eql(u8, name, "Down")) return "\x1b[B";
    if (comptime std.mem.eql(u8, name, "Home")) return "\x1b[H";
    if (comptime std.mem.eql(u8, name, "End")) return "\x1b[F";
    if (comptime std.mem.eql(u8, name, "PageUp")) return "\x1b[5~";
    if (comptime std.mem.eql(u8, name, "PageDown")) return "\x1b[6~";
    if (comptime std.mem.eql(u8, name, "Insert")) return "\x1b[2~";
    if (comptime std.mem.eql(u8, name, "Delete")) return "\x1b[3~";
    if (comptime std.mem.eql(u8, name, "Tab")) return "\t";
    if (comptime std.mem.eql(u8, name, "Enter")) return "\r";
    if (comptime std.mem.eql(u8, name, "Backspace")) return "\x7f";
    if (comptime std.mem.eql(u8, name, "Esc")) return "\x1b";

    // Modifier-tagged variants — xterm CSI-1 form: `ESC [ 1 ; <mod> X`
    // where mod = 1+Shift +2*Alt +4*Ctrl (Meta=8 is rare, Super has no
    // portable encoding — most terminals send nothing for it).
    if (comptime std.mem.eql(u8, name, "Shift+Tab")) return "\x1b[Z";

    if (comptime std.mem.eql(u8, name, "Shift+Right")) return "\x1b[1;2C";
    if (comptime std.mem.eql(u8, name, "Shift+Left")) return "\x1b[1;2D";
    if (comptime std.mem.eql(u8, name, "Shift+Up")) return "\x1b[1;2A";
    if (comptime std.mem.eql(u8, name, "Shift+Down")) return "\x1b[1;2B";
    if (comptime std.mem.eql(u8, name, "Shift+Home")) return "\x1b[1;2H";
    if (comptime std.mem.eql(u8, name, "Shift+End")) return "\x1b[1;2F";

    if (comptime std.mem.eql(u8, name, "Alt+Right")) return "\x1b[1;3C";
    if (comptime std.mem.eql(u8, name, "Alt+Left")) return "\x1b[1;3D";
    if (comptime std.mem.eql(u8, name, "Alt+Up")) return "\x1b[1;3A";
    if (comptime std.mem.eql(u8, name, "Alt+Down")) return "\x1b[1;3B";
    if (comptime std.mem.eql(u8, name, "Alt+Home")) return "\x1b[1;3H";
    if (comptime std.mem.eql(u8, name, "Alt+End")) return "\x1b[1;3F";

    if (comptime std.mem.eql(u8, name, "Ctrl+Right")) return "\x1b[1;5C";
    if (comptime std.mem.eql(u8, name, "Ctrl+Left")) return "\x1b[1;5D";
    if (comptime std.mem.eql(u8, name, "Ctrl+Up")) return "\x1b[1;5A";
    if (comptime std.mem.eql(u8, name, "Ctrl+Down")) return "\x1b[1;5B";
    if (comptime std.mem.eql(u8, name, "Ctrl+Home")) return "\x1b[1;5H";
    if (comptime std.mem.eql(u8, name, "Ctrl+End")) return "\x1b[1;5F";

    if (comptime std.mem.eql(u8, name, "Ctrl+Shift+Right")) return "\x1b[1;6C";
    if (comptime std.mem.eql(u8, name, "Ctrl+Shift+Left")) return "\x1b[1;6D";
    if (comptime std.mem.eql(u8, name, "Ctrl+Shift+Up")) return "\x1b[1;6A";
    if (comptime std.mem.eql(u8, name, "Ctrl+Shift+Down")) return "\x1b[1;6B";

    if (comptime std.mem.eql(u8, name, "Ctrl+Alt+Right")) return "\x1b[1;7C";
    if (comptime std.mem.eql(u8, name, "Ctrl+Alt+Left")) return "\x1b[1;7D";
    if (comptime std.mem.eql(u8, name, "Ctrl+Alt+Up")) return "\x1b[1;7A";
    if (comptime std.mem.eql(u8, name, "Ctrl+Alt+Down")) return "\x1b[1;7B";

    // Function keys.
    if (comptime std.mem.eql(u8, name, "F1")) return "\x1bOP";
    if (comptime std.mem.eql(u8, name, "F2")) return "\x1bOQ";
    if (comptime std.mem.eql(u8, name, "F3")) return "\x1bOR";
    if (comptime std.mem.eql(u8, name, "F4")) return "\x1bOS";
    if (comptime std.mem.eql(u8, name, "F5")) return "\x1b[15~";
    if (comptime std.mem.eql(u8, name, "F6")) return "\x1b[17~";
    if (comptime std.mem.eql(u8, name, "F7")) return "\x1b[18~";
    if (comptime std.mem.eql(u8, name, "F8")) return "\x1b[19~";
    if (comptime std.mem.eql(u8, name, "F9")) return "\x1b[20~";
    if (comptime std.mem.eql(u8, name, "F10")) return "\x1b[21~";
    if (comptime std.mem.eql(u8, name, "F11")) return "\x1b[23~";
    if (comptime std.mem.eql(u8, name, "F12")) return "\x1b[24~";

    // Ctrl + ASCII letter — comptime fold to control byte.
    if (comptime name.len == 6 and std.mem.eql(u8, name[0..5], "Ctrl+")) {
        const c: u8 = name[5];
        if (comptime (c >= 'a' and c <= 'z')) return comptime &[_]u8{c - 'a' + 1};
        if (comptime (c >= 'A' and c <= 'Z')) return comptime &[_]u8{c - 'A' + 1};
    }

    // Alt + single ASCII char → ESC + char (xterm metaSendsEscape).
    if (comptime name.len == 5 and std.mem.eql(u8, name[0..4], "Alt+")) {
        return comptime "\x1b" ++ name[4..5];
    }

    // Ctrl+Shift+<letter> → kitty-keyboard `CSI <code> ; 6 u` form.
    // This is the *disambiguated* encoding for Ctrl+letter combos that
    // would otherwise collide with control bytes (Ctrl+Shift+I vs Tab,
    // Ctrl+Shift+M vs Enter, …). Requires the terminal to be in kitty
    // keyboard protocol mode — proxy.zig sends `\x1b[>1u` on startup
    // when `enable_kitty_keyboard` is true (default).
    if (comptime name.len == 12 and std.mem.eql(u8, name[0..11], "Ctrl+Shift+")) {
        const c: u8 = name[11];
        const code: u8 = if (c >= 'a' and c <= 'z') c else if (c >= 'A' and c <= 'Z') c + 32 else 0;
        if (comptime code != 0) {
            return comptime std.fmt.comptimePrint("\x1B[{d};6u", .{code});
        }
    }

    @compileError("unknown key name: '" ++ name ++ "' — see src/keymap.zig");
}

test "key resolves named keys" {
    try std.testing.expectEqualStrings("\x1b[C", key("Right"));
    try std.testing.expectEqualStrings("\x1b[F", key("End"));
    try std.testing.expectEqualStrings("\t", key("Tab"));
    try std.testing.expectEqualStrings("\x1b[Z", key("Shift+Tab"));
}

test "key resolves multi-modifier arrows" {
    try std.testing.expectEqualStrings("\x1b[1;5C", key("Ctrl+Right"));
    try std.testing.expectEqualStrings("\x1b[1;2D", key("Shift+Left"));
    try std.testing.expectEqualStrings("\x1b[1;6A", key("Ctrl+Shift+Up"));
    try std.testing.expectEqualStrings("\x1b[1;7B", key("Ctrl+Alt+Down"));
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

/// Linear scan over `bindings` looking for an exact byte match against
/// `input`. Returns the bound action, or null when no binding matches
/// (or the input is empty / a binding has an empty `.bytes`). Pulled
/// out of the proxy loop so the dispatch logic is testable without a
/// PTY fixture.
pub fn match(bindings: []const Binding, input: []const u8) ?Action {
    if (input.len == 0) return null;
    for (bindings) |bind| {
        if (bind.bytes.len == 0) continue;
        if (std.mem.eql(u8, input, bind.bytes)) return bind.action;
    }
    return null;
}

test "match returns null on empty input" {
    const bs = [_]Binding{.{ .bytes = "\x06", .action = .ghost_accept }};
    try std.testing.expectEqual(@as(?Action, null), match(&bs, ""));
}

test "match skips bindings with empty .bytes (so a half-built config can't always-fire)" {
    const bs = [_]Binding{
        .{ .bytes = "", .action = .ghost_accept },
        .{ .bytes = "\x06", .action = .ghost_accept },
    };
    try std.testing.expectEqual(@as(?Action, null), match(&bs, ""));
    try std.testing.expectEqual(Action.ghost_accept, match(&bs, "\x06").?);
}

test "match resolves a real binding by exact byte sequence" {
    const bs = [_]Binding{
        .{ .bytes = key("Right"), .action = .ghost_accept },
        .{ .bytes = key("Ctrl+Shift+I"), .action = .incognito_toggle },
        .{ .bytes = key("Ctrl+Shift+D"), .action = .delete_history_match },
    };
    try std.testing.expectEqual(Action.ghost_accept, match(&bs, "\x1b[C").?);
    try std.testing.expectEqual(Action.incognito_toggle, match(&bs, "\x1B[105;6u").?);
    try std.testing.expectEqual(Action.delete_history_match, match(&bs, "\x1B[100;6u").?);
    try std.testing.expectEqual(@as(?Action, null), match(&bs, "\x1b[A"));
}

test "match requires byte-exact equality (chunked reads don't trigger)" {
    const bs = [_]Binding{.{ .bytes = "\x1b[C", .action = .ghost_accept }};
    // partial match
    try std.testing.expectEqual(@as(?Action, null), match(&bs, "\x1b["));
    // trailing junk
    try std.testing.expectEqual(@as(?Action, null), match(&bs, "\x1b[Cx"));
}

test "isCsiU recognises kitty-protocol CSI-u shapes" {
    try std.testing.expect(isCsiU("\x1B[105;6u")); // Ctrl+Shift+I
    try std.testing.expect(isCsiU("\x1B[57;5u")); // Ctrl+9
    try std.testing.expect(isCsiU("\x1B[27u")); // Esc (single param)
    try std.testing.expect(isCsiU("\x1B[1;5:2u")); // alternate-key indicator
}

test "isCsiU rejects non-CSI-u sequences" {
    try std.testing.expect(!isCsiU("\x1B[C")); // arrow (CSI final = C)
    try std.testing.expect(!isCsiU("\x1B[1;5C")); // Ctrl+Right (CSI-1 form)
    try std.testing.expect(!isCsiU("\t")); // bare Tab
    try std.testing.expect(!isCsiU("\x1B[2J")); // ED
    try std.testing.expect(!isCsiU("u")); // too short
    try std.testing.expect(!isCsiU("\x1B[abc;6u")); // non-digit in params
}

test "key resolves Ctrl+Shift+letter via kitty kbd encoding" {
    // i = 105
    try std.testing.expectEqualStrings("\x1B[105;6u", key("Ctrl+Shift+I"));
    try std.testing.expectEqualStrings("\x1B[105;6u", key("Ctrl+Shift+i"));
    // a = 97, z = 122
    try std.testing.expectEqualStrings("\x1B[97;6u", key("Ctrl+Shift+A"));
    try std.testing.expectEqualStrings("\x1B[122;6u", key("Ctrl+Shift+z"));
}

test "key folds Ctrl+letter to control byte" {
    try std.testing.expectEqualStrings("\x01", key("Ctrl+A"));
    try std.testing.expectEqualStrings("\x06", key("Ctrl+f"));
    try std.testing.expectEqualStrings("\x1a", key("Ctrl+Z"));
}

test "key handles Alt+char" {
    try std.testing.expectEqualStrings("\x1bf", key("Alt+f"));
    try std.testing.expectEqualStrings("\x1b.", key("Alt+."));
}

test "key handles function keys" {
    try std.testing.expectEqualStrings("\x1bOP", key("F1"));
    try std.testing.expectEqualStrings("\x1b[24~", key("F12"));
}
