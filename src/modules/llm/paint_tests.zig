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
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
    try testing.expect(std.mem.indexOf(u8, opened.?, "Alt+Shift+C close") != null);
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
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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

test "inline chat fast-path: keystroke replays only the input block, not the divider" {
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const full = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(full != null);
    try testing.expect(rt.chat_inline_paint_cache_valid);
    const full_len = full.?.len;

    // Simulate typing: input_dirty without paint_pending → fast path.
    rt.chat_inline_input_buf[0] = 'h';
    rt.chat_inline_input_len = 1;
    rt.chat_inline_input_cursor = 1;
    rt.chat_inline_input_dirty = true;
    const fast = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(fast != null);
    // Fast-path skips divider + scrollback → output is meaningfully
    // shorter than the full paint AND lacks the chrome label.
    try testing.expect(fast.?.len < full_len);
    try testing.expect(std.mem.indexOf(u8, fast.?, "atty chat") == null);
    try testing.expect(std.mem.indexOf(u8, fast.?, "\u{276F}") != null);
    try testing.expect(std.mem.indexOf(u8, fast.?, "h") != null);

    // Inserting a `\n` shifts the scrollback boundary — fast-path
    // must bail to full repaint (divider chrome reappears).
    rt.chat_inline_input_buf[1] = '\n';
    rt.chat_inline_input_len = 2;
    rt.chat_inline_input_cursor = 2;
    rt.chat_inline_input_dirty = true;
    const after_newline = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(after_newline != null);
    try testing.expect(std.mem.indexOf(u8, after_newline.?, "atty chat") != null);

    // Cols change → cache mismatch → bail to full repaint.
    rt.chat_inline_input_dirty = true;
    ctx.terminal_cols = 120;
    const after_cols = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(after_cols != null);
    try testing.expect(std.mem.indexOf(u8, after_cols.?, "atty chat") != null);

    // Incognito toggle changes chrome (icon + mode_word) — fast-path
    // must bail so the divider reflects the new state. Ctrl+Shift+I
    // lives in the proxy and has no per-module notify hook; the
    // fast-path detects via the cached flag.
    rt.chat_inline_input_dirty = true;
    ctx.incognito = true;
    const after_incognito = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(after_incognito != null);
    try testing.expect(std.mem.indexOf(u8, after_incognito.?, "incognito") != null);
}

test "inline chat fast-path: once input is at the cap, more newlines keep fast-pathing" {
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);

    // Pre-seed buffer with enough newlines to saturate
    // `input_lines_cap` (panel_rows / 2). Default `inline_chat_rows=10`
    // + `inline_chat_top_gap=1` → live_reserve=14, panel_rows=10 →
    // cap=5. So 5 newlines push desired=6 → clamped to 5 (the cap);
    // 6 newlines push desired=7 → still clamped to 5.
    @memcpy(rt.chat_inline_input_buf[0..7], "h\n\n\n\n\n\n");
    rt.chat_inline_input_len = 7;
    rt.chat_inline_input_cursor = 7;
    _ = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(rt.chat_inline_paint_cache_valid);
    try testing.expectEqual(@as(u16, 5), rt.chat_inline_paint_input_lines);
    try testing.expectEqual(@as(u16, 5), rt.chat_inline_paint_input_lines_cap);

    // Add another newline — desired=8 → clamped to 5 → no shift.
    // Fast-path must STAY engaged (this is the whole point of the
    // clamp-aware comparison from round 2 review). Output should
    // lack the divider chrome.
    rt.chat_inline_input_buf[7] = '\n';
    rt.chat_inline_input_len = 8;
    rt.chat_inline_input_cursor = 8;
    rt.chat_inline_input_dirty = true;
    const after_cap_newline = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(after_cap_newline != null);
    try testing.expect(std.mem.indexOf(u8, after_cap_newline.?, "atty chat") == null);
}

