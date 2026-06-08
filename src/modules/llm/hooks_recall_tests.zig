//! Hooks-side tests for `modules/llm.zig` — exercise `onAction`
//! (chat-panel toggles, focus navigation, mutual-exclusion guards)
//! and `onInput` (key-swallow into chat input buffers). Setup
//! pieces call `L.attach` / `L.onAction` through the top-level
//! `configure()` factory in llm.zig.

const std = @import("std");
const testing = std.testing;

const mod = @import("../llm.zig");
const configure = mod.configure;
const m = @import("../../module.zig");
const dialog = mod.dialog_ns;
const hooks = @import("hooks.zig");
const shutdownAndFree = @import("test_helpers.zig").shutdownAndFree;

const test_io: std.Io = std.Io.failing;

test "inline chat: Alt+C refuses to open when terminal is too short for minimum layout" {
    // Before this gate, paintInlineChat's "live_reserve - base <
    // top_gap + 3" early-out fired on every Alt+C in a too-short
    // terminal, recoverInlineChatPaintFailure closed the panel AND
    // wrote a stderr line each time. Repeated Alt+C → repeated
    // stderr spam (screenshot from PR #392 review). The action
    // handler now refuses the open with a single statusbar hint
    // and no stderr.
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
        .terminal_rows = 6,
        .terminal_cols = 80,
        .statusbar_base_reserve = 3,
        .statusbar_reserve = 3,
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(!rt.chat_inline_open);
    // Re-trying must keep refusing without leaving stale state.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(!rt.chat_inline_open);
}

test "inline chat: Alt+C opens normally when terminal is exactly at the floor" {
    // Floor = base(3) + top_gap(1) + 3 + 1 = 8 rows. At 8 the panel
    // fits a divider + 1 scrollback row + input + a shell row.
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
        .terminal_rows = 8,
        .terminal_cols = 80,
        .statusbar_base_reserve = 3,
        .statusbar_reserve = 3,
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(rt.chat_inline_open);
}

test "inline chat: provideTermBytes skips paint when reserve hasn't caught up to fresh open" {
    // Bug reproduced from PR #392 review: the swallow_after_binding
    // drain (d5540f5) fires the panel paint immediately after Alt+C
    // sets `chat_inline_open = true`, BEFORE the proxy's top-of-
    // iteration `applyReserveRows` enlarges `sb.reserve_rows` for
    // the panel's `extraReserveRows`. In that window paintInlineChat
    // sees `ctx.statusbar_reserve = base_reserve` (stale, pre-open
    // value), hits the "live_reserve <= base_reserve" early-out,
    // recoverInlineChatPaintFailure closes the panel + writes a
    // stderr line. provideTermBytes now detects the transient
    // (open + wants extra rows + ctx still reports base only) and
    // returns null without clearing paint_pending — the next
    // iteration runs with the caught-up reserve and paints cleanly.
    const paint = @import("paint.zig");
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
        .terminal_rows = 30,
        .terminal_cols = 80,
        .statusbar_base_reserve = 3,
        .statusbar_reserve = 3, // proxy hasn't applied the panel's reserve yet
    };

    // Mimic the post-Alt+C state at the swallow_after_binding drain
    // site: panel is open, paint is pending, proxy hasn't caught up.
    rt.chat_inline_open = true;
    rt.chat_inline_paint_pending = true;

    const P = paint.Module(L.config, L.Runtime);
    const bytes = try P.provideTermBytes(&rt, &ctx);
    try testing.expect(bytes == null);
    // Crucially: paint_pending stays armed AND panel stays open.
    try testing.expect(rt.chat_inline_paint_pending);
    try testing.expect(rt.chat_inline_open);
}

