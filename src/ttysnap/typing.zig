//! Char-by-char typing with selectable cadence — the input-side counterpart to
//! the `wait` helpers. Generic over any driver exposing `send([]const u8) !void`
//! + `pumpMs(i32) !bool` (ttysnap's `Harness`, the e2e `Session`).
//!
//! Each codepoint is sent, then the screen is pumped for the pattern's inter-key
//! delay (via `wait.sleepMs`), so the shell echo renders one char at a time and
//! a `cast_recorder` captures one timestamped event per keystroke — `agg` then
//! animates realistic typing. The jitter is a fixed-seed PRNG, so a recording
//! regenerates byte-for-byte.

const std = @import("std");
const wait = @import("wait");

pub const Pattern = enum {
    instant, // send all at once, no animation (the default — matches plain send)
    fast, // consistent, brisk
    consistent, // consistent, normal pace
    slow, // consistent, deliberate
    irregular, // human-like: jitter + longer pauses after spaces/punctuation
    random, // uniform random jitter

    /// Parse a DSL/CLI pattern name; null if unknown.
    pub fn fromName(name: []const u8) ?Pattern {
        return std.meta.stringToEnum(Pattern, name);
    }
};

/// Type `text` into `driver` at the given cadence. UTF-8 aware — whole
/// codepoints are sent, never split across keystrokes.
pub fn typeText(driver: anytype, text: []const u8, pattern: Pattern) !void {
    if (pattern == .instant) {
        try driver.send(text);
        return;
    }
    var prng = std.Random.DefaultPrng.init(0xA77_5EED);
    const rng = prng.random();
    var i: usize = 0;
    while (i < text.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + cp_len, text.len);
        try driver.send(text[i..end]);
        const last = text[end - 1];
        i = end;
        const delay = perCharDelay(pattern, last, rng);
        if (delay > 0) try wait.sleepMs(driver, delay);
    }
}

fn perCharDelay(pattern: Pattern, prev: u8, rng: std.Random) u32 {
    return switch (pattern) {
        .instant => 0,
        .fast => 25,
        .consistent => 55,
        .slow => 120,
        .random => rng.intRangeAtMost(u32, 20, 110),
        .irregular => blk: {
            var d = rng.intRangeAtMost(u32, 40, 85); // base keystroke jitter
            switch (prev) { // a beat after a word boundary / punctuation
                ' ', ',', '.', '/', '-', ';', ':' => d += 70,
                else => {},
            }
            if (rng.intRangeAtMost(u32, 0, 11) == 0) d += 190; // occasional hesitation
            break :blk d;
        },
    };
}

test {
    _ = @import("typing_tests.zig");
}