test "inline chat (Alt+C): open paint CUP-restores to the cursor_row snapshot captured at first paint" {
    // Invariant: the first paint after toggle-open snapshots
    // `ctx.cursor_row` into the Runtime; every subsequent paint
    // ends with CUP back to that row so the real terminal cursor
    // sits on the shell prompt (not the panel input row).
    // (Snapshot is deferred from toggle to first paint so the
    // proxy's reservation-grow scroll-up can complete and update
    // `ctx.cursor_row` to the post-scroll prompt position before
    // we capture.)
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
    // Toggle defers capture — snapshot is 0 until first paint.
    try testing.expectEqual(@as(u16, 0), rt.chat_open_cursor_row);

    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const opened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(opened != null);
    // First paint captured 8 from ctx.cursor_row.
    try testing.expectEqual(@as(u16, 8), rt.chat_open_cursor_row);
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
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
    // Invariant: toggle-open resets the snapshot to 0 and the
    // first paint writes `ctx.cursor_row orelse 0` into it. A
    // re-open with `cursor_row = null` (cursor_tracker not wired
    // this tick) must NOT reuse the previous open's row — paint
    // writes 0 and the helper falls back to shell_bottom.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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

    // First open + first paint captures row 8.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 0), rt.chat_open_cursor_row);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    _ = try L.provideTermBytes(&rt, &ctx);
    try testing.expectEqual(@as(u16, 8), rt.chat_open_cursor_row);
    // Close leaves the snapshot intact — the close paint still
    // needs it to know where to restore.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 8), rt.chat_open_cursor_row);

    // Re-open with no cursor_row available — toggle resets to 0,
    // first paint writes 0 (the null fallback).
    ctx.cursor_row = null;
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 0), rt.chat_open_cursor_row);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const reopened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(reopened != null);
    try testing.expectEqual(@as(u16, 0), rt.chat_open_cursor_row);
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
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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

    // First open + first paint captures row 8.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    _ = try L.provideTermBytes(&rt, &ctx);
    try testing.expectEqual(@as(u16, 8), rt.chat_open_cursor_row);
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);

    // Re-open at a different row. Toggle resets snapshot to 0,
    // first paint captures the new value.
    ctx.cursor_row = 12;
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 0), rt.chat_open_cursor_row);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const reopened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(reopened != null);
    try testing.expectEqual(@as(u16, 12), rt.chat_open_cursor_row);
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
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
    // Toggle defers — snapshot still 0.
    try testing.expectEqual(@as(u16, 0), rt.chat_open_cursor_row);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);

    const first = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(first != null);
    // First paint captured 10. The restore CUP is the LAST bytes
    // the paint emits.
    try testing.expectEqual(@as(u16, 10), rt.chat_open_cursor_row);
    try testing.expect(std.mem.endsWith(u8, first.?, "\x1B[10;1H"));

    // Live cursor drifts (shell printed output between ticks).
    // Snapshot must NOT update on subsequent paints — the lazy
    // capture only fires when the sentinel is 0.
    ctx.cursor_row = 5;
    rt.chat_inline_paint_pending = true;
    const second = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(second != null);
    try testing.expect(std.mem.endsWith(u8, second.?, "\x1B[10;1H"));
    try testing.expectEqual(@as(u16, 10), rt.chat_open_cursor_row);
}

test "provideTermBytes emits OSC 12 on prefix-match edge, OSC 112 on un-match" {
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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

test "overlay: assistant_exec turn renders structured (description + `$ command`) instead of raw JSON" {
    // Regression guard: the structured renderer must split the
    // envelope into description + indented cyan command and never
    // leak the raw `{"action":"exec",...}` JSON to the user.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "list zig files"));
    const envelope = "{\"action\":\"exec\",\"description\":\"find Zig sources\",\"command\":\"find . -name '*.zig'\"}";
    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, envelope));

    rt.chat_overlay_open = true;
    rt.chat_overlay_paint_pending = true;
    const bytes = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(bytes != null);
    // Description visible.
    try testing.expect(std.mem.indexOf(u8, bytes.?, "find Zig sources") != null);
    // Command rendered as `$ <cmd>` on its own row.
    try testing.expect(std.mem.indexOf(u8, bytes.?, "$ ") != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "find . -name '*.zig'") != null);
    // The raw JSON envelope MUST NOT appear verbatim in the paint
    // (no `"action":"exec"` substring).
    try testing.expect(std.mem.indexOf(u8, bytes.?, "\"action\":\"exec\"") == null);
}