test "Alt+M cycle arms chat panel repaint so divider shows the new provider" {
    // Regression: cycle_model bumped `current_provider_idx` and
    // emitted a statusbar hint, but never armed
    // `chat_inline_paint_pending` / `chat_overlay_paint_pending`.
    // The divider in `paintInlineChat` reads
    // `resolveProviderForMode(.chat, …)` on every paint, so the
    // updated provider only surfaces once SOMETHING else triggers
    // a repaint — until then the panel chrome shows the stale name.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .providers = &.{
            .{ .name = "a", .config = .{ .http = .{ .api_base = "http://a/", .api_base_env = "ATTY_TEST_NEVER", .api_base_fallback_env = "ATTY_TEST_NEVER", .api_key_env = "ATTY_TEST_NEVER" } } },
            .{ .name = "b", .config = .{ .http = .{ .api_base = "http://b/", .api_base_env = "ATTY_TEST_NEVER", .api_base_fallback_env = "ATTY_TEST_NEVER", .api_key_env = "ATTY_TEST_NEVER" } } },
        },
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

    rt.chat_inline_open = true;
    rt.chat_inline_paint_pending = false;
    try testing.expectEqual(@as(usize, 0), rt.current_provider_idx);

    const consumed = try L.onAction(&rt, &ctx, .llm_exec_cycle_model);
    try testing.expect(consumed);
    try testing.expectEqual(@as(usize, 1), rt.current_provider_idx);
    try testing.expect(rt.chat_inline_paint_pending);

    // Overlay arm also fires when the overlay is the surface in
    // use (mutual exclusion in practice but the cycle handler
    // checks both flags independently — defensive).
    rt.chat_inline_open = false;
    rt.chat_overlay_open = true;
    rt.chat_overlay_paint_pending = false;
    _ = try L.onAction(&rt, &ctx, .llm_exec_cycle_model);
    try testing.expect(rt.chat_overlay_paint_pending);
}

test "Alt+T chat_toggle_auto flips auto_mode_active when chat surface is open" {
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

    // No chat surface open → action declines so the keystroke can
    // flow elsewhere.
    try testing.expectEqual(false, try L.onAction(&rt, &ctx, .llm_chat_toggle_auto));
    try testing.expectEqual(false, rt.auto_mode_active);

    // Inline chat open → toggles + arms paint latch.
    rt.chat_inline_open = true;
    rt.chat_inline_paint_pending = false;
    try testing.expectEqual(true, try L.onAction(&rt, &ctx, .llm_chat_toggle_auto));
    try testing.expectEqual(true, rt.auto_mode_active);
    try testing.expectEqual(true, rt.chat_inline_paint_pending);

    // Second press flips back off.
    rt.chat_inline_paint_pending = false;
    _ = try L.onAction(&rt, &ctx, .llm_chat_toggle_auto);
    try testing.expectEqual(false, rt.auto_mode_active);
    try testing.expectEqual(true, rt.chat_inline_paint_pending);
}

test "chat_scroll_to_tail snaps inline_view_offset to 0 when focus is in panel" {
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

    // Not in any chat surface → action declines so End passes
    // through to the shell.
    rt.chat_inline_view_offset = 5;
    try testing.expectEqual(false, try L.onAction(&rt, &ctx, .chat_scroll_to_tail));
    try testing.expectEqual(@as(usize, 5), rt.chat_inline_view_offset);

    // Inline open + focus parked on shell → also declines (End
    // belongs to the shell when the panel doesn't have focus).
    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = false;
    try testing.expectEqual(false, try L.onAction(&rt, &ctx, .chat_scroll_to_tail));
    try testing.expectEqual(@as(usize, 5), rt.chat_inline_view_offset);

    // Focus moves into panel → consumes + snaps offset to 0 + arms
    // paint.
    rt.chat_focus_in_panel = true;
    rt.chat_inline_paint_pending = false;
    try testing.expectEqual(true, try L.onAction(&rt, &ctx, .chat_scroll_to_tail));
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_view_offset);
    try testing.expectEqual(true, rt.chat_inline_paint_pending);

    // Already at tail → still consumes (key stays inside the
    // panel) but paint stays unarmed for the no-op case.
    rt.chat_inline_paint_pending = false;
    try testing.expectEqual(true, try L.onAction(&rt, &ctx, .chat_scroll_to_tail));
    try testing.expectEqual(false, rt.chat_inline_paint_pending);
}

