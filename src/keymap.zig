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
///   - it's CSI-u but the key has no legacy form (Ctrl+9,
///     Ctrl+Shift+Right, Shift+Tab, …) — caller drops to avoid
///     mojibake echo
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

test "match does not bind Ctrl+C against the shipped default bindings" {
    // Regression guard: Ctrl+C (0x03) is a legacy control code we
    // MUST pass through to the shell so SIGINT-style line-abort
    // still works. None of the default bindings shall accidentally
    // shadow it. We replicate the default list verbatim here rather
    // than @import("defaults.zig") to avoid the multi-module file
    // rule (defaults.zig lives in the `config` module, keymap in
    // `atty`). If the upstream defaults ever change, e2e + the
    // ctrl_c_aborts_line scenario will catch behavioural regressions;
    // this test specifically forbids any binding for these bytes.
    const defaults_bindings = [_]Binding{
        .{ .bytes = key("Right"), .action = .ghost_accept },
        .{ .bytes = key("End"), .action = .ghost_accept },
        .{ .bytes = key("Ctrl+F"), .action = .ghost_accept },
        .{ .bytes = key("Ctrl+Shift+I"), .action = .incognito_toggle },
        .{ .bytes = key("Alt+i"), .action = .incognito_toggle },
        .{ .bytes = key("Ctrl+Shift+D"), .action = .delete_history_match },
    };
    try std.testing.expectEqual(@as(?Action, null), match(&defaults_bindings, "\x03"));
    // Same for Ctrl+D (0x04), Ctrl+Z (0x1A), Ctrl+\ (0x1C) — the
    // other control codes a shell wants to see verbatim.
    try std.testing.expectEqual(@as(?Action, null), match(&defaults_bindings, "\x04"));
    try std.testing.expectEqual(@as(?Action, null), match(&defaults_bindings, "\x1A"));
    try std.testing.expectEqual(@as(?Action, null), match(&defaults_bindings, "\x1C"));
}

test "isCsiU lets bare Ctrl+C through (not a CSI-u sequence)" {
    // The CSI-u drop is the second gate after match — if a key
    // doesn't match any binding AND looks like CSI-u, we drop it.
    // Bare \x03 isn't CSI-u shaped, so isCsiU returns false and
    // the byte falls through to the pty.master write.
    try std.testing.expect(!isCsiU("\x03"));
    try std.testing.expect(!isCsiU("\x04"));
}

test "match requires byte-exact equality (chunked reads don't trigger)" {
    const bs = [_]Binding{.{ .bytes = "\x1b[C", .action = .ghost_accept }};
    // partial match
    try std.testing.expectEqual(@as(?Action, null), match(&bs, "\x1b["));
    // trailing junk
    try std.testing.expectEqual(@as(?Action, null), match(&bs, "\x1b[Cx"));
}

test "csiUToLegacy: Ctrl+letter combos become their 0x01..0x1A control byte" {
    var out: [4]u8 = undefined;
    // Ctrl+A = 0x01
    try std.testing.expectEqualSlices(u8, "\x01", csiUToLegacy("\x1b[97;5u", &out).?);
    // Ctrl+C = 0x03 (the user's reported breakage)
    try std.testing.expectEqualSlices(u8, "\x03", csiUToLegacy("\x1b[99;5u", &out).?);
    // Ctrl+D = 0x04
    try std.testing.expectEqualSlices(u8, "\x04", csiUToLegacy("\x1b[100;5u", &out).?);
    // Ctrl+E = 0x05
    try std.testing.expectEqualSlices(u8, "\x05", csiUToLegacy("\x1b[101;5u", &out).?);
    // Ctrl+R = 0x12 (bash reverse-i-search)
    try std.testing.expectEqualSlices(u8, "\x12", csiUToLegacy("\x1b[114;5u", &out).?);
    // Ctrl+U = 0x15
    try std.testing.expectEqualSlices(u8, "\x15", csiUToLegacy("\x1b[117;5u", &out).?);
    // Ctrl+Z = 0x1A
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
    // Ctrl+9 — no legacy encoding (kitty kbd's whole reason for existing).
    try std.testing.expectEqual(@as(?[]const u8, null), csiUToLegacy("\x1b[57;5u", &out));
    // Ctrl+Alt+C — Alt-bearing combos fall outside our simple table.
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
    try std.testing.expectEqualSlices(u8, "\x03", csiUToLegacy("\x1b[99;6u", &out).?); // Ctrl+Shift+C
    try std.testing.expectEqualSlices(u8, "\x1a", csiUToLegacy("\x1b[122;6u", &out).?); // Ctrl+Shift+Z
}

test "csiUToLegacy: non-CSI-u input returns null without touching `out`" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), csiUToLegacy("\x03", &out));
    try std.testing.expectEqual(@as(?[]const u8, null), csiUToLegacy("\x1b[C", &out)); // arrow
    try std.testing.expectEqual(@as(?[]const u8, null), csiUToLegacy("abc", &out));
}

test "csiUToLegacy: malformed CSI-u (non-numeric) returns null safely" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), csiUToLegacy("\x1b[abc;5u", &out));
    try std.testing.expectEqual(@as(?[]const u8, null), csiUToLegacy("\x1b[99;xyu", &out));
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
