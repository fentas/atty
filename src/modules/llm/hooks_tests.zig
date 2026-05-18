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
const shutdownAndFree = @import("test_helpers.zig").shutdownAndFree;

const test_io: std.Io = std.Io.failing;

test "chat overlay (Alt+Shift+C): refuses to open when no conversation exists" {
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

    // Fresh runtime — no turns, no conclusion. Alt+Shift+C should
    // hint-and-no-op rather than open an empty overlay.
    const consumed = try L.onAction(&rt, &ctx, .llm_chat_overlay_toggle);
    try testing.expect(consumed);
    try testing.expect(!rt.chat_overlay_open);
    try testing.expect(rt.hint_pending);
    rt.hint_pending = false; // drain the latch so the next test starts clean
}

test "chat overlay: onInput swallows all keystrokes while open" {
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

    // Printable ASCII accumulates into chat_input_buf; control
    // bytes are dropped; Enter submits (and would fire a worker
    // request); Backspace pops the last byte. Every input case
    // returns .swallow so the underlying shell never sees these
    // keystrokes.
    const helpers = dialog.Module(L.config, L.Runtime);
    defer helpers.freeTurns(&rt);

    try testing.expectEqual(m.Action{ .swallow = {} }, try L.onInput(&rt, &ctx, "hello"));
    try testing.expectEqualStrings("hello", rt.chat_input_buf[0..rt.chat_input_len]);

    try testing.expectEqual(m.Action{ .swallow = {} }, try L.onInput(&rt, &ctx, "\x08"));
    try testing.expectEqualStrings("hell", rt.chat_input_buf[0..rt.chat_input_len]);

    // Control byte (Ctrl+C) silently dropped — neither appended
    // nor surfaced.
    try testing.expectEqual(m.Action{ .swallow = {} }, try L.onInput(&rt, &ctx, "\x03"));
    try testing.expectEqualStrings("hell", rt.chat_input_buf[0..rt.chat_input_len]);

    // Enter clears the buffer (submitted as a turn) — even
    // though fireDialogRequest will fail in the inert test
    // environment, the buffer was already consumed.
    try testing.expectEqual(m.Action{ .swallow = {} }, try L.onInput(&rt, &ctx, "\r"));
    try testing.expectEqual(@as(usize, 0), rt.chat_input_len);
    try testing.expectEqual(@as(usize, 1), rt.turns_len);
}

test "chat overlay: Ctrl+D closes the overlay (mirrors Alt+Shift+C)" {
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
    try testing.expectEqual(m.Action{ .swallow = {} }, try L.onInput(&rt, &ctx, "\x04"));
    try testing.expect(!rt.chat_overlay_open);
    try testing.expect(rt.chat_overlay_paint_pending);
}

test "inline chat: Ctrl+D closes the panel (mirrors Alt+C)" {
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;
    try testing.expectEqual(m.Action{ .swallow = {} }, try L.onInput(&rt, &ctx, "\x04"));
    try testing.expect(!rt.chat_inline_open);
    try testing.expect(rt.chat_inline_paint_pending);
}

test "Ctrl+D falls through to .forward when no chat panel is open (bash gets EOF)" {
    // Regression guard: the chat panel intercepts Ctrl+D ONLY when
    // it owns focus. With both panel + overlay closed, Ctrl+D must
    // reach bash so the user's normal shell-exit semantics work.
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

    try testing.expectEqual(m.Action{ .forward = {} }, try L.onInput(&rt, &ctx, "\x04"));
}

