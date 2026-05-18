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
    // Invariant: open paint ends with explicit CUP to the shell
    // row, so the real terminal cursor doesn't stay parked at the
    // panel input row. Snapshot is 0 here (is_tty=false), so the
    // helper falls back to shell_bottom = 24 - 3 = 21.
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[21;1H") != null);

    // Toggle closed — reserve request returns to zero, paint emits
    // the saved-cursor restore + leaves clearing to the proxy.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(!rt.chat_inline_open);
    try testing.expectEqual(@as(u16, 0), L.extraReserveRows(&rt));
    const closed = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(closed != null);
    // Close emits cursor-show + explicit CUP to the shell-bottom
    // row (rather than DECRC, which the proxy's applyReserveRows
    // would have clobbered with its own DECSC/DECRC pair).
    // Pin the EXACT row — terminal_rows=24, base_reserve=3 →
    // shell_bottom = 21. Catches a regression that emits CUP to a
    // wrong row (e.g. the old `\x1B[1;1H` home-position drift).
    try testing.expect(std.mem.indexOf(u8, closed.?, "\x1B[?25h") != null);
    try testing.expect(std.mem.indexOf(u8, closed.?, "\x1B[21;1H") != null);
}

test "inline chat (Alt+C): open paint CUP-restores to the cursor_row snapshot taken at toggle time" {
    // Invariant: toggle-open snapshots `ctx.cursor_row` into the
    // Runtime; every subsequent paint ends with CUP back to that
    // row so the real terminal cursor sits on the shell prompt
    // (not the panel input row) when paint returns.
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
        .statusbar_base_reserve = 3,
        .statusbar_reserve = 3,
        .terminal_rows = 24,
        .terminal_cols = 80,
        // Shell prompt is currently at row 8 (e.g. plenty of output
        // above). The open-paint must CUP back here, NOT shell_bottom.
        .cursor_row = 8,
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(rt.chat_inline_open);
    try testing.expectEqual(@as(u16, 8), rt.chat_open_cursor_row);

    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const opened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(opened != null);
    // Paint must end with CUP to row 8 (the snapshot), NOT row 21
    // (the fallback shell_bottom).
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[8;1H") != null);

    // Close also routes through the same helper — CUP to row 8.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    const closed = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(closed != null);
    try testing.expect(std.mem.indexOf(u8, closed.?, "\x1B[8;1H") != null);
}

test "inline chat: cursor_row snapshot clamps to shell_bottom when it overshoots the shell area" {
    // Invariant: a snapshot that lands inside the reserved
    // statusbar/panel zone (cursor_tracker drift, SIGWINCH races)
    // must clamp to shell_bottom — never CUP into the reservation.
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
        .statusbar_base_reserve = 3,
        .statusbar_reserve = 3,
        .terminal_rows = 24,
        .terminal_cols = 80,
        // Bogus row (in the reservation): helper must clamp to 21.
        .cursor_row = 23,
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const opened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(opened != null);
    // CUP to row 21 (shell_bottom), NOT row 23 (the bogus snapshot).
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[21;1H") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[23;1H") == null);
}

test "inline chat: re-open with null ctx.cursor_row clears the previous snapshot via the open branch" {
    // Invariant: the open branch unconditionally writes
    // `ctx.cursor_row orelse 0` into the snapshot. A re-open with
    // `cursor_row = null` (e.g. cursor_tracker not wired this tick)
    // must NOT reuse the previous open's row — it falls back to
    // shell_bottom via the helper's 0-sentinel branch.
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
        .statusbar_base_reserve = 3,
        .statusbar_reserve = 3,
        .terminal_rows = 24,
        .terminal_cols = 80,
        .cursor_row = 8,
    };

    // First open captures row 8.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 8), rt.chat_open_cursor_row);
    // Close leaves the snapshot intact — the close paint still
    // needs it to know where to restore.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 8), rt.chat_open_cursor_row);

    // Re-open with no cursor_row available — open branch writes 0.
    ctx.cursor_row = null;
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 0), rt.chat_open_cursor_row);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const reopened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(reopened != null);
    // CUP to row 21 (shell_bottom fallback), NOT row 8 (stale).
    try testing.expect(std.mem.indexOf(u8, reopened.?, "\x1B[21;1H") != null);
    try testing.expect(std.mem.indexOf(u8, reopened.?, "\x1B[8;1H") == null);
}

