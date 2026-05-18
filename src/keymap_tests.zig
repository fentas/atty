//! Tests for `keymap.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("keymap.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const parser = @import("keymap/parser.zig");
const csiu = @import("keymap/csiu.zig");

// Re-binds of pub decls so test bodies stay short.
const Action = mod.Action;
const Binding = mod.Binding;
const csiULen = mod.csiULen;
const csiUToLegacy = mod.csiUToLegacy;
const isCsiU = mod.isCsiU;
const key = mod.key;
const kitty_kbd_pop = mod.kitty_kbd_pop;
const kitty_kbd_push = mod.kitty_kbd_push;
const match = mod.match;
const translateCsiUStream = mod.translateCsiUStream;

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
        .{ .bytes = key("Ctrl+Tab"), .action = .ghost_accept },
        .{ .bytes = key("Ctrl+Shift+I"), .action = .incognito_toggle },
        .{ .bytes = key("Alt+i"), .action = .incognito_toggle },
        .{ .bytes = key("Ctrl+Shift+D"), .action = .delete_history_match },
    };
    try std.testing.expectEqual(@as(?Action, null), match(&defaults_bindings, "\x03"));
    try std.testing.expectEqual(@as(?Action, null), match(&defaults_bindings, "\x04"));
    try std.testing.expectEqual(@as(?Action, null), match(&defaults_bindings, "\x1A"));
    try std.testing.expectEqual(@as(?Action, null), match(&defaults_bindings, "\x1C"));
}

test "match requires byte-exact equality (chunked reads don't trigger)" {
    const bs = [_]Binding{.{ .bytes = "\x1b[C", .action = .ghost_accept }};
    try std.testing.expectEqual(@as(?Action, null), match(&bs, "\x1b["));
    try std.testing.expectEqual(@as(?Action, null), match(&bs, "\x1b[Cx"));
}

test "Binding: label + description default to empty (backwards compatible)" {
    // Existing user configs that build bindings without setting
    // label/description must still compile. The Alt+H help renderer
    // skips entries with either field empty.
    const b: Binding = .{ .bytes = "\x06", .action = .ghost_accept };
    try std.testing.expectEqualStrings("", b.label);
    try std.testing.expectEqualStrings("", b.description);

    const labelled: Binding = .{ .bytes = "\x06", .action = .ghost_accept, .label = "Ctrl+F", .description = "accept ghost" };
    try std.testing.expectEqualStrings("Ctrl+F", labelled.label);
    try std.testing.expectEqualStrings("accept ghost", labelled.description);
}

test "Action.ghost_pick carries the index as a payload" {
    // Regression guard for the union(enum) shape — switch sites in
    // proxy.zig depend on capturing the index via `|n|`.
    const a: Action = .{ .ghost_pick = 3 };
    switch (a) {
        .ghost_pick => |n| try std.testing.expectEqual(@as(u8, 3), n),
        else => return error.TestFailed,
    }
}