test "inline chat: Ctrl+D inside a multi-byte chunk closes the panel and drops the rest" {
    // Regression guard: when a chunk contains Ctrl+D PLUS trailing
    // bytes (paste, buffered burst), the panel must close AT the
    // 0x04 and the trailing bytes must NOT be appended to the
    // (now-closed) input buffer.
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;
    // Seed the buffer empty; rely on the chunk to fill it.
    rt.chat_inline_input_len = 0;

    // Chunk: "ab\x04cd" — 'a','b' accumulate, Ctrl+D closes + returns,
    // 'c','d' must NOT reach the buffer.
    try testing.expectEqual(m.Action{ .swallow = {} }, try L.onInput(&rt, &ctx, "ab\x04cd"));
    try testing.expect(!rt.chat_inline_open);
    try testing.expectEqualStrings("ab", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
}

test "inline chat: Ctrl+D falls through to .forward when focus is parked on the shell" {
    // Same regression guard for the parked-focus state: Ctrl+Up
    // moves focus to bash while the panel stays painted. In that
    // state, Ctrl+D should reach bash, not close the panel.
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = false; // parked on shell

    try testing.expectEqual(m.Action{ .forward = {} }, try L.onInput(&rt, &ctx, "\x04"));
    try testing.expect(rt.chat_inline_open); // panel still open
}

test "inline chat: Alt+C refuses to open when there's no statusbar" {
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
        // No statusbar_reserve / terminal_rows = null — mimics
        // `config.statusbar.enabled = false` (the default).
    };

    const consumed = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(consumed); // action claimed (key stays out of shell)
    try testing.expect(!rt.chat_inline_open); // but refused to open
    try testing.expect(rt.hint_pending); // hint surfaces explaining why
    rt.hint_pending = false;
}

test "inline chat: Ctrl+Up parks focus; Ctrl+Down brings it back; passthrough while parked" {
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

    // Without inline chat open, both focus actions are no-ops AND
    // not-consumed (so the keystroke bytes flow through to the shell
    // — e.g. tmux pane navigation on Ctrl+Up still works).
    try testing.expect(!try L.onAction(&rt, &ctx, .chat_focus_to_shell));
    try testing.expect(!try L.onAction(&rt, &ctx, .chat_focus_to_chat));

    // Open inline chat — focus defaults to in-panel.
    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;

    // Keystroke while focused: swallowed into chat buffer.
    try testing.expectEqual(m.Action{ .swallow = {} }, try L.onInput(&rt, &ctx, "h"));
    try testing.expectEqualStrings("h", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);

    // Ctrl+Up → parks focus on the shell.
    try testing.expect(try L.onAction(&rt, &ctx, .chat_focus_to_shell));
    try testing.expect(!rt.chat_focus_in_panel);
    try testing.expect(rt.chat_inline_open); // panel STILL open
    try testing.expect(rt.chat_inline_paint_pending); // repaint armed to dim chrome

    // Keystroke while parked: forwarded, NOT swallowed; chat buffer
    // unchanged.
    const len_before = rt.chat_inline_input_len;
    try testing.expectEqual(m.Action{ .forward = {} }, try L.onInput(&rt, &ctx, "x"));
    try testing.expectEqual(len_before, rt.chat_inline_input_len);

    // Ctrl+Down → focus back in panel.
    rt.chat_inline_paint_pending = false;
    try testing.expect(try L.onAction(&rt, &ctx, .chat_focus_to_chat));
    try testing.expect(rt.chat_focus_in_panel);
    try testing.expect(rt.chat_inline_paint_pending);
}

test "inline chat: closing panel via Alt+C resets focus to in-panel for next open" {
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

    // Open, park focus on shell, close, reopen — focus must restart
    // in the panel (don't carry stale parked state into next session).
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle); // open
    rt.chat_focus_in_panel = false; // parked
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle); // close
    try testing.expect(!rt.chat_inline_open);
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle); // reopen
    try testing.expect(rt.chat_inline_open);
    try testing.expect(rt.chat_focus_in_panel);
}

test "inline chat: pushTurn arms paint latch when inline open (response auto-repaints)" {
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

    const helpers = dialog.Module(L.config, L.Runtime);
    defer helpers.freeTurns(&rt);

    // Simulate "panel is open, LLM response just landed and pushed
    // an assistant_exec turn." pushTurn must re-arm the inline paint
    // latch so the next term-bytes tick re-renders chrome with the
    // new turn visible — without this the panel sits stale until
    // the next keystroke.
    rt.chat_inline_open = true;
    rt.chat_inline_paint_pending = false;
    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, "echo hi"));
    try testing.expect(rt.chat_inline_paint_pending);

    // Same for the overlay (existing behaviour, regression guard).
    rt.chat_inline_open = false;
    rt.chat_overlay_open = true;
    rt.chat_overlay_paint_pending = false;
    try helpers.pushTurn(&rt, .observation, try testing.allocator.dupe(u8, "ok"));
    try testing.expect(rt.chat_overlay_paint_pending);
}