test "chat_recall: loads a pre-existing dialog file end-to-end" {
    // Stages a JSONL file in chat_persist_dir, fires Alt+R via
    // onAction, asserts the load loop populated rt.turns +
    // conclusion + opened the inline panel.
    //
    // Fixed dir — comptime cfg requires a literal string, and
    // Zig's test runner is single-threaded within a process so
    // sequential tests don't race on /tmp paths. Per-test
    // suffix would still be useful for parallel `zig test` runs;
    // not addressed here since the dev workflow is sequential.
    const dir: []const u8 = "/tmp/atty-recall-load-test";
    const dz = try testing.allocator.dupeZ(u8, dir);
    defer testing.allocator.free(dz);
    const dialog_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/20260101T000000-aaaaaa.jsonl",
        .{dir},
    );
    // Pre-cleanup: unlink the staged file from a possible prior
    // crashed run (so the rmdir below isn't blocked by ENOTEMPTY),
    // then drop the dir, then recreate clean.
    const pre_dpz = try testing.allocator.dupeZ(u8, dialog_path);
    _ = std.c.unlink(pre_dpz.ptr);
    testing.allocator.free(pre_dpz);
    _ = std.c.rmdir(dz.ptr);
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(dz.ptr, 0o700));
    defer testing.allocator.free(dialog_path);
    const dpz = try testing.allocator.dupeZ(u8, dialog_path);
    defer testing.allocator.free(dpz);
    const fd = std.c.open(dpz.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c_uint, 0o600));
    try testing.expect(fd >= 0);
    const payload =
        "{\"kind\":\"user\",\"content\":\"list files\"}\n" ++
        "{\"kind\":\"assistant_exec\",\"content\":\"{\\\"action\\\":\\\"exec\\\",\\\"command\\\":\\\"ls\\\"}\"}\n" ++
        "{\"kind\":\"observation\",\"content\":\"a.txt\\nb.txt\"}\n" ++
        "{\"kind\":\"conclusion\",\"content\":\"\u{2713} done\"}\n";
    _ = std.c.write(fd, payload.ptr, payload.len);
    _ = std.c.close(fd);
    // Defers run LIFO — declare rmdir BEFORE unlink so unlink
    // fires first (removes the file) and rmdir runs second
    // (against the now-empty directory). Otherwise rmdir hits
    // ENOTEMPTY and leaves the test dir behind.
    defer _ = std.c.rmdir(dz.ptr);
    defer _ = std.c.unlink(dpz.ptr);

    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .chat_persist_enabled = true,
        .chat_persist_dir = dir,
    });

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();
    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);
    const helpers = dialog.Module(L.config, L.Runtime);
    defer helpers.freeTurns(&rt);

    var line: @import("../../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = real_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
        .statusbar_reserve = 2, // satisfy the chat_recall statusbar guard
    };

    // Alt+R opens the picker (NOT the load directly — the picker
    // overlay UI landed in PR 2c after the initial recall slice).
    const consumed = try L.onAction(&rt, &ctx, .chat_recall);
    try testing.expect(consumed);
    try testing.expect(rt.chat_recall_open);
    try testing.expectEqual(@as(usize, 1), rt.chat_recall_items.len);
    try testing.expect(rt.chat_recall_paint_pending);

    // Press Enter on the picker — fires the load + opens inline.
    const Action = @import("../../keymap.zig").Action;
    _ = Action;
    _ = try L.onInput(&rt, &ctx, "\r");
    try testing.expect(!rt.chat_recall_open);
    try testing.expect(rt.chat_inline_open);
    try testing.expect(rt.chat_focus_in_panel);
    try testing.expectEqual(@as(usize, 3), rt.turns_len);
    try testing.expect(rt.conclusion_formatted != null);
    if (rt.conclusion_formatted) |c| {
        try testing.expect(std.mem.indexOf(u8, c, "done") != null);
    }
    try testing.expect(rt.hint_pending);
    rt.hint_pending = false;

    // dialogReset on rt cleanup expects conclusion freed by detach;
    // shutdownAndFree handles chat_persist_path/dir but doesn't
    // free the heap-owned conclusion banner.
    if (rt.conclusion_formatted) |c| {
        testing.allocator.free(c);
        rt.conclusion_formatted = null;
    }
}

