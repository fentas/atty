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
    // Locks in the inline-panel render path for a multi-paragraph
    // `done`-action reason. An earlier shape capped the reason at
    // `max_inline_visible` cols (~74 for 80-col terminal) via
    // `truncateToCols`, designed for short exec commands but far
    // too tight for a long-form LLM reply — a multi-paragraph
    // essay would clip silently at the cap with no truncation
    // marker visible on a typical terminal.
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
    // Pure-prose reply — parseFencedResponse degrades to .done
    // with the whole content as reason. Matches the production
    // shape for a fence-less LLM reply.
    const envelope =
        "The terminal has always been more than a utility - it is a philosophy made manifest. " ++
        "In the early days of computing, the interface between human and machine was purely textual: " ++
        "a blinking cursor, a prompt, MID-SENTINEL a conversation conducted in commands. " ++
        "There is a particular pleasure in software that knows exactly what it is. " ++
        "Not the sprawling framework that promises to solve every problem if you only learn its idioms " ++
        "deeply enough, but the small tool, the one that does one thing and refuses to do anything else. END-SENTINEL";

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

    // Pure-prose reply — same shape rationale as the inline
    // sibling test above. parseFencedResponse turns this into
    // .done with reason = whole content.
    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, long_buf[0..]));
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
    // Locks in the countTurnRows row-estimate behaviour for done
    // replies with embedded newlines. countTurnRows now calls
    // parseFencedResponse and uses md_render.countRows on the
    // resulting reason — under-counting would clip the newest
    // turn's tail under back-walk pressure.
    //
    // Fixture: 6 older user turns (1 row each) + a newer assistant
    // pure-prose reply spanning 6 hard-break rows. Without a
    // matching row estimate the back-walk would include too many
    // older turns and clip TAIL-SENTINEL.
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

    // Six older user turns (1 row each) putting the scrollback
    // budget under real pressure. Each is short so it claims
    // exactly 1 row in countTurnRows.
    const olds = [_][]const u8{
        "older turn 1",
        "older turn 2",
        "older turn 3",
        "older turn 4",
        "older turn 5",
        "older turn 6",
    };
    for (olds) |s| {
        try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, s));
    }

    // Pure-prose reply with 5 hard breaks → 6 rows of content
    // after md_render. countTurnRows on this must return 6 so the
    // back-walk reserves enough budget; under-counting would clip
    // TAIL-SENTINEL.
    const envelope =
        "Para1 FRONT-SENTINEL\n" ++
        "Para2 middle\n" ++
        "Para3 body content\n" ++
        "Para4 more body\n" ++
        "Para5 nearing end\n" ++
        "Para6 TAIL-SENTINEL";
    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, envelope));
    defer helpers.freeTurns(&rt);

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const painted = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(painted != null);

    // TAIL-SENTINEL is on the LAST row of the assistant turn.
    // countTurnRows must report 6 (md_render row count over the
    // .done reason); an under-count would clip TAIL under the
    // back-walk's row-budget pressure.
    try testing.expect(std.mem.indexOf(u8, painted.?, "TAIL-SENTINEL") != null);
}

test "inline scroll: per-row offset scrolls THROUGH a single tall turn" {
    // Per-#213: when a single turn is taller than the visible
    // panel, the per-row offset must walk it row-by-row. The
    // top of the turn becomes visible as offset grows; the
    // kind-prefix (the ◇ glyph) suppresses when row 1 of the turn
    // is above the cut.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .inline_chat_rows = 4,
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

    // Pure prose reply — parseFencedResponse with no fence
    // degrades to .done with the whole content as the reason.
    // Each `\n` becomes one row; the panel budget (2 rows after
    // the input + divider) shows 2 at a time.
    const envelope = "P1-TOP\nP2-MID-A\nP3-MID-B\nP4-BOTTOM";
    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, envelope));

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);

    // Offset 0: tail visible (P4-BOTTOM at the bottom of the panel).
    rt.chat_inline_view_offset = 0;
    rt.chat_inline_paint_pending = true;
    const tail = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(tail != null);
    try testing.expect(std.mem.indexOf(u8, tail.?, "P4-BOTTOM") != null);
    try testing.expect(std.mem.indexOf(u8, tail.?, "P1-TOP") == null);

    // Offset 2: visible_end_row=total-2=2; indicator reserves
    // 1 row of the 2-row budget, visible_start_row=max(0,2-1)=1.
    // Window [1, 2) — md_render.renderWithSkip(skip=1, max=1)
    // emits exactly P2-MID-A. Bit-flip checks pin every other
    // row absent so an off-by-one in either bound flips fails.
    rt.chat_inline_view_offset = 2;
    rt.chat_inline_paint_pending = true;
    const mid = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(mid != null);
    try testing.expect(std.mem.indexOf(u8, mid.?, "\u{2191} 2 below") != null);
    try testing.expect(std.mem.indexOf(u8, mid.?, "P2-MID-A") != null);
    try testing.expect(std.mem.indexOf(u8, mid.?, "P1-TOP") == null);
    try testing.expect(std.mem.indexOf(u8, mid.?, "P3-MID-B") == null);
    try testing.expect(std.mem.indexOf(u8, mid.?, "P4-BOTTOM") == null);
}