test "inline chat: Alt+Shift+C closes inline panel first if it was open (mutually exclusive — reverse direction)" {
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

    // Seed content so the overlay-toggle handler doesn't refuse to
    // open with "no LLM session to recall".
    const helpers = dialog.Module(L.config, L.Runtime);
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "first prompt"));
    defer helpers.freeTurns(&rt);

    rt.chat_inline_open = true;
    _ = try L.onAction(&rt, &ctx, .llm_chat_overlay_toggle);
    try testing.expect(!rt.chat_inline_open);
    try testing.expect(rt.chat_overlay_open);
    try testing.expect(rt.chat_inline_paint_pending);
    try testing.expect(rt.chat_overlay_paint_pending);
}

test "inline chat: Alt+C closes overlay first if it was open (mutually exclusive)" {
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

    rt.chat_overlay_open = true;
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(!rt.chat_overlay_open);
    try testing.expect(rt.chat_inline_open);
    // Both paint latches set — overlay must emit its alt-screen
    // exit, inline must emit its first paint, in some order on
    // subsequent term-bytes calls.
    try testing.expect(rt.chat_overlay_paint_pending);
    try testing.expect(rt.chat_inline_paint_pending);
}

test "inline chat: onInput swallows keystrokes into chat_inline_input_buf when open" {
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

    rt.chat_inline_open = true;
    try testing.expectEqual(m.Action{ .swallow = {} }, try L.onInput(&rt, &ctx, "ping"));
    try testing.expectEqualStrings("ping", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
    try testing.expectEqual(@as(usize, 4), rt.chat_inline_input_cursor);
    // Backspace pops.
    try testing.expectEqual(m.Action{ .swallow = {} }, try L.onInput(&rt, &ctx, "\x08"));
    try testing.expectEqualStrings("pin", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
    try testing.expectEqual(@as(usize, 3), rt.chat_inline_input_cursor);
    // The overlay buffer must not be touched (mutually exclusive).
    try testing.expectEqual(@as(usize, 0), rt.chat_input_len);
}

test "inline chat: Left/Right arrow + Home/End move the cursor; Ctrl+A/E mirror them" {
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;

    _ = try L.onInput(&rt, &ctx, "hello");
    try testing.expectEqual(@as(usize, 5), rt.chat_inline_input_cursor);
    // Left arrow (CSI D).
    _ = try L.onInput(&rt, &ctx, "\x1B[D");
    try testing.expectEqual(@as(usize, 4), rt.chat_inline_input_cursor);
    // Right arrow back.
    _ = try L.onInput(&rt, &ctx, "\x1B[C");
    try testing.expectEqual(@as(usize, 5), rt.chat_inline_input_cursor);
    // Right at end → no-op, doesn't overshoot.
    _ = try L.onInput(&rt, &ctx, "\x1B[C");
    try testing.expectEqual(@as(usize, 5), rt.chat_inline_input_cursor);
    // Ctrl+A jumps to start.
    _ = try L.onInput(&rt, &ctx, "\x01");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_cursor);
    // Left at start → no-op.
    _ = try L.onInput(&rt, &ctx, "\x1B[D");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_cursor);
    // Ctrl+E jumps to end.
    _ = try L.onInput(&rt, &ctx, "\x05");
    try testing.expectEqual(@as(usize, 5), rt.chat_inline_input_cursor);
    // CSI Home (`ESC [ H`) → start. End (`ESC [ F`) → end.
    _ = try L.onInput(&rt, &ctx, "\x1B[H");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_cursor);
    _ = try L.onInput(&rt, &ctx, "\x1B[F");
    try testing.expectEqual(@as(usize, 5), rt.chat_inline_input_cursor);
    // VT-style xterm sequences: `ESC [ 1 ~` / `ESC [ 7 ~` Home, `ESC [ 4 ~` / `ESC [ 8 ~` End.
    _ = try L.onInput(&rt, &ctx, "\x1B[1~");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_cursor);
    _ = try L.onInput(&rt, &ctx, "\x1B[4~");
    try testing.expectEqual(@as(usize, 5), rt.chat_inline_input_cursor);
    _ = try L.onInput(&rt, &ctx, "\x1B[7~");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_cursor);
    _ = try L.onInput(&rt, &ctx, "\x1B[8~");
    try testing.expectEqual(@as(usize, 5), rt.chat_inline_input_cursor);
    // Buffer unchanged through all that.
    try testing.expectEqualStrings("hello", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
}

