//! Paint-side tests for `modules/llm.zig` — exercise the paint
//! surface (alt-screen chat overlay, inline chat panel, OSC 12/112
//! cursor-colour edges, `provideTermBytes` output). Lives next to
//! `paint.zig` per the project's `<name>_tests.zig` convention,
//! even though the assertions go through the top-level
//! `configure()` factory in llm.zig.

const std = @import("std");
const testing = std.testing;

const mod = @import("../llm.zig");
const configure = mod.configure;
const m = @import("../../module.zig");
const dialog = mod.dialog_ns;
const shutdownAndFree = @import("test_helpers.zig").shutdownAndFree;

const test_io: std.Io = std.Io.failing;

test "chat overlay (Alt+Shift+C): toggle emits alt-screen enter then exit" {
    const L = configure(.{
        .api_base = "http://test/v1",
        .api_base_env = "ATTY_TEST_NEVER",
        .api_base_fallback_env = "ATTY_TEST_NEVER",
        .api_key_env = "ATTY_TEST_NEVER",
    });

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();
    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);

    var line: @import("../../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = real_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    // Inject a fake turn so the overlay has content to render.
    // `pushTurn` is internal to `configure()`, so reach it via the
    // dialog factory the same way the module's own hooks do.
    const helpers = dialog.Module(L.config, L.Runtime);
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "explain X"));
    defer helpers.freeTurns(&rt);

    // Open.
    _ = try L.onAction(&rt, &ctx, .llm_chat_overlay_toggle);
    try testing.expect(rt.chat_overlay_open);
    try testing.expect(rt.chat_overlay_paint_pending);
    const opened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(opened != null);
    // Alt-screen enter + clear + home + title bar present.
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[?1049h") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[2J") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "atty chat") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "You:") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "explain X") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "[Alt+Shift+C close") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "Enter send") != null);
    // DECSTBM scroll region is set so long content can't clobber
    // the input + footer at the bottom (regression for the
    // "broken overlay" screenshot bug). Match `\x1B[1;<digits>r`
    // — the trailing `r` is the DECSTBM terminator and rules out
    // false positives from the cursor-home `\x1B[1;1H` also emitted
    // by the open sequence.
    {
        const idx = std.mem.indexOf(u8, opened.?, "\x1B[1;") orelse return error.TestUnexpectedResult;
        var j = idx + 4;
        while (j < opened.?.len and opened.?[j] >= '0' and opened.?[j] <= '9') : (j += 1) {}
        try testing.expect(j < opened.?.len);
        try testing.expectEqual(@as(u8, 'r'), opened.?[j]);
    }
    // Cyan chat input prompt glyph (input row).
    try testing.expect(std.mem.indexOf(u8, opened.?, "\u{276F}") != null);

    // Close.
    _ = try L.onAction(&rt, &ctx, .llm_chat_overlay_toggle);
    try testing.expect(!rt.chat_overlay_open);
    try testing.expect(rt.chat_overlay_paint_pending);
    const closed = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(closed != null);
    // Cursor-show + alt-screen exit, in that order (real cursor
    // was hidden on open so the overlay's reverse-video block
    // cursor wasn't doubled).
    // Close emits DECSTBM reset (defensive — even though
    // alt-screen exit should restore the primary screen's
    // scroll region), then show-cursor, then alt-screen exit.
    try testing.expectEqualStrings("\x1B[r\x1B[?25h\x1B[?1049l", closed.?);
}

test "inline chat (Alt+C): toggle flips reserve-rows request and paints panel" {
    const L = configure(.{
        .api_base = "http://test/v1",
        .api_base_env = "ATTY_TEST_NEVER",
        .api_base_fallback_env = "ATTY_TEST_NEVER",
        .api_key_env = "ATTY_TEST_NEVER",
    });

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();
    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);

    var line: @import("../../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = real_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
        // Pretend a statusbar exists — the toggle handler refuses
        // to open inline chat when statusbar_reserve is null
        // (round 5 fix); these tests focus on the toggle/paint path,
        // not the no-statusbar guard.
        .statusbar_base_reserve = 3,
        .statusbar_reserve = 3,
        .terminal_rows = 24,
        .terminal_cols = 80,
    };

    // Closed by default — no reserve request, getter reports false.
    try testing.expectEqual(@as(u16, 0), L.extraReserveRows(&rt));
    try testing.expect(!L.isInlineChatActive(&rt));

    // Toggle open — reserve grows by `cfg.inline_chat_rows`, the
    // inline-active getter flips, and the paint latch is armed.
    const consumed = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(consumed);
    try testing.expect(rt.chat_inline_open);
    try testing.expect(rt.chat_inline_paint_pending);
    try testing.expect(L.isInlineChatActive(&rt));
    try testing.expect(L.extraReserveRows(&rt) >= 3);

    // Simulate the proxy growing the reservation in response: the
    // real proxy bumps `ctx.statusbar_reserve` to base + extra on
    // the next iteration top. Without this, paintInlineChat would
    // bail because `live_reserve == base_reserve` (no panel room).
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);

    // Paint must render the divider chrome + input prompt glyph.
    // (Cannot pin the exact CUP rows because tty size isn't
    // queryable in the test environment — paintInlineChat falls
    // back to 24×80 so the input row lands somewhere in 1..24.)
    const opened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(opened != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "atty chat") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "\u{276F}") != null); // input ❯
    try testing.expect(std.mem.indexOf(u8, opened.?, "Alt+C") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "Enter") != null);
    // Save-cursor on open so close can restore.
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[s") != null);

    // Toggle closed — reserve request returns to zero, paint shows
    // the cursor and leaves placement to bash's next redraw.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(!rt.chat_inline_open);
    try testing.expectEqual(@as(u16, 0), L.extraReserveRows(&rt));
    const closed = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(closed != null);
    try testing.expect(std.mem.indexOf(u8, closed.?, "\x1B[?25h") != null);
}

test "provideTermBytes emits OSC 12 on prefix-match edge, OSC 112 on un-match" {
    const L = configure(.{
        .api_base = "http://test/v1",
        .api_base_env = "ATTY_TEST_NEVER",
        .api_base_fallback_env = "ATTY_TEST_NEVER",
        .api_key_env = "ATTY_TEST_NEVER",
        .prefix_signal_cursor_color = "cyan",
    });

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();

    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);

    var line: @import("../../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = real_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    // Empty line → no transition, returns null.
    try testing.expectEqual(@as(?[]const u8, null), try L.provideTermBytes(&rt, &ctx));

    // User starts typing the prefix. After 3 keystrokes, the line
    // matches `#: `. The next provideTermBytes call should emit
    // OSC 12 with the configured colour.
    _ = line.applyInput("#: ");
    const out1 = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(out1 != null);
    try testing.expect(std.mem.indexOf(u8, out1.?, "\x1B]12;cyan\x07") != null);
    try testing.expect(rt.cursor_signal_active);

    // Still matching → no edge, no re-emit.
    try testing.expectEqual(@as(?[]const u8, null), try L.provideTermBytes(&rt, &ctx));

    // User backspaces past the prefix. Edge out → OSC 112 reset.
    line = .{};
    _ = line.applyInput("#");
    const out2 = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(out2 != null);
    try testing.expect(std.mem.indexOf(u8, out2.?, "\x1B]112\x07") != null);
    try testing.expect(!rt.cursor_signal_active);
}