test "overlay: assistant_exec with action=done renders ✓ + reason (no raw JSON)" {
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
    const envelope = "{\"action\":\"done\",\"reason\":\"task complete: 42 files\"}";
    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, envelope));

    rt.chat_overlay_open = true;
    rt.chat_overlay_paint_pending = true;
    const bytes = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(bytes != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "\u{2713}") != null); // check glyph
    try testing.expect(std.mem.indexOf(u8, bytes.?, "task complete: 42 files") != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "\"action\":\"done\"") == null);
}

test "overlay: malformed assistant envelope falls back to raw render so nothing vanishes" {
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
    // Has `"action"` key (passes shape check) but JSON is broken.
    const envelope = "{\"action\":NOPE this isn't valid";
    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, envelope));

    rt.chat_overlay_open = true;
    rt.chat_overlay_paint_pending = true;
    const bytes = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(bytes != null);
    // Raw content still surfaces — the user sees what the model emitted.
    try testing.expect(std.mem.indexOf(u8, bytes.?, "NOPE this isn't valid") != null);
}

test "overlay: assistant_exec with action=question + choices renders italic prompt + numbered list" {
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
    const envelope =
        "{\"action\":\"question\",\"question\":\"Which directory?\",\"choices\":[\"src\",\"tests\",\"docs\"]}";
    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, envelope));

    rt.chat_overlay_open = true;
    rt.chat_overlay_paint_pending = true;
    const bytes = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(bytes != null);
    // Italic SGR + prompt text + numbered choices.
    try testing.expect(std.mem.indexOf(u8, bytes.?, "\x1B[3m") != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "Which directory?") != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "1.") != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "2.") != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "3.") != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "src") != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "tests") != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "docs") != null);
    // Raw JSON envelope must NOT leak.
    try testing.expect(std.mem.indexOf(u8, bytes.?, "\"choices\"") == null);
}

test "overlay input: cursor-split rendering puts reverse-video on the cursor byte" {
    // Invariant: when the cursor is mid-buffer the byte UNDER the
    // cursor renders inside `\x1B[7m...\x1B[0m` (reverse video),
    // not duplicated in the tail. At end-of-buffer the cursor
    // collapses to a reverse-video space.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
    try testing.expect(std.mem.indexOf(u8, bytes.?, "\u{2191} 2 below") != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "Ctrl+End") != null);

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