test "inline chat: re-open with a different non-null cursor_row overwrites the previous snapshot" {
    // Symmetric to the null-cursor_row test: the open branch
    // unconditionally writes `ctx.cursor_row orelse 0`, so a fresh
    // value MUST overwrite the previous open's snapshot — paint
    // CUPs to the new row, not the old one.
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
        .statusbar_base_reserve = 3,
        .statusbar_reserve = 3,
        .terminal_rows = 24,
        .terminal_cols = 80,
        .cursor_row = 8,
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 8), rt.chat_open_cursor_row);
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);

    // Re-open at a different row. New snapshot must replace the
    // previous one and the paint must use it.
    ctx.cursor_row = 12;
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 12), rt.chat_open_cursor_row);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const reopened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(reopened != null);
    try testing.expect(std.mem.indexOf(u8, reopened.?, "\x1B[12;1H") != null);
    try testing.expect(std.mem.indexOf(u8, reopened.?, "\x1B[8;1H") == null);
}

test "inline chat: paint ignores live ctx.cursor_row drift while panel is open" {
    // Regression guard: paint MUST anchor to the snapshot, not the
    // live `ctx.cursor_row`. The shell can still emit output that
    // updates cursor_tracker between paints; if a future refactor
    // swaps the snapshot for the live value, the panel would
    // chase the cursor around instead of restoring to the prompt.
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
        .statusbar_base_reserve = 3,
        .statusbar_reserve = 3,
        .terminal_rows = 24,
        .terminal_cols = 80,
        .cursor_row = 10,
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 10), rt.chat_open_cursor_row);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);

    const first = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(first != null);
    // The restore CUP is the LAST bytes the paint emits.
    try testing.expect(std.mem.endsWith(u8, first.?, "\x1B[10;1H"));

    // Live cursor drifts (shell printed output between ticks).
    // Snapshot must NOT update — the closing restore CUP must
    // still target row 10, never row 5 / row 18 / etc.
    ctx.cursor_row = 5;
    rt.chat_inline_paint_pending = true;
    const second = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(second != null);
    try testing.expect(std.mem.endsWith(u8, second.?, "\x1B[10;1H"));
    try testing.expectEqual(@as(u16, 10), rt.chat_open_cursor_row);
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

test "overlay input: cursor-split rendering puts reverse-video on the cursor byte" {
    // Invariant: when the cursor is mid-buffer the byte UNDER the
    // cursor renders inside `\x1B[7m...\x1B[0m` (reverse video),
    // not duplicated in the tail. At end-of-buffer the cursor
    // collapses to a reverse-video space.
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

    rt.chat_overlay_open = true;
    rt.chat_overlay_paint_pending = true;
    // Seed input buffer directly.
    const buf = "abXcd";
    @memcpy(rt.chat_input_buf[0..buf.len], buf);
    rt.chat_input_len = buf.len;
    rt.chat_input_cursor = 2; // on 'X'

    const bytes = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(bytes != null);
    // The cursor byte 'X' must appear inside the reverse-video
    // SGR pair. Asserting the literal `\x1B[7mX\x1B[0m` substring
    // pins both the highlight AND the no-duplication invariant.
    try testing.expect(std.mem.indexOf(u8, bytes.?, "\x1B[7mX\x1B[0m") != null);
    // The buffer text appears once: walk the rendered output and
    // confirm 'X' shows up exactly once.
    var count: usize = 0;
    for (bytes.?) |c| if (c == 'X') {
        count += 1;
    };
    try testing.expectEqual(@as(usize, 1), count);

    // End-of-buffer cursor → reverse-video SPACE (not a buffer byte).
    rt.chat_input_cursor = rt.chat_input_len;
    rt.chat_overlay_paint_pending = true;
    const bytes2 = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(bytes2 != null);
    try testing.expect(std.mem.indexOf(u8, bytes2.?, "\x1B[7m \x1B[0m") != null);
}