test "chat_recall: loaded assistant_exec envelope renders with the timeline-rail box" {
    // Pins the contract that a recalled dialog's historical
    // assistant_exec turns flow through the SAME paint path as
    // freshly-pushed turns — the `╭ exec ─` opener must appear
    // for both. Catches a future regression where the recall
    // path might cache a pre-rendered string instead of the
    // envelope JSON, freezing recalled turns at the old style.
    const dir: []const u8 = "/tmp/atty-recall-render-test";
    const dz = try testing.allocator.dupeZ(u8, dir);
    defer testing.allocator.free(dz);
    const dialog_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/20260101T000000-bbbbbb.jsonl",
        .{dir},
    );
    const pre_dpz = try testing.allocator.dupeZ(u8, dialog_path);
    _ = std.c.unlink(pre_dpz.ptr);
    testing.allocator.free(pre_dpz);
    _ = std.c.rmdir(dz.ptr);
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(dz.ptr, 0o700));
    defer testing.allocator.free(dialog_path);
    const dpz = try testing.allocator.dupeZ(u8, dialog_path);
    defer testing.allocator.free(dpz);
    const fd = std.c.open(dpz.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c_uint, 0o600));
    try testing.expect(fd >= 0);
    // Fenced reply — production protocol shape stored in NDJSON.
    // The `\\n` sequences are the literal `\n` newlines the
    // worker would have persisted.
    const payload =
        "{\"kind\":\"user\",\"content\":\"list files\"}\n" ++
        "{\"kind\":\"assistant_exec\",\"content\":\"```exec\\nls -la /tmp\\n```\\n\"}\n";
    _ = std.c.write(fd, payload.ptr, payload.len);
    _ = std.c.close(fd);
    defer _ = std.c.rmdir(dz.ptr);
    defer _ = std.c.unlink(dpz.ptr);

    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .chat_persist_enabled = true,
        .chat_persist_dir = dir,
    });

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();
    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);
    const helpers = dialog.Module(L.config, L.Runtime);
    defer helpers.freeTurns(&rt);

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

    _ = try L.onAction(&rt, &ctx, .chat_recall);
    _ = try L.onInput(&rt, &ctx, "\r");
    try testing.expect(rt.chat_inline_open);
    try testing.expectEqual(@as(usize, 2), rt.turns_len);

    // Now trigger a paint and pin the rendered exec box on the
    // recalled assistant turn.
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    rt.chat_inline_paint_pending = true;
    const out = (try L.provideTermBytes(&rt, &ctx)).?;

    try testing.expect(std.mem.indexOf(u8, out, "\u{256D} exec \u{2500}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ls -la /tmp") != null);
    // Old `<description> → <command>` one-liner shouldn't appear.
    try testing.expect(std.mem.indexOf(u8, out, "\u{2192}") == null);

    // Now flip to the full-screen overlay and pin the same box —
    // both render paths must apply to recalled turns.
    rt.chat_inline_open = false;
    rt.chat_overlay_open = true;
    rt.chat_overlay_paint_pending = true;
    const overlay_out = (try L.provideTermBytes(&rt, &ctx)).?;
    try testing.expect(std.mem.indexOf(u8, overlay_out, "\u{256D} exec \u{2500}") != null);
    try testing.expect(std.mem.indexOf(u8, overlay_out, "ls -la /tmp") != null);
    try testing.expect(std.mem.indexOf(u8, overlay_out, "```exec") == null);
}