test "inline chat: observation collapses to line-count stub when compact (#311)" {
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .inline_observation_compact = true,
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

    const helpers = dialog.Module(L.config, L.Runtime);
    defer helpers.freeTurns(&rt);
    const obs_content =
        "RUSTC_OUTPUT_LINE_1_should_not_appear\n" ++
        "RUSTC_OUTPUT_LINE_2_should_not_appear\n" ++
        "RUSTC_OUTPUT_LINE_3_should_not_appear";
    try helpers.pushTurn(&rt, .observation, try testing.allocator.dupe(u8, obs_content));

    rt.chat_inline_paint_pending = true;
    const out = (try L.provideTermBytes(&rt, &ctx)).?;

    // Compact stub (Proposal G phase 2) shows the line count and
    // the Linux-friendly `Alt+Shift+C` keychord. The earlier `⌥⇧C`
    // Mac glyphs read as foreign on the project's primary platform
    // and were swapped back to plain text.
    try testing.expect(std.mem.indexOf(u8, out, "3 lines") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Alt+Shift+C") != null);
    // ╰ corner closes the exec box visually (see `╭ exec ─` opener
    // pinned by the sibling test below). Without this assertion a
    // revision that drops the corner glyph would silently regress
    // the timeline-rail box closer.
    try testing.expect(std.mem.indexOf(u8, out, "\u{2570}") != null);
    // Verbatim content must NOT appear in the inline panel.
    try testing.expect(std.mem.indexOf(u8, out, "RUSTC_OUTPUT_LINE_1") == null);
    try testing.expect(std.mem.indexOf(u8, out, "RUSTC_OUTPUT_LINE_2") == null);
    try testing.expect(std.mem.indexOf(u8, out, "RUSTC_OUTPUT_LINE_3") == null);
}

test "inline chat: exec envelope renders as 2-row box with `\u{256D} exec \u{2500}` opener" {
    // Proposal G phase 2 pins the opener glyph so a revision that
    // changes the box style (or drops it altogether and reverts to
    // the old `<desc> \u{2192} <cmd>` one-liner) fails loudly.
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

    const helpers = dialog.Module(L.config, L.Runtime);
    defer helpers.freeTurns(&rt);

    // Fenced exec reply — production protocol shape.
    const envelope = "list files\n\n```exec\nls -la /tmp\n```\n";
    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, envelope));

    rt.chat_inline_paint_pending = true;
    const out = (try L.provideTermBytes(&rt, &ctx)).?;

    // Opener: `\u{256D} exec \u{2500}` (rounded-corner top-left, the
    // word "exec", a horizontal line).
    try testing.expect(std.mem.indexOf(u8, out, "\u{256D} exec \u{2500}") != null);
    // The command body must appear too.
    try testing.expect(std.mem.indexOf(u8, out, "ls -la /tmp") != null);
    // Description / fence markers are intentionally dropped.
    try testing.expect(std.mem.indexOf(u8, out, "list files") == null);
    try testing.expect(std.mem.indexOf(u8, out, "```exec") == null);
}

test "inline chat: compact OFF renders observation verbatim (#311)" {
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .inline_observation_compact = false,
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

    const helpers = dialog.Module(L.config, L.Runtime);
    defer helpers.freeTurns(&rt);
    try helpers.pushTurn(&rt, .observation, try testing.allocator.dupe(u8, "VERBATIM_SENTINEL"));

    rt.chat_inline_paint_pending = true;
    const out = (try L.provideTermBytes(&rt, &ctx)).?;

    try testing.expect(std.mem.indexOf(u8, out, "VERBATIM_SENTINEL") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Alt+Shift+C") == null);
}
