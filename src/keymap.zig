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