test "chat_recall picker: Esc cancels without loading" {
    // Picker opens, user presses Esc — picker closes, no load
    // happens, in-memory ring stays empty.
    const dir: []const u8 = "/tmp/atty-recall-esc-test";
    const dz = try testing.allocator.dupeZ(u8, dir);
    defer testing.allocator.free(dz);
    const dialog_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/20260101T000000-aaaaaa.jsonl",
        .{dir},
    );
    defer testing.allocator.free(dialog_path);
    const pre_dpz = try testing.allocator.dupeZ(u8, dialog_path);
    _ = std.c.unlink(pre_dpz.ptr);
    testing.allocator.free(pre_dpz);
    _ = std.c.rmdir(dz.ptr);
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(dz.ptr, 0o700));
    const dpz = try testing.allocator.dupeZ(u8, dialog_path);
    defer testing.allocator.free(dpz);
    const fd = std.c.open(dpz.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c_uint, 0o600));
    try testing.expect(fd >= 0);
    _ = std.c.write(fd, "{\"kind\":\"user\",\"content\":\"hi\"}\n", 31);
    _ = std.c.close(fd);
    defer _ = std.c.rmdir(dz.ptr);
    defer _ = std.c.unlink(dpz.ptr);

    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .chat_persist_enabled = true,
        .chat_persist_dir = dir,
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
        .statusbar_reserve = 2,
    };

    _ = try L.onAction(&rt, &ctx, .chat_recall);
    try testing.expect(rt.chat_recall_open);

    // Press Esc — picker closes, no load.
    _ = try L.onInput(&rt, &ctx, "\x1b");
    try testing.expect(!rt.chat_recall_open);
    try testing.expect(!rt.chat_inline_open);
    try testing.expectEqual(@as(usize, 0), rt.turns_len);
    try testing.expect(rt.conclusion_formatted == null);
}

test "chat_recall: refuses with statusbar hint when statusbar_reserve is null" {
    // Mirror the inline-toggle path's statusbar prerequisite: a
    // user with chat_persist_enabled but statusbar.enabled = false
    // would otherwise open the inline panel without a reserved
    // row + the shell would scroll through it.
    const dir: []const u8 = "/tmp/atty-recall-no-sb-test";
    const dz = try testing.allocator.dupeZ(u8, dir);
    defer testing.allocator.free(dz);
    _ = std.c.rmdir(dz.ptr);

    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .chat_persist_enabled = true,
        .chat_persist_dir = dir,
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
        // statusbar_reserve deliberately null
    };

    const consumed = try L.onAction(&rt, &ctx, .chat_recall);
    try testing.expect(consumed);
    try testing.expect(!rt.chat_inline_open);
    try testing.expect(rt.hint_pending);
    rt.hint_pending = false;
}

test "chat_recall: latches hint and refuses cleanly when no dialogs exist" {
    const dir: []const u8 = "/tmp/atty-recall-empty-test";
    const dz = try testing.allocator.dupeZ(u8, dir);
    defer testing.allocator.free(dz);
    _ = std.c.rmdir(dz.ptr); // pre-cleanup

    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .chat_persist_enabled = true,
        .chat_persist_dir = dir,
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

    // attach reserved file A but no past dialogs exist (just the
    // current reservation, which listDialogs would skip due to
    // 0-byte filter). Alt+R must consume + hint, not crash.
    const consumed = try L.onAction(&rt, &ctx, .chat_recall);
    try testing.expect(consumed);
    try testing.expect(rt.hint_pending);
    try testing.expect(!rt.chat_inline_open);

    rt.hint_pending = false;
}