test "inline chat: open paint CUP-restores to (row, col) snapshot — not col 1" {
    // Regression guard: pre-cursor_col-tracking, the close paint
    // emitted `\x1B[<row>;1H` which landed bash's next echo at the
    // start of the prompt row, on top of the PS1 chrome. With the
    // snapshot now capturing the prompt-end column from OSC 133
    // `;B`, the restore CUP includes the col so the cursor parks
    // where bash's input region begins.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
        .cursor_col = 4, // e.g. cursor after `~ ) ` prompt
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    // Toggle defers — snapshot still 0/0.
    try testing.expectEqual(@as(u16, 0), rt.chat_open_cursor_row);
    try testing.expectEqual(@as(u16, 0), rt.chat_open_cursor_col);

    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const opened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(opened != null);
    // First paint captured row 8 + col 4.
    try testing.expectEqual(@as(u16, 8), rt.chat_open_cursor_row);
    try testing.expectEqual(@as(u16, 4), rt.chat_open_cursor_col);
    // CUP must include BOTH row and col.
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[8;4H") != null);
    // The legacy col-1 form must NOT appear at that row.
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[8;1H") == null);

    // Close also uses (row, col).
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    const closed = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(closed != null);
    try testing.expect(std.mem.indexOf(u8, closed.?, "\x1B[8;4H") != null);
}

test "inline chat: col snapshot 0 → falls back to col 1" {
    // When `ctx.cursor_col` is null at first paint (cursor_tracker
    // unwired / non-TTY), the snapshot stays 0 and the restore
    // CUP uses col 1 as a defensive default. Existing tests that
    // don't set cursor_col rely on this fallback.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
        // cursor_col left null
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 0), rt.chat_open_cursor_col);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const opened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(opened != null);
    // First paint captured row 8 + col 0 (null cursor_col).
    try testing.expectEqual(@as(u16, 0), rt.chat_open_cursor_col);
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[8;1H") != null);
}

test "inline chat scrollback: newest turn stays visible when prior turns wrap multiple rows" {
    // Regression for the start_turn back-walk fix — with multi-row
    // wrapping turns and a tight scrollback budget, the OLDEST
    // visible turn must get clipped, not the newest. Previous
    // `visible_end - scrollback_budget` math anchored the wrong end
    // because it assumed one row per turn.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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

    // FOUR turns sized to exercise the budget-pressure path:
    //   • long_a/b/c wrap to MORE than per_turn_max_rows (3) so
    //     each one's `countTurnRows` returns the cap of 3.
    //   • long_d wraps to EXACTLY 3 chunks with the marker in the
    //     3rd. If the render loop incorrectly caps long_d to 2
    //     rows (the pre-fix behaviour, where the generic
    //     `min(per_turn_max_rows, remaining_rows)` ate the deficit
    //     from the NEWEST turn instead of the oldest), `[…]` lands
    //     on row 2 and the marker never gets emitted.
    // Default budget at terminal_rows=24 / cfg.inline_chat_rows=10
    // is 8 scrollback rows; 4 × 3-row turns = 12 demand, so the
    // back-walk includes 3 of 4 turns with oldest_turn_cap = 2.
    const long_a = "AAAA " ** 80;
    const long_b = "BBBB " ** 80;
    const long_c = "CCCC " ** 80;
    // 28 × "DDDD " (140 bytes) wraps to two 69-byte chunks; the
    // marker (15 chars, no spaces) becomes chunk 3 — fits in the
    // 3-row budget cleanly.
    const long_d = "DDDD " ** 28 ++ "NEWEST-MARKER-D";
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, long_a));
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, long_b));
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, long_c));
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, long_d));
    defer helpers.freeTurns(&rt);

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const painted = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(painted != null);

    // The newest turn's distinctive marker — placed at the END of
    // ~3 wrap rows of content — MUST be in the paint output. Both
    // bug variants (pre-back-walk and post-back-walk render-loop
    // cap mis-allocation) would have clipped it off.
    try testing.expect(std.mem.indexOf(u8, painted.?, "NEWEST-MARKER-D") != null);
}