test "inline input: parked render renders cursor byte once (no duplication)" {
    // Invariant: when focus is parked, the byte under the cursor
    // renders in `\x1B[2m...\x1B[0m` (dim) — NOT as a stand-in
    // glyph AND the literal byte. Regression guard for the
    // "draft shifted one column right when parked" bug.
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
        .statusbar_base_reserve = 3,
        .statusbar_reserve = 3,
        .terminal_rows = 24,
        .terminal_cols = 80,
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(rt.chat_inline_open);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);

    // Seed inline input + park focus.
    const buf = "abYcd";
    @memcpy(rt.chat_inline_input_buf[0..buf.len], buf);
    rt.chat_inline_input_len = buf.len;
    rt.chat_inline_input_cursor = 2;
    rt.chat_focus_in_panel = false; // parked
    rt.chat_inline_paint_pending = true;

    const bytes = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(bytes != null);
    // 'Y' must appear exactly once across the entire paint.
    var count: usize = 0;
    for (bytes.?) |c| if (c == 'Y') {
        count += 1;
    };
    try testing.expectEqual(@as(usize, 1), count);
}

test "overlay scroll: nonzero view offset hides tail turns AND emits indicator" {
    // Invariant: when `chat_view_offset > 0` the paint must (a)
    // suppress the most-recent N turns, and (b) emit the
    // dim `[↑ N below]` indicator in the footer row.
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

    const helpers = dialog.Module(L.config, L.Runtime);
    defer helpers.freeTurns(&rt);
    // Three turns with distinct content so we can assert which
    // ones the paint suppresses.
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "TURN-OLDEST"));
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "TURN-MIDDLE"));
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "TURN-NEWEST"));

    rt.chat_overlay_open = true;
    rt.chat_overlay_paint_pending = true;
    // Scroll back by 2 — only TURN-OLDEST should be visible.
    rt.chat_view_offset = 2;

    const bytes = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(bytes != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "TURN-OLDEST") != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "TURN-MIDDLE") == null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "TURN-NEWEST") == null);
    // Footer indicator visible with the count.
    try testing.expect(std.mem.indexOf(u8, bytes.?, "\u{2191} 2 below") != null);
    // Standard footer hint still present (scroll indicator
    // prepends, doesn't replace).
    try testing.expect(std.mem.indexOf(u8, bytes.?, "Alt+Shift+C close") != null);

    // Re-pin: offset = 0 → all 3 turns visible, no indicator.
    rt.chat_view_offset = 0;
    rt.chat_overlay_paint_pending = true;
    const bytes2 = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(bytes2 != null);
    try testing.expect(std.mem.indexOf(u8, bytes2.?, "TURN-OLDEST") != null);
    try testing.expect(std.mem.indexOf(u8, bytes2.?, "TURN-MIDDLE") != null);
    try testing.expect(std.mem.indexOf(u8, bytes2.?, "TURN-NEWEST") != null);
    try testing.expect(std.mem.indexOf(u8, bytes2.?, "below") == null);
}

test "inline scroll: nonzero inline offset windows the visible turns + emits indicator" {
    // Invariant for the inline panel: when
    // `chat_inline_view_offset > 0` the scrollback walker must
    // window further back (suppress recent turns) and the first
    // scrollback row must carry the dim "↑ N more turn(s) below"
    // header.
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
        .statusbar_base_reserve = 3,
        .statusbar_reserve = 3,
        .terminal_rows = 24,
        .terminal_cols = 80,
    };

    const helpers = dialog.Module(L.config, L.Runtime);
    defer helpers.freeTurns(&rt);
    // Three labelled turns so we can pin which one survives.
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "INL-OLDEST"));
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "INL-MIDDLE"));
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "INL-NEWEST"));

    // Toggle the panel open — the proxy normally extends the
    // reservation in response, so mirror that here.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(rt.chat_inline_open);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    // Scroll back by 2 turns: only INL-OLDEST should remain.
    rt.chat_inline_view_offset = 2;
    rt.chat_inline_paint_pending = true;

    const bytes = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(bytes != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "INL-OLDEST") != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "INL-MIDDLE") == null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "INL-NEWEST") == null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "\u{2191} 2 more turn") != null);

    // Re-pin to 0 → all three visible, header gone.
    rt.chat_inline_view_offset = 0;
    rt.chat_inline_paint_pending = true;
    const bytes2 = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(bytes2 != null);
    try testing.expect(std.mem.indexOf(u8, bytes2.?, "INL-OLDEST") != null);
    try testing.expect(std.mem.indexOf(u8, bytes2.?, "INL-MIDDLE") != null);
    try testing.expect(std.mem.indexOf(u8, bytes2.?, "INL-NEWEST") != null);
    try testing.expect(std.mem.indexOf(u8, bytes2.?, "more turn") == null);
}