test "persistence: retained conclusion from prior dialog does NOT leak into the next session file on cancel" {
    // Regression for Copilot's round-2 finding on PR #238:
    // conclusion_formatted survives dialogReset (overlay recall);
    // without the `_pending` gate, a later cancel of the NEXT
    // dialog would re-flush the prior banner into the new file.
    // Comptime-known dir — Zig's test runner is sequential within
    // a process, so the fixed path is collision-safe across the
    // 800+ tests in one run. Pre-cleanup catches stale files from
    // a previous crash.
    const dir: []const u8 = "/tmp/atty-pers-regress-test";
    const dir_z = try testing.allocator.dupeZ(u8, dir);
    defer testing.allocator.free(dir_z);
    // Best-effort pre-cleanup: ignore errors; if the dir doesn't
    // exist, mkdir during attach handles it.
    _ = std.c.rmdir(dir_z.ptr);

    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .chat_persist_enabled = true,
        .chat_persist_dir = dir,
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

    // attach reserved file A.
    try testing.expect(rt.chat_persist_path.len > 0);

    // Simulate dialog 1's outcome AFTER the wrapper's .done flush:
    // banner is in memory (overlay recall), but it has already been
    // persisted — pending=false.
    rt.conclusion_formatted = try testing.allocator.dupe(u8, "✓ done — dialog 1 banner");
    rt.chat_persist_conclusion_pending = false;
    rt.chat_persist_has_writes = true; // pretend turn was appended

    // Manually rotate to file B (the wrapper does this on
    // dialogReset; we skip the helper here because driving a real
    // .done needs a worker round-trip). After the rotate the path
    // changes and has_writes resets to false.
    const file_b_path = blk: {
        // Free file A's reservation (with its 0-byte file —
        // but our manual path says writes happened, so just free).
        testing.allocator.free(rt.chat_persist_path);
        rt.chat_persist_path = &.{};
        // Reserve a new one inside the same dir.
        const chat_persist = @import("chat_persist.zig");
        const new_path = try chat_persist.createSessionPath(testing.allocator, rt.chat_persist_dir);
        rt.chat_persist_path = new_path;
        rt.chat_persist_has_writes = false;
        break :blk try testing.allocator.dupe(u8, new_path);
    };
    defer testing.allocator.free(file_b_path);

    // Dialog 2 has work to cancel.
    rt.dialog_persistent_mode = .dialog;
    rt.dialog_state = .generating;

    // Cancel — wrapper flushes ONLY if pending. Since we set
    // pending=false above, file B should NOT receive a conclusion
    // record. The cancel also rotates the path again, so we
    // captured file_b_path beforehand.
    _ = try L.onAction(&rt, &ctx, .llm_exec_cancel);

    // Read file B and assert no conclusion record landed.
    const file_b_z = try testing.allocator.dupeZ(u8, file_b_path);
    defer testing.allocator.free(file_b_z);
    defer _ = std.c.unlink(file_b_z.ptr);
    const fd = std.c.open(file_b_z.ptr, .{ .ACCMODE = .RDONLY });
    if (fd >= 0) {
        defer _ = std.c.close(fd);
        var buf: [512]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        if (n > 0) {
            const slice = buf[0..@as(usize, @intCast(n))];
            try testing.expect(std.mem.indexOf(u8, slice, "\"kind\":\"conclusion\"") == null);
        }
        // n == 0 (empty file) is also acceptable — the dialog-2
        // cancel unlinks the unused reservation; the open might
        // race with that. Either way: no conclusion record.
    }
    // fd < 0 means dropUnusedReservation already unlinked file B
    // (correct cancel-path behavior). Test still passes.

    // Cleanup the new (third) reservation the wrapper made on
    // rotation after the cancel.
    if (rt.chat_persist_path.len > 0) {
        const z = try testing.allocator.dupeZ(u8, rt.chat_persist_path);
        defer testing.allocator.free(z);
        _ = std.c.unlink(z.ptr);
    }
    // dialogReset preserves conclusion_formatted (overlay recall);
    // shutdownAndFree doesn't free it. Drop it explicitly so the
    // testing allocator doesn't flag a leak.
    if (rt.conclusion_formatted) |buf| {
        testing.allocator.free(buf);
        rt.conclusion_formatted = null;
    }

    // Best-effort dir cleanup so subsequent test runs start clean.
    _ = std.c.rmdir(dir_z.ptr);
}

