//! Keyboard input parsing for attop.
//!
//! The proxy has its own elaborate keymap (kitty kbd protocol, CSI-u,
//! release-event handling) because it sits between a terminal and a
//! shell. attop is a leaf TUI — it owns the terminal outright — so it
//! needs a smaller, self-contained decoder: one read → zero or more
//! `Key`s. We model the keys a dashboard actually binds (arrows + vim
//! motions + Tab/Enter/Esc + Ctrl-C) and treat everything else as a
//! printable `char`, leaving richer protocols for if/when a panel asks.
//!
//! Decoding is greedy left-to-right over the raw bytes of a single
//! read. A lone ESC (0x1b) with no following bytes IS the Escape key;
//! an ESC that begins a recognised CSI/SS3 sequence is that key. An
//! unrecognised escape sequence is consumed (so its bytes don't leak
//! as printable noise) and reported as `.unknown` — the host ignores
//! those rather than mis-firing an action.

const std = @import("std");

pub const Key = union(enum) {
    /// A printable byte (>= 0x20, != DEL). Multi-byte UTF-8 arrives as
    /// a sequence of `char`s today — panels that care about glyphs can
    /// reassemble; the dashboard's bindings are all ASCII.
    char: u8,
    /// Ctrl-<letter>, normalised to the lowercase letter (Ctrl-C → 'c').
    ctrl: u8,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    enter,
    tab,
    back_tab, // Shift+Tab
    escape,
    backspace,
    /// A consumed-but-unrecognised escape sequence. The host ignores it
    /// (vs. letting the raw bytes fall through as printable mojibake).
    unknown,
};

/// One decoded key + how many bytes it consumed from the front of
/// `bytes`. `len == 0` never happens for a non-empty input (we always
/// make progress), so the caller's loop terminates.
pub const Decoded = struct {
    key: Key,
    len: usize,
};

/// Decode the first key at the front of `bytes`. Returns null only for
/// an empty slice. Callers drain a read by looping: decode, advance by
/// `len`, repeat.
pub fn decode(bytes: []const u8) ?Decoded {
    if (bytes.len == 0) return null;
    const b = bytes[0];

    // ESC: either a lone Escape, or the lead-in of a CSI/SS3 sequence.
    if (b == 0x1b) return decodeEscape(bytes);

    // Control bytes we name explicitly; the rest become Ctrl-<letter>.
    switch (b) {
        '\r', '\n' => return .{ .key = .enter, .len = 1 },
        '\t' => return .{ .key = .tab, .len = 1 },
        0x7f, 0x08 => return .{ .key = .backspace, .len = 1 },
        else => {},
    }
    if (b < 0x20) {
        // C0 control → Ctrl-<letter>. 0x01='a' … 0x1a='z'; others map
        // to their `@` + offset form but only letters are bound today.
        return .{ .key = .{ .ctrl = b + 0x60 }, .len = 1 };
    }
    if (b == 0x7f) return .{ .key = .backspace, .len = 1 };

    // Printable.
    return .{ .key = .{ .char = b }, .len = 1 };
}

fn decodeEscape(bytes: []const u8) Decoded {
    // Lone ESC (nothing follows) → Escape key.
    if (bytes.len == 1) return .{ .key = .escape, .len = 1 };

    switch (bytes[1]) {
        // CSI: ESC [ … final
        '[' => return decodeCsi(bytes),
        // SS3: ESC O <final> — some terminals send arrows/Home/End this
        // way (application cursor-key mode).
        'O' => {
            if (bytes.len < 3) return .{ .key = .escape, .len = 1 };
            return .{ .key = ss3Final(bytes[2]), .len = 3 };
        },
        // ESC followed by something else: a lone Escape; let the next
        // byte decode on its own next iteration.
        else => return .{ .key = .escape, .len = 1 },
    }
}

fn decodeCsi(bytes: []const u8) Decoded {
    // Scan to the final byte (0x40..0x7e). If the sequence is split
    // across reads (no final byte yet) treat the ESC as Escape — a
    // dashboard read is never split mid-CSI in practice, and falling
    // back to Escape is harmless.
    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c >= 0x40 and c <= 0x7e) break;
    }
    if (i >= bytes.len) return .{ .key = .escape, .len = 1 };

    const final = bytes[i];
    const params = bytes[2..i];
    const consumed = i + 1;

    // Tilde-style: ESC [ <n> ~  → Home/End/PageUp/PageDown/etc.
    if (final == '~') {
        return .{ .key = tildeKey(params), .len = consumed };
    }
    // Letter finals: arrows + Home/End. Shift+Tab is ESC [ Z.
    const key: Key = switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'Z' => .back_tab,
        else => .unknown,
    };
    return .{ .key = key, .len = consumed };
}

fn ss3Final(c: u8) Key {
    return switch (c) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        else => .unknown,
    };
}

fn tildeKey(params: []const u8) Key {
    // Modified form is `<n>;<mod>` (e.g. Ctrl+End = `4;5`). Key off the
    // leading number so a modified nav key still navigates.
    const code = params[0..(std.mem.indexOfScalar(u8, params, ';') orelse params.len)];
    if (std.mem.eql(u8, code, "1") or std.mem.eql(u8, code, "7")) return .home;
    if (std.mem.eql(u8, code, "4") or std.mem.eql(u8, code, "8")) return .end;
    if (std.mem.eql(u8, code, "5")) return .page_up;
    if (std.mem.eql(u8, code, "6")) return .page_down;
    return .unknown;
}

test {
    _ = @import("key_tests.zig");
}