test "inline chat: insert at mid-cursor shifts trailing bytes right" {
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;

    _ = try L.onInput(&rt, &ctx, "hllo");
    // Move cursor between 'h' and 'l'. Three left arrows.
    _ = try L.onInput(&rt, &ctx, "\x1B[D\x1B[D\x1B[D");
    try testing.expectEqual(@as(usize, 1), rt.chat_inline_input_cursor);
    // Insert 'e' AT cursor — buffer becomes "hello", cursor=2.
    _ = try L.onInput(&rt, &ctx, "e");
    try testing.expectEqualStrings("hello", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
    try testing.expectEqual(@as(usize, 2), rt.chat_inline_input_cursor);
    // Backspace deletes BEFORE cursor (the just-inserted 'e').
    _ = try L.onInput(&rt, &ctx, "\x08");
    try testing.expectEqualStrings("hllo", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
    try testing.expectEqual(@as(usize, 1), rt.chat_inline_input_cursor);
}

test "inline chat: Ctrl+W kills the previous word" {
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;

    _ = try L.onInput(&rt, &ctx, "explain foo bar");
    // Ctrl+W kills the last word "bar".
    _ = try L.onInput(&rt, &ctx, "\x17");
    try testing.expectEqualStrings("explain foo ", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
    try testing.expectEqual(@as(usize, 12), rt.chat_inline_input_cursor);
    // Ctrl+W again kills "foo " (trailing-whitespace-then-word).
    _ = try L.onInput(&rt, &ctx, "\x17");
    try testing.expectEqualStrings("explain ", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
    try testing.expectEqual(@as(usize, 8), rt.chat_inline_input_cursor);
}

test "inline chat: Ctrl+U kills to start; Ctrl+K kills to end" {
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;

    _ = try L.onInput(&rt, &ctx, "hello world");
    // Move cursor to AFTER "hello " (idx 6).
    _ = try L.onInput(&rt, &ctx, "\x01\x06\x06\x06\x06\x06\x06");
    try testing.expectEqual(@as(usize, 6), rt.chat_inline_input_cursor);
    // Ctrl+K wipes from cursor to end → "hello ".
    _ = try L.onInput(&rt, &ctx, "\x0B");
    try testing.expectEqualStrings("hello ", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
    try testing.expectEqual(@as(usize, 6), rt.chat_inline_input_cursor);
    // Ctrl+U wipes from start to cursor → buffer empty.
    _ = try L.onInput(&rt, &ctx, "\x15");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_len);
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_cursor);
}

test "inline chat: CSI 3~ (Delete) removes the byte AFTER cursor" {
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;

    _ = try L.onInput(&rt, &ctx, "abcd");
    _ = try L.onInput(&rt, &ctx, "\x01"); // cursor to start
    _ = try L.onInput(&rt, &ctx, "\x1B[3~"); // Delete: removes 'a'
    try testing.expectEqualStrings("bcd", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_cursor);
    // Delete at end of buffer is a no-op.
    _ = try L.onInput(&rt, &ctx, "\x05"); // Ctrl+E
    _ = try L.onInput(&rt, &ctx, "\x1B[3~");
    try testing.expectEqualStrings("bcd", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
    try testing.expectEqual(@as(usize, 3), rt.chat_inline_input_cursor);
}

test "inline chat: insert short-circuits when the buffer is full" {
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;

    // Saturate to buf.len with a long ASCII run.
    const cap = rt.chat_inline_input_buf.len;
    var i: usize = 0;
    while (i < cap) : (i += 1) {
        rt.chat_inline_input_buf[i] = 'x';
    }
    rt.chat_inline_input_len = cap;
    rt.chat_inline_input_cursor = cap;
    // Append: must drop silently (no overflow, no len growth).
    _ = try L.onInput(&rt, &ctx, "y");
    try testing.expectEqual(cap, rt.chat_inline_input_len);
    try testing.expectEqual(cap, rt.chat_inline_input_cursor);
    // Mid-cursor insert with a full buffer is also a no-op.
    _ = try L.onInput(&rt, &ctx, "\x01"); // cursor=0
    _ = try L.onInput(&rt, &ctx, "z");
    try testing.expectEqual(cap, rt.chat_inline_input_len);
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_cursor);
    try testing.expectEqual(@as(u8, 'x'), rt.chat_inline_input_buf[0]);
}

test "overlay chat: cursor movement + mid-line insert + Ctrl+W mirror the inline path" {
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

    // Overlay path — open via the field directly, mirroring the
    // existing overlay-input test pattern.
    rt.chat_overlay_open = true;

    _ = try L.onInput(&rt, &ctx, "explain foo bar");
    try testing.expectEqual(@as(usize, 15), rt.chat_input_cursor);
    // Ctrl+A then Right-arrow ×4: cursor at 4.
    _ = try L.onInput(&rt, &ctx, "\x01\x1B[C\x1B[C\x1B[C\x1B[C");
    try testing.expectEqual(@as(usize, 4), rt.chat_input_cursor);
    // Insert '!' at cursor → "expl!ain foo bar".
    _ = try L.onInput(&rt, &ctx, "!");
    try testing.expectEqualStrings("expl!ain foo bar", rt.chat_input_buf[0..rt.chat_input_len]);
    try testing.expectEqual(@as(usize, 5), rt.chat_input_cursor);
    // Ctrl+E then Ctrl+W → kills "bar".
    _ = try L.onInput(&rt, &ctx, "\x05\x17");
    try testing.expectEqualStrings("expl!ain foo ", rt.chat_input_buf[0..rt.chat_input_len]);
    // Ctrl+D closes the overlay (regression guard for PR #89).
    _ = try L.onInput(&rt, &ctx, "\x04");
    try testing.expect(!rt.chat_overlay_open);
}

test "inline chat: Enter with refused-fire clamps cursor when trailing whitespace was trimmed" {
    // Regression guard: PR #93 round-1 review caught that trimming
    // trailing whitespace could leave the cursor past the new EOL.
    // If can_fire = false (request in flight), the buffer survives
    // and a later paint or edit would index out of bounds.
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;
    // Block submission so Enter takes the can_fire=false branch.
    rt.in_flight = true;

    _ = try L.onInput(&rt, &ctx, "hi   "); // 5 chars, cursor=5
    try testing.expectEqual(@as(usize, 5), rt.chat_inline_input_cursor);
    _ = try L.onInput(&rt, &ctx, "\r"); // Enter → trims to "hi" (len=2)
    try testing.expectEqual(@as(usize, 2), rt.chat_inline_input_len);
    // Cursor MUST have been clamped to the new length.
    try testing.expect(rt.chat_inline_input_cursor <= rt.chat_inline_input_len);
    try testing.expectEqual(@as(usize, 2), rt.chat_inline_input_cursor);
}

test "inline chat: chunk ending mid-CSI doesn't spin AND doesn't insert literal `[`" {
    // Regression guard: a chunk ending with `ESC [ 3` (partial
    // Delete sequence) used to make parseChatKey return .none
    // without advancing `i`, sending the caller's
    // `while (i < input.len)` loop into an infinite spin.
    // Sibling: a chunk ending with `ESC [` would fall through to
    // the single-byte path and insert a literal `[` next.
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;

    // Partial Delete: must terminate (no spin) and not insert anything.
    _ = try L.onInput(&rt, &ctx, "\x1B[3");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_len);

    // Partial 3-byte CSI: must NOT insert `[` as printable.
    _ = try L.onInput(&rt, &ctx, "\x1B[");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_len);

    // Bare ESC at chunk end: also drained cleanly.
    _ = try L.onInput(&rt, &ctx, "\x1B");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_len);

    // A complete CSI in a single chunk still works.
    _ = try L.onInput(&rt, &ctx, "abc");
    _ = try L.onInput(&rt, &ctx, "\x1B[3~"); // Delete at end of buffer — no-op
    try testing.expectEqualStrings("abc", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
}