test "chat_recall picker: CSI Up/Down moves the selection (#318)" {
    // Regression pin: parseChatKey's CSI 3-byte arm was missing
    // 'A' / 'B' (only SS3 had them). Plain ↑/↓ over the recall
    // picker did nothing. Verifies both CSI and SS3 forms now
    // produce a selection change.
    const dir: []const u8 = "/tmp/atty-recall-arrow-test";
    const dz = try testing.allocator.dupeZ(u8, dir);
    defer testing.allocator.free(dz);
    // Pre-cleanup: unlink the staged JSONL files from a possible
    // prior crashed run (rmdir below would otherwise hit ENOTEMPTY
    // and the subsequent mkdir would return EEXIST). Mirrors the
    // pattern in `chat_recall: loads a pre-existing dialog file`.
    const fnames = [_][]const u8{ "20260101T000000-aaaaaa.jsonl", "20260102T000000-bbbbbb.jsonl" };
    for (fnames) |fname| {
        const p = std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, fname }) catch return error.OutOfMemory;
        defer testing.allocator.free(p);
        const pz = testing.allocator.dupeZ(u8, p) catch return error.OutOfMemory;
        defer testing.allocator.free(pz);
        _ = std.c.unlink(pz.ptr);
    }
    _ = std.c.rmdir(dz.ptr);
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(dz.ptr, 0o700));
    // Stage TWO dialogs so the picker has rows to navigate.
    var paths_z: [2][:0]u8 = undefined;
    for (fnames, 0..) |fname, idx| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, fname });
        defer testing.allocator.free(p);
        paths_z[idx] = try testing.allocator.dupeZ(u8, p);
        const fd = std.c.open(paths_z[idx].ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c_uint, 0o600));
        try testing.expect(fd >= 0);
        const payload = "{\"kind\":\"user\",\"content\":\"x\"}\n";
        _ = std.c.write(fd, payload.ptr, payload.len);
        _ = std.c.close(fd);
    }
    // Defers run LIFO — rmdir must fire last (against the empty dir).
    defer _ = std.c.rmdir(dz.ptr);
    defer for (paths_z) |pz| {
        _ = std.c.unlink(pz.ptr);
        testing.allocator.free(pz);
    };

    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .chat_persist_enabled = true,
        .chat_persist_dir = dir,
    });
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();
    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);
    const helpers = dialog.Module(L.config, L.Runtime);
    defer helpers.freeTurns(&rt);

    var line: @import("../../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = real_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
        .statusbar_reserve = 2,
    };

    _ = try L.onAction(&rt, &ctx, .chat_recall);
    try testing.expect(rt.chat_recall_open);
    try testing.expectEqual(@as(usize, 0), rt.chat_recall_selected_idx);

    // CSI Down — `\x1B[B`. Pre-fix this returned .none from
    // parseChatKey and the selection didn't move.
    _ = try L.onInput(&rt, &ctx, "\x1B[B");
    try testing.expectEqual(@as(usize, 1), rt.chat_recall_selected_idx);

    // CSI Up — `\x1B[A`. Symmetric fix.
    _ = try L.onInput(&rt, &ctx, "\x1B[A");
    try testing.expectEqual(@as(usize, 0), rt.chat_recall_selected_idx);

    // SS3 Down — `\x1BOB`. Already worked, regression pin.
    _ = try L.onInput(&rt, &ctx, "\x1BOB");
    try testing.expectEqual(@as(usize, 1), rt.chat_recall_selected_idx);

    // Close cleanly so dialog reset doesn't leak open recall state.
    _ = try L.onInput(&rt, &ctx, "\x1B");
    try testing.expect(!rt.chat_recall_open);
}

