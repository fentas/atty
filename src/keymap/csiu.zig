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
        // Unmodified printable ASCII. atty pushes kitty kbd flag 1
        // (disambiguate) which per spec only requires Tab/Enter/Esc/
        // Backspace + the function keys to be CSI-u — printable
        // chars should arrive as their literal bytes. Some terminal
        // implementations (xterm.js in VS Code / Windsurf) over-
        // report and emit `\x1b[32u` for Space too. Without this
        // translation, the "unmapped + not in alt-screen → drop"
        // path silently swallows Space (typed line never grows) and
        // any other printable that the terminal CSI-u-ifies. Cover
        // 0x20..0x7E so the failure mode can't show up for `!`,
        // `~`, digits, letters either if a future terminal lib
        // generalises the over-reporting.
        0x20...0x7E => return writeOne(out, @intCast(kc)),
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

/// True if `input` is a modifier-augmented VT-style CSI sequence:
/// `ESC [ <keycode> ; <modifier> ~`, where the modifier param is
/// strictly greater than 1 (1 = no modifier; legacy unmodified
/// `\x1b[<n>~` shapes still pass through to the shell).
///
/// This is the `~`-terminated sibling of CSI-u under kitty kbd
/// flag 1 (disambiguate). Examples bash readline can't handle:
///   `\x1b[2;5~` — Ctrl+Insert (Windsurf's Super+V paste).
///   `\x1b[3;5~` — Ctrl+Delete.
///   `\x1b[5;5~` — Ctrl+PageUp.
/// Without dropping these, bash beeps + echoes the trailing
/// `<modifier>~` tail (`5~`) as if it were typed input — the
/// user-visible "5~ leak" on the prompt.
pub fn isModifiedVtCsi(input: []const u8) bool {
    if (input.len < 6) return false; // min: `ESC [ <kc> ; <m> ~`
    if (input[0] != 0x1B or input[1] != '[') return false;
    if (input[input.len - 1] != '~') return false;
    // Body must contain exactly one `;` (separating keycode and
    // modifier). Body chars are digits / `;` / `:` only.
    var semis: usize = 0;
    for (input[2 .. input.len - 1]) |b| {
        switch (b) {
            '0'...'9', ':' => {},
            ';' => semis += 1,
            else => return false,
        }
    }
    if (semis != 1) return false;
    // Modifier param must be >= 2 (i.e. some modifier is held);
    // an explicit `<n>;1~` shape is rare but, if it ever appears,
    // is semantically identical to the unmodified `<n>~` form.
    // Don't drop those — let them pass through.
    const body = input[2 .. input.len - 1];
    const semi = std.mem.indexOfScalar(u8, body, ';').?;
    const after = body[semi + 1 ..];
    const mod_end = std.mem.indexOfScalar(u8, after, ':') orelse after.len;
    const mod = std.fmt.parseInt(u32, after[0..mod_end], 10) catch return false;
    return mod >= 2;
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

// ===========================================================================
// Tests — extracted to `csiu_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("csiu_tests.zig");
}
