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
    // Backspace pops.
    try testing.expectEqual(m.Action{ .swallow = {} }, try L.onInput(&rt, &ctx, "\x08"));
    try testing.expectEqualStrings("pin", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
    // The overlay buffer must not be touched (mutually exclusive).
    try testing.expectEqual(@as(usize, 0), rt.chat_input_len);
}
