//! SGR-mode mouse-event parser (xterm DECSET 1006).
//!
//! Sequence shape: `\x1b[<` Cb `;` Cx `;` Cy ( `M` | `m` )
//! - `Cb` packs button + modifiers + drag bit
//! - `Cx` / `Cy` are 1-based column / row
//! - `M` = press (or motion w/ drag bit), `m` = release
//!
//! Compared to legacy x10 (`\x1b[M` + 3 raw bytes), SGR avoids
//! the 223-cell terminal-size limit and uses ASCII digits so the
//! sequence is robust to bytestream re-encoding (UTF-8, charset
//! swaps, …).
//!
//! This file ONLY parses bytes into typed events. Wiring into
//! the proxy stdin handler + the new `onMouseClick` dispatch
//! hook + the modules that act on clicks (file-path links, URL
//! opener) all land in subsequent PRs — see #304 design comment
//! for the multi-PR plan.
const std = @import("std");

pub const Button = enum {
    left,
    middle,
    right,
    /// Bare wheel-up tick (no modifiers — `Shift+Wheel` and
    /// `Ctrl+Wheel` come through the Modifiers fields).
    wheel_up,
    wheel_down,
    /// xterm "extended" buttons (button4/5 on some mice).
    /// Rare; carry through verbatim so callers can ignore.
    extended_8,
    extended_9,
    extended_10,
    extended_11,
};

pub const Kind = enum {
    /// Button went down at this cell.
    press,
    /// Button went up.
    release,
    /// Mouse moved while a button was held (drag).
    drag,
};

pub const Modifiers = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const Event = struct {
    button: Button,
    kind: Kind,
    /// 1-based column (matches the terminal's coordinate system).
    col: u16,
    /// 1-based row.
    row: u16,
    mods: Modifiers,
};

pub const ParseError = error{
    /// Sequence doesn't start with `\x1b[<`.
    NotMouseSequence,
    /// Sequence shape recognised but content is malformed (missing
    /// separator, non-digit where number expected, etc.).
    Malformed,
    /// Trailer is neither `M` nor `m`.
    BadTrailer,
    /// One of the numeric fields overflows u16. Pathological
    /// terminal sizes would have to claim 65535+ cols/rows.
    Overflow,
};

/// Parse a complete SGR mouse sequence from `bytes` starting at
/// `bytes[0]`. Returns the event + the number of bytes consumed
/// so the caller (stdin handler) can advance its cursor.
///
/// The caller is responsible for recognising the sequence
/// boundary; `peekIsMouse` below is the quick discriminator.
pub fn parse(bytes: []const u8) ParseError!struct { event: Event, consumed: usize } {
    if (bytes.len < 6) return error.NotMouseSequence;
    if (bytes[0] != 0x1b or bytes[1] != '[' or bytes[2] != '<') return error.NotMouseSequence;

    var i: usize = 3;
    const cb = try readU16(bytes, &i);
    if (i >= bytes.len or bytes[i] != ';') return error.Malformed;
    i += 1;
    const col = try readU16(bytes, &i);
    if (i >= bytes.len or bytes[i] != ';') return error.Malformed;
    i += 1;
    const row = try readU16(bytes, &i);
    if (i >= bytes.len) return error.Malformed;
    const trailer = bytes[i];
    i += 1;
    if (trailer != 'M' and trailer != 'm') return error.BadTrailer;

    // Cb bit layout (xterm SGR 1006):
    //   bits 0-1 : button number, modulo wheel/extended classes
    //   bit 2 (4): shift held
    //   bit 3 (8): alt held
    //   bit 4 (16): ctrl held
    //   bit 5 (32): motion event (drag if combined with a press)
    //   bit 6 (64): wheel
    //   bit 7 (128): xterm extended buttons (8-11)
    const shift = (cb & 4) != 0;
    const alt = (cb & 8) != 0;
    const ctrl = (cb & 16) != 0;
    const is_motion = (cb & 32) != 0;
    const is_wheel = (cb & 64) != 0;
    const is_ext = (cb & 128) != 0;
    const low2 = @as(u2, @intCast(cb & 0b11));

    const button: Button = if (is_wheel) blk: {
        break :blk if (low2 == 0) .wheel_up else .wheel_down;
    } else if (is_ext) blk: {
        break :blk switch (low2) {
            0 => .extended_8,
            1 => .extended_9,
            2 => .extended_10,
            3 => .extended_11,
        };
    } else blk: {
        // low2 == 3 is the legacy "release any" code; in SGR mode
        // the trailer (`m`) carries that info so low2 == 3 should
        // not occur — accept defensively as 'left' release.
        break :blk switch (low2) {
            0 => .left,
            1 => .middle,
            2 => .right,
            3 => .left,
        };
    };

    const kind: Kind = if (trailer == 'm')
        .release
    else if (is_motion)
        .drag
    else
        .press;

    return .{
        .event = .{
            .button = button,
            .kind = kind,
            .col = col,
            .row = row,
            .mods = .{ .shift = shift, .alt = alt, .ctrl = ctrl },
        },
        .consumed = i,
    };
}

/// Quick discriminator for the proxy stdin handler. True iff
/// `bytes` could be the start of an SGR mouse sequence. Doesn't
/// validate the rest — `parse()` does the full check.
pub fn peekIsMouse(bytes: []const u8) bool {
    return bytes.len >= 3 and bytes[0] == 0x1b and bytes[1] == '[' and bytes[2] == '<';
}

/// Enable SGR mouse reporting on a terminal. Writes the standard
/// DECSET sequences: `?1000h` (any button), `?1002h` (button-
/// drag motion), `?1006h` (SGR format). The trio is what kitty,
/// foot, Ghostty, WezTerm all expect. Caller writes the returned
/// slice to the PTY master (it's typically appended to atty's
/// other initial-state setup like `?1u` for the kitty kbd
/// protocol).
pub const enable_sequence: []const u8 = "\x1b[?1000h\x1b[?1002h\x1b[?1006h";

/// Disable counterpart — atty's exit path writes this so the
/// terminal isn't left in mouse-reporting mode (which would leak
/// CSI < sequences into the next shell the user starts).
pub const disable_sequence: []const u8 = "\x1b[?1006l\x1b[?1002l\x1b[?1000l";

fn readU16(bytes: []const u8, i: *usize) ParseError!u16 {
    var n: u32 = 0;
    var any = false;
    while (i.* < bytes.len) {
        const c = bytes[i.*];
        if (c < '0' or c > '9') break;
        any = true;
        n = n * 10 + (c - '0');
        if (n > std.math.maxInt(u16)) return error.Overflow;
        i.* += 1;
    }
    if (!any) return error.Malformed;
    return @intCast(n);
}

test {
    _ = @import("mouse_tests.zig");
}