test "inline chat: long turn renders in full, not capped at 3 rows" {
    // Regression for "no wrap, it cuts of [...]" — a single long
    // assistant reply was getting clipped at 3 rows because of a
    // hardcoded `per_turn_max_rows = 3`. The per-turn cap is
    // dropped entirely: each turn renders its full wrap count up
    // to the scrollback budget; older turns scroll off the top
    // and PageUp/PageDown walks history.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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

    // 5+ wrap chunks of distinct content. Each tagged with a
    // sentinel so we can assert the LAST chunk lands in the paint
    // output — pre-fix, anything past the 3rd chunk got dropped
    // and a `[…]` marker emitted instead.
    const content =
        "AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA AAAA " ++
        "BBBB BBBB BBBB BBBB BBBB BBBB BBBB BBBB BBBB BBBB BBBB BBBB BBBB BBBB " ++
        "CCCC CCCC CCCC CCCC CCCC CCCC CCCC CCCC CCCC CCCC CCCC CCCC CCCC CCCC " ++
        "DDDD DDDD DDDD DDDD DDDD DDDD DDDD DDDD DDDD DDDD DDDD DDDD DDDD DDDD " ++
        "EEEE-LAST-CHUNK-MARKER";
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, content));
    defer helpers.freeTurns(&rt);

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const painted = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(painted != null);

    // Marker at the END of the content MUST be visible — the
    // hardcoded 3-row cap that used to drop it is gone.
    try testing.expect(std.mem.indexOf(u8, painted.?, "EEEE-LAST-CHUNK-MARKER") != null);
}

test "inline chat: em-dash and emoji survive writeSanitized (no `�` rendering)" {
    // Regression for "espond — not the mai" rendering as
    // "espond � not the mai" — the byte-level C1 filter in
    // writeSanitized was dropping continuation bytes that
    // happened to fall in 0x80..0x9F, corrupting any 3- or
    // 4-byte UTF-8 sequence that needed those bytes. Em-dash
    // (U+2014 = 0xE2 0x80 0x94) is the easiest trigger because
    // its middle continuation byte is exactly 0x80. The fix
    // walks codepoints and only drops C1 controls AFTER decode.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
    // Em-dash, bullet, sparkle emoji, CJK — every one of these
    // has at least one continuation byte in 0x80..0x9F.
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "respond \u{2014} not the main \u{2022} \u{2728} \u{4E2D}"));
    defer helpers.freeTurns(&rt);

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const painted = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(painted != null);

    // Each multibyte glyph survives intact (full UTF-8 byte
    // sequence present in the paint output, no replacement char).
    try testing.expect(std.mem.indexOf(u8, painted.?, "\u{2014}") != null);
    try testing.expect(std.mem.indexOf(u8, painted.?, "\u{2022}") != null);
    try testing.expect(std.mem.indexOf(u8, painted.?, "\u{2728}") != null);
    try testing.expect(std.mem.indexOf(u8, painted.?, "\u{4E2D}") != null);
    // No replacement char in the output.
    try testing.expect(std.mem.indexOf(u8, painted.?, "\u{FFFD}") == null);
}

test "inline chat chrome: divider trailing-hint shows close/send; statusbar carries Alt+T / Alt+M" {
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
        .terminal_cols = 100,
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const painted = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(painted != null);

    // Divider trailing hint = close/send only (structural shortcuts).
    try testing.expect(std.mem.indexOf(u8, painted.?, "Alt+C") != null);
    try testing.expect(std.mem.indexOf(u8, painted.?, "Enter") != null);
    // Statusbar carries the mode/provider toggles.
    const status_hint = try L.statusText(&rt, &ctx);
    try testing.expect(status_hint != null);
    try testing.expect(std.mem.indexOf(u8, status_hint.?, "Alt+T") != null);
    try testing.expect(std.mem.indexOf(u8, status_hint.?, "Alt+M") != null);
    // Auto mode is OFF — mode word has no `(auto)` annotation.
    try testing.expect(std.mem.indexOf(u8, painted.?, "(auto") == null);
}

test "inline chat chrome: auto-on flips mode word to `atty chat (auto)`" {
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
        .terminal_cols = 100,
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    rt.auto_mode_active = true;
    rt.chat_inline_paint_pending = true;
    const painted = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(painted != null);
    try testing.expect(std.mem.indexOf(u8, painted.?, "atty chat (auto)") != null);
}

