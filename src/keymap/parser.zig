//! Keymap — comptime key-name parser.
//!
//! `key("Right")` resolves the byte sequence a terminal sends for the
//! named key. Lives here (not in `../keymap.zig`) so the parser's
//! ~200 lines of comptime branching don't crowd the public Action +
//! Binding types. `keymap.zig` re-exports `key` so callers still
//! write `keymap.key("Ctrl+R")` unchanged.

const std = @import("std");

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
///   - **Ctrl + digit (1..9):** kitty-keyboard CSI-u form. Only fires
///     in terminals with the disambiguate flag (atty default).
///   - **Esc + digit (1..9):** legacy `ESC <digit>`. Doubles as
///     Alt+digit on terminals without kitty kbd. Used as the
///     ghost_pick fallback binding.
///   - **Alt + single ASCII char:** `Alt+f` → `ESC f`. xterm-style.
///
/// Not handled (because terminals don't have a portable sequence):
///
///   - `Super+…` / `Win+…` / `Cmd+…` — most terminals send nothing.
///     Some (kitty/foot/Ghostty) emit kitty-keyboard-protocol bytes
///     when the protocol is negotiated; not encodable as a static
///     constant.
///   - `Ctrl+Enter`, `Ctrl+Backspace` — typically indistinguishable
///     from the unmodified key on legacy terminals. (`Ctrl+Tab` IS
///     handled via the kitty-keyboard CSI-u form `\x1b[9;5u`, since
///     atty pushes the disambiguate flag by default.)
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

    // Ctrl+Tab — kitty-keyboard CSI-u form. Legacy terminals don't
    // have a distinct encoding for this (the kernel collapses it to
    // plain Tab), so the binding only fires when the kitty kbd
    // disambiguate flag is active (atty's default). On a terminal
    // that doesn't speak the protocol, fall back to one of the other
    // ghost_accept bindings (Right / End / Ctrl+F).
    if (comptime std.mem.eql(u8, name, "Ctrl+Tab")) return "\x1b[9;5u";

    // Ctrl+<digit> — kitty kbd CSI-u. No legacy encoding for these;
    // works only with the disambiguate flag (atty default).
    if (comptime std.mem.eql(u8, name, "Ctrl+1")) return "\x1b[49;5u";
    if (comptime std.mem.eql(u8, name, "Ctrl+2")) return "\x1b[50;5u";
    if (comptime std.mem.eql(u8, name, "Ctrl+3")) return "\x1b[51;5u";
    if (comptime std.mem.eql(u8, name, "Ctrl+4")) return "\x1b[52;5u";
    if (comptime std.mem.eql(u8, name, "Ctrl+5")) return "\x1b[53;5u";
    if (comptime std.mem.eql(u8, name, "Ctrl+6")) return "\x1b[54;5u";
    if (comptime std.mem.eql(u8, name, "Ctrl+7")) return "\x1b[55;5u";
    if (comptime std.mem.eql(u8, name, "Ctrl+8")) return "\x1b[56;5u";
    if (comptime std.mem.eql(u8, name, "Ctrl+9")) return "\x1b[57;5u";

    // Esc+<digit> — legacy ESC+digit byte pair. Doubles as Alt+digit
    // on terminals without kitty kbd; matches the "fast Esc then digit"
    // two-step on terminals with kitty kbd (separated reads won't
    // trigger). Used as ghost_pick legacy fallback.
    if (comptime std.mem.eql(u8, name, "Esc+1")) return "\x1b1";
    if (comptime std.mem.eql(u8, name, "Esc+2")) return "\x1b2";
    if (comptime std.mem.eql(u8, name, "Esc+3")) return "\x1b3";
    if (comptime std.mem.eql(u8, name, "Esc+4")) return "\x1b4";
    if (comptime std.mem.eql(u8, name, "Esc+5")) return "\x1b5";
    if (comptime std.mem.eql(u8, name, "Esc+6")) return "\x1b6";
    if (comptime std.mem.eql(u8, name, "Esc+7")) return "\x1b7";
    if (comptime std.mem.eql(u8, name, "Esc+8")) return "\x1b8";
    if (comptime std.mem.eql(u8, name, "Esc+9")) return "\x1b9";

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

    @compileError("unknown key name: '" ++ name ++ "' — see src/keymap/parser.zig");
}

// ===========================================================================
// Tests — extracted to `parser_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("parser_tests.zig");
}
