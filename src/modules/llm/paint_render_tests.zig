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

test "overlay: assistant_exec turn renders as `╭ exec ─` box (Proposal G), no raw JSON" {
    // Regression guard: the structured renderer must split the
    // envelope into the timeline-rail box (`╭ exec ─` opener +
    // command row) and never leak the raw `{"action":"exec",...}`
    // JSON. Mirrors the inline panel's exec rendering — both
    // surfaces share the same visual vocabulary so recall + view
    // switching stays consistent.
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
    // Fenced reply — matches the production protocol
    // (hooks.parseDialogResponse → parseFencedResponse).
    const envelope = "find Zig sources\n\n```exec\nfind . -name '*.zig'\n```\n";
    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, envelope));

    rt.chat_overlay_open = true;
    rt.chat_overlay_paint_pending = true;
    const bytes = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(bytes != null);
    // Box opener present, command visible, description dropped.
    try testing.expect(std.mem.indexOf(u8, bytes.?, "\u{256D} exec \u{2500}") != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "find . -name '*.zig'") != null);
    // Raw fence markers must NOT leak into the paint.
    try testing.expect(std.mem.indexOf(u8, bytes.?, "```exec") == null);
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
    // Pure-prose reply — parseFencedResponse degrades to .done with
    // reason = full prose. No fence needed.
    const envelope = "task complete: 42 files";
    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, envelope));

    rt.chat_overlay_open = true;
    rt.chat_overlay_paint_pending = true;
    const bytes = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(bytes != null);
    try testing.expect(std.mem.indexOf(u8, bytes.?, "\u{2713}") != null); // check glyph
    try testing.expect(std.mem.indexOf(u8, bytes.?, "task complete: 42 files") != null);
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
        "```question\nWhich directory?\n- src\n- tests\n- docs\n```\n";
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
    // Raw fence markers must NOT leak.
    try testing.expect(std.mem.indexOf(u8, bytes.?, "```question") == null);
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
    // `chat_inline_view_offset > 0` the row-window walker (per
    // #213's per-row refactor) must drop newest content from the
    // bottom + the first scrollback row must carry the dim
    // "↑ N below" header. Tight 3-row budget so 3 single-row
    // turns overflow and the offset has somewhere to scroll to.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .inline_chat_rows = 5,
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