test "inline chat chrome: progressive trailing-hint shrinks on narrow terminal" {
    // The full hint is ~51 cols. With a narrow terminal + the
    // `(auto, incognito)` mode word, the chrome shouldn't overrun
    // — progressively shrinks to medium (38) or short (22) form
    // depending on how much room is left after the mode word +
    // provider label.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
        .incognito = true,
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    rt.auto_mode_active = true;
    rt.chat_inline_paint_pending = true;
    const painted = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(painted != null);

    // Mode word reflects both flags.
    try testing.expect(std.mem.indexOf(u8, painted.?, "atty chat (auto, incognito)") != null);
    // Divider trailing hint still has the structural shortcuts.
    try testing.expect(std.mem.indexOf(u8, painted.?, "Alt+C") != null);
}

test "inline chat: long done-action reason renders in full, not capped at one row's cols" {
    // Regression for user bug after #212 landed — a `done`-action
    // envelope with a multi-paragraph reason was getting clipped
    // at `max_inline_visible` cols (~74 for 80-col terminal) by
    // `truncateToCols(r, max_visible)` in `renderTurnContent`'s
    // .done arm. The cap was designed for short exec commands
    // (where 74 cols of cmd is plenty) but is far too tight for
    // a long-form LLM reply — the user's 520-word essay cut at
    // ~700 chars with NO truncation marker (because the inline
    // path's marker is appended but the user's terminal is
    // small enough the cut happens before any marker would show
    // anyway).
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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

    // 800-char done reason — well past the ~74-col inline cap.
    // Mid-text sentinel proves the WHOLE reason rendered. End-of-
    // text sentinel locks down the final chars. Single line (no
    // \n) is the worst case for column-truncation.
    const long_reason =
        "The terminal has always been more than a utility - it is a philosophy made manifest. " ++
        "In the early days of computing, the interface between human and machine was purely textual: " ++
        "a blinking cursor, a prompt, MID-SENTINEL a conversation conducted in commands. " ++
        "There is a particular pleasure in software that knows exactly what it is. " ++
        "Not the sprawling framework that promises to solve every problem if you only learn its idioms " ++
        "deeply enough, but the small tool, the one that does one thing and refuses to do anything else. END-SENTINEL";
    var envelope_buf: [2048]u8 = undefined;
    const envelope = try std.fmt.bufPrint(
        &envelope_buf,
        "{{\"action\":\"done\",\"reason\":\"{s}\"}}",
        .{long_reason},
    );

    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, envelope));
    defer helpers.freeTurns(&rt);

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const painted = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(painted != null);

    // Both sentinels must appear — the cap that clipped at ~74
    // cols would drop MID-SENTINEL too. The whole reason wraps
    // across multiple rows; the terminal handles wrap naturally.
    try testing.expect(std.mem.indexOf(u8, painted.?, "MID-SENTINEL") != null);
    try testing.expect(std.mem.indexOf(u8, painted.?, "END-SENTINEL") != null);
    // The dim "[…]" truncation marker MUST NOT appear — that
    // would mean truncateToCols clipped the content.
    try testing.expect(std.mem.indexOf(u8, painted.?, "\u{2026}]") == null);
}