test "chat_recall: Alt+R auto-closes the inline panel instead of refusing (#318)" {
    // Pre-fix: chat_recall handler refused to open when
    // chat_inline_open was true ("close the chat panel first").
    // Post-fix: the inline panel is auto-closed (it doesn't own the
    // alt-screen; the picker does) and the picker opens.
    const dir: []const u8 = "/tmp/atty-recall-handoff-test";
    const dz = try testing.allocator.dupeZ(u8, dir);
    defer testing.allocator.free(dz);
    const dialog_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/20260101T000000-cccccc.jsonl",
        .{dir},
    );
    defer testing.allocator.free(dialog_path);
    const dpz = try testing.allocator.dupeZ(u8, dialog_path);
    defer testing.allocator.free(dpz);
    // Pre-cleanup: unlink the staged JSONL from any prior crashed
    // run so the rmdir doesn't hit ENOTEMPTY + mkdir EEXIST.
    _ = std.c.unlink(dpz.ptr);
    _ = std.c.rmdir(dz.ptr);
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(dz.ptr, 0o700));
    const fd = std.c.open(dpz.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c_uint, 0o600));
    try testing.expect(fd >= 0);
    _ = std.c.write(fd, "{\"kind\":\"user\",\"content\":\"x\"}\n", 30);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(dpz.ptr);
    defer _ = std.c.rmdir(dz.ptr);

    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .chat_persist_enabled = true,
        .chat_persist_dir = dir,
    });
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();
    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);
    const helpers = dialog.Module(L.config, L.Runtime);
    defer helpers.freeTurns(&rt);

    var line: @import("../../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = real_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
        .statusbar_reserve = 2,
    };

    // Open the inline panel first, then fire Alt+R.
    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;
    _ = try L.onAction(&rt, &ctx, .chat_recall);
    try testing.expect(rt.chat_recall_open);
    try testing.expect(!rt.chat_inline_open);
    try testing.expect(!rt.chat_focus_in_panel);

    // Close cleanly.
    _ = try L.onInput(&rt, &ctx, "\x1B");
    try testing.expect(!rt.chat_recall_open);
}

test "OSC 133 ;D clears cached chat_open_cursor (#303)" {
    // Pre-fix: `chat_open_cursor_row`/_col was captured ONCE at
    // first chat-open and never invalidated. After an exec ran +
    // output scrolled the shell prompt down, the next paint
    // CUP'd back to the stale (pre-exec) row, landing the second
    // exec's insertion on top of the first exec's output.
    //
    // Fix: ;D handler clears both fields when chat_refocus_pending
    // fires, so paintInlineChat re-captures from the current
    // ctx.cursor_row/col on the next tick.
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

    // Stage state as if a first exec just ran: chat open, cursor
    // snapshot recorded from the pre-exec row, refocus pending,
    // dialog in capturing_output (the only state ;D unwinds).
    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = false;
    rt.chat_open_cursor_row = 17;
    rt.chat_open_cursor_col = 1;
    rt.chat_refocus_pending = true;
    rt.dialog_state = .capturing_output;

    // Feed an OSC 133 ;C + ;D pair. The ;C transitions into
    // capturing; ;D fires the refocus arm.
    _ = try L.onOutput(&rt, &ctx, "\x1B]133;C\x07output\x1B]133;D\x07");

    try testing.expect(rt.chat_focus_in_panel);
    try testing.expectEqual(@as(u16, 0), rt.chat_open_cursor_row);
    try testing.expectEqual(@as(u16, 0), rt.chat_open_cursor_col);
    try testing.expect(!rt.chat_refocus_pending);
}
