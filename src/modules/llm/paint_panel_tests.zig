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
    // Proposal-G timeline rail: user turns prefix with the ◆
    // glyph instead of an explicit "You:" label (icons disclose
    // the side).
    try testing.expect(std.mem.indexOf(u8, opened.?, "\u{25C6}") != null);
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

test "inline chat: question pick-list renders ▶ + numbered rows + truncation" {
    // Regression pin for #308 + Copilot review: inline panel renders
    // a numbered choice list above the input row when
    // chat_question_active fires, selects with ▶, truncates long
    // choices to the panel width, and slides the visible window so
    // the selected choice stays in view even when question_rows
    // is capped below choice_count.
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
        .terminal_cols = 40,
    };

    // Open the panel + grow the reservation so paintInlineChat has
    // room for the picker above the input row.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);

    // Stage question state directly — production code populates
    // these on dialog parse; the test bypasses the parser.
    rt.chat_question_active = true;
    rt.chat_question_choice_count = 3;
    rt.chat_question_selected_idx = 1; // middle option
    const choices = [_][]const u8{
        "first option",
        "second option (selected)",
        "third option goes here and should be safely truncated when narrower than the panel",
    };
    for (choices, 0..) |c, idx| {
        const dst = rt.question_choices_storage[idx][0..@min(c.len, rt.question_choices_storage[idx].len)];
        @memcpy(dst, c[0..dst.len]);
        rt.question_choices_lens[idx] = dst.len;
    }
    rt.chat_inline_paint_pending = true;

    const out_opt = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(out_opt != null);
    const out = out_opt.?;

    // Numbered prefixes for all three choices.
    try testing.expect(std.mem.indexOf(u8, out, "1. ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2. ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3. ") != null);
    // Selected row carries the mauve ▶ glyph.
    try testing.expect(std.mem.indexOf(u8, out, "\u{25B6}") != null);
    // Truncation: the long third choice must NOT appear in full —
    // panel cols=40 minus prefix=5 = 35-col budget; full text is
    // ~80 chars.
    try testing.expect(std.mem.indexOf(u8, out, "safely truncated when narrower") == null);
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