test "chat overlay: long done-action reason renders in full, not capped at 480 cols" {
    // Sibling test for the overlay path. `renderOverlayTurnContent`
    // capped done reasons at `overlay_field_cap = 480` cols. 480
    // is much wider than the inline cap but still hits realistic
    // LLM reply lengths (a 600-word reply is ~3500 chars).
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
        .terminal_rows = 40,
        .terminal_cols = 100,
    };

    const helpers = dialog.Module(L.config, L.Runtime);

    // 1500-char reason — well past 480-col overlay cap. Sentinels
    // span the front, middle, and tail so any clip is detected.
    var long_buf: [1500]u8 = undefined;
    @memset(&long_buf, 'x');
    const front_marker = "FRONT-SENTINEL";
    const mid_marker = "MIDDLE-SENTINEL";
    const tail_marker = "TAIL-SENTINEL";
    std.mem.copyForwards(u8, long_buf[0..front_marker.len], front_marker);
    std.mem.copyForwards(u8, long_buf[700..(700 + mid_marker.len)], mid_marker);
    std.mem.copyForwards(u8, long_buf[(long_buf.len - tail_marker.len)..], tail_marker);

    var envelope_buf: [2048]u8 = undefined;
    const envelope = try std.fmt.bufPrint(
        &envelope_buf,
        "{{\"action\":\"done\",\"reason\":\"{s}\"}}",
        .{long_buf[0..]},
    );

    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, envelope));
    defer helpers.freeTurns(&rt);

    // Open the chat overlay (Alt+Shift+C). Paint via provideTermBytes.
    _ = try L.onAction(&rt, &ctx, .llm_chat_overlay_toggle);
    const painted = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(painted != null);

    // All three sentinels must appear in the rendered overlay.
    try testing.expect(std.mem.indexOf(u8, painted.?, front_marker) != null);
    try testing.expect(std.mem.indexOf(u8, painted.?, mid_marker) != null);
    try testing.expect(std.mem.indexOf(u8, painted.?, tail_marker) != null);
    // Truncation marker must NOT appear.
    try testing.expect(std.mem.indexOf(u8, painted.?, "\u{2026}]") == null);
}

test "inline chat: multi-newline done reason — back-walk anchor reserves enough rows" {
    // Regression for the countTurnRows under-count bug Copilot caught
    // in round 1 of PR #212. Previously: WrapIter over the raw JSON
    // envelope counted `\n` JSON escapes as 2 literal chars on a
    // single line. The actual render parses the envelope, feeds the
    // reason to md_render which hard-breaks on each `\n` —
    // emitting more rows than the estimator predicted. The back-
    // walk then picked `start_turn` thinking the newest turn took
    // FEWER rows than it actually does, and the older neighbour
    // ate scrollback that should have gone to the newest turn.
    //
    // Worked example: a reason with 4 embedded `\n` characters
    // becomes 5 hard-broken rows after parsing. WrapIter on the raw
    // envelope (which has `\\n` as the 2-char JSON encoding) sees
    // those as inline chars on ~1-2 wrap rows. Estimator was off
    // by ~3-4 rows; with limited scrollback the newest turn's
    // tail got clipped.
    //
    // Test setup: an OLDER user turn (small) + a newer assistant
    // done envelope with 5 embedded `\n` separators. Asserts the
    // TAIL sentinel of the newest reason still appears in the
    // paint output — proving the back-walk reserved enough rows
    // for it.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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

    // Older user turn — small. The assistant turn that follows is
    // the newest; back-walk should reserve enough rows for it.
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(
        u8,
        "tell me about something with multiple paragraphs",
    ));

    // Assistant done envelope with 5 `\n` escapes — JSON-encoded.
    // Each `\\n` in the source string is a literal `\n` JSON escape
    // (two bytes in the envelope content), which the parser
    // converts to a real newline. md_render then hard-breaks on
    // each newline → 6 separate rows of content.
    const envelope =
        "{\"action\":\"done\",\"reason\":\"" ++
        "Para1 head FRONT-SENTINEL\\n" ++
        "Para2 middle\\n" ++
        "Para3 body content\\n" ++
        "Para4 more body\\n" ++
        "Para5 nearing end\\n" ++
        "Para6 tail TAIL-SENTINEL\"}";
    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, envelope));
    defer helpers.freeTurns(&rt);

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const painted = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(painted != null);

    // TAIL-SENTINEL is on the LAST row of the newest turn. Pre-fix
    // (under-count), the back-walk thought the assistant turn fit
    // in ~2 rows, gave the older user turn too many, and clipped
    // off the tail of the assistant turn. Post-fix, the escape
    // count adds 5 rows to the estimate so back-walk reserves
    // enough room.
    try testing.expect(std.mem.indexOf(u8, painted.?, "TAIL-SENTINEL") != null);
}
