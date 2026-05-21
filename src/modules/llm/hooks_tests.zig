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
    try testing.expectEqual(m.Action{ .swallow = {} }, try L.onInput(&rt, &ctx, "\x04"));
    try testing.expect(!rt.chat_overlay_open);
    try testing.expect(rt.chat_overlay_paint_pending);
}

test "inline chat: Ctrl+D closes the panel (mirrors Alt+C)" {
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

    try testing.expectEqual(m.Action{ .forward = {} }, try L.onInput(&rt, &ctx, "\x04"));
}

test "inline chat: Ctrl+D inside a multi-byte chunk closes the panel and drops the rest" {
    // Regression guard: when a chunk contains Ctrl+D PLUS trailing
    // bytes (paste, buffered burst), the panel must close AT the
    // 0x04 and the trailing bytes must NOT be appended to the
    // (now-closed) input buffer.
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = false; // parked on shell

    try testing.expectEqual(m.Action{ .forward = {} }, try L.onInput(&rt, &ctx, "\x04"));
    try testing.expect(rt.chat_inline_open); // panel still open
}

test "inline chat: Alt+C refuses to open when there's no statusbar" {
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
    // Ctrl+D closes the overlay — `.close` must return `.swallow`
    // immediately so trailing bytes don't land in the now-closed
    // buffer.
    _ = try L.onInput(&rt, &ctx, "\x04");
    try testing.expect(!rt.chat_overlay_open);
}

test "inline chat: Enter with refused-fire clamps cursor when trailing whitespace was trimmed" {
    // Invariant: trimming trailing whitespace must leave the cursor
    // within `[0, chat_inline_input_len]`. When submission is
    // refused (request in flight) the buffer survives, and a stale
    // out-of-range cursor would index past EOL on the next paint or
    // edit.
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

test "inline chat: modified CSI (`ESC [ 1 ; 5 D`) doesn't leak its tail as printables" {
    // Invariant: parseChatKey must consume the WHOLE CSI sequence
    // for unrecognised modified keys (Ctrl+Left etc.), not just
    // `ESC [`. A premature return mid-sequence would leave the
    // remaining bytes (digits + params) to be reparsed as
    // printables on the next loop iteration.
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;

    // Ctrl+Left arrow: `ESC [ 1 ; 5 D`. Unrecognised (we only
    // handle plain Left/Right/Home/End and VT-style ~ sequences).
    // The whole 6-byte sequence must be consumed silently.
    _ = try L.onInput(&rt, &ctx, "\x1B[1;5D");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_len);

    // Same shape but with a recognised final wrapped in params —
    // still consumed as a single sequence, not insert-leaked.
    _ = try L.onInput(&rt, &ctx, "\x1B[1;2C"); // Shift+Right
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_len);

    // A plain CSI right afterwards still works.
    _ = try L.onInput(&rt, &ctx, "hello");
    _ = try L.onInput(&rt, &ctx, "\x1B[D"); // Left
    try testing.expectEqual(@as(usize, 4), rt.chat_inline_input_cursor);
}

test "inline chat: SS3 cursor keys (`ESC O D/C/H/F`) move the cursor and don't leak" {
    // Invariant: terminals in application-cursor mode emit
    // `ESC O <letter>` for arrows / Home / End. parseChatKey must
    // map the same handful as the CSI form so legacy and
    // application modes both work, and the trailing letter must
    // not leak into the buffer as a printable when the variant
    // is unrecognised.
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;

    _ = try L.onInput(&rt, &ctx, "abc");
    try testing.expectEqual(@as(usize, 3), rt.chat_inline_input_cursor);
    _ = try L.onInput(&rt, &ctx, "\x1BOD"); // SS3 Left
    try testing.expectEqual(@as(usize, 2), rt.chat_inline_input_cursor);
    _ = try L.onInput(&rt, &ctx, "\x1BOC"); // SS3 Right
    try testing.expectEqual(@as(usize, 3), rt.chat_inline_input_cursor);
    _ = try L.onInput(&rt, &ctx, "\x1BOH"); // SS3 Home
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_cursor);
    _ = try L.onInput(&rt, &ctx, "\x1BOF"); // SS3 End
    try testing.expectEqual(@as(usize, 3), rt.chat_inline_input_cursor);
    // Unrecognised SS3 (e.g. F1 = `ESC O P`) must be silently
    // dropped — no `P` should land in the buffer.
    _ = try L.onInput(&rt, &ctx, "\x1BOP");
    try testing.expectEqualStrings("abc", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
}

test "inline chat: CSI with intermediate params (`ESC [ ? 2 5 l`, `ESC [ ; 5 D`) doesn't leak tail" {
    // Invariant: the CSI scanner must consume to the final byte
    // (0x40..0x7E) regardless of which parameter / intermediate
    // bytes appear in between. Without this, an unrecognised
    // private-mode sequence like `ESC [ ? 2 5 l` (DECTCEM hide
    // cursor) would have only `ESC [ ?` consumed and `25l` would
    // reparse as printables.
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;

    // Private-mode CSI: DECTCEM hide cursor.
    _ = try L.onInput(&rt, &ctx, "\x1B[?25l");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_len);

    // CSI starting with `;` separator (no leading digit).
    _ = try L.onInput(&rt, &ctx, "\x1B[;5D");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_len);

    // `>` introducer (kitty / device-attributes style).
    _ = try L.onInput(&rt, &ctx, "\x1B[>0c");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_len);

    // Normal typing after still works.
    _ = try L.onInput(&rt, &ctx, "ok");
    try testing.expectEqualStrings("ok", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
}

// ───────────────────────────────────────────────────────────────
// Chat scroll / viewport — overlay + inline.
// ───────────────────────────────────────────────────────────────

fn seedTurns(rt: anytype, helpers: anytype, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const kind: dialog.TurnKind = if (i % 2 == 0) .user else .assistant_exec;
        const body = try std.fmt.allocPrint(testing.allocator, "turn-{d}", .{i});
        try helpers.pushTurn(rt, kind, body);
    }
}

test "chat scroll: no chat surface open → action declines and PageUp passes through" {
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

    const consumed = try L.onAction(&rt, &ctx, .chat_scroll_page_up);
    try testing.expect(!consumed);
    try testing.expectEqual(@as(usize, 0), rt.chat_view_offset);
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_view_offset);
}

test "chat scroll: overlay PageUp / PageDown adjusts chat_view_offset and clamps at edges" {
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
    // `history_turns_max` defaults to 8 — pushTurn FIFO-evicts past
    // that. Seed exactly the ring size so max_offset = 7.
    try seedTurns(&rt, helpers, 8);
    try testing.expectEqual(@as(usize, 8), rt.turns_len);

    rt.chat_overlay_open = true;

    // PageUp pages by 8, clamped at max_offset = 7.
    try testing.expect(try L.onAction(&rt, &ctx, .chat_scroll_page_up));
    try testing.expectEqual(@as(usize, 7), rt.chat_view_offset);
    try testing.expect(rt.chat_overlay_paint_pending);

    // Already at the head — extra PageUp is a no-op (offset unchanged,
    // but `consumed=true` still claims the key so it doesn't leak to
    // the shell).
    rt.chat_overlay_paint_pending = false;
    try testing.expect(try L.onAction(&rt, &ctx, .chat_scroll_page_up));
    try testing.expectEqual(@as(usize, 7), rt.chat_view_offset);

    // PageDown by 8 floors at 0.
    try testing.expect(try L.onAction(&rt, &ctx, .chat_scroll_page_down));
    try testing.expectEqual(@as(usize, 0), rt.chat_view_offset);

    // scroll_up nudges +1; scroll_down -1.
    _ = try L.onAction(&rt, &ctx, .chat_scroll_up);
    try testing.expectEqual(@as(usize, 1), rt.chat_view_offset);
    _ = try L.onAction(&rt, &ctx, .chat_scroll_down);
    try testing.expectEqual(@as(usize, 0), rt.chat_view_offset);
    // scroll_down at 0 is also a no-op-but-consumed.
    _ = try L.onAction(&rt, &ctx, .chat_scroll_down);
    try testing.expectEqual(@as(usize, 0), rt.chat_view_offset);
}

test "chat scroll: inline panel scrolls only when focus is in the panel" {
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
    try seedTurns(&rt, helpers, 8); // ring size; max_offset = 7

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = false; // parked on the shell

    // Parked → action declines, shell sees PageUp.
    try testing.expect(!try L.onAction(&rt, &ctx, .chat_scroll_page_up));
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_view_offset);

    rt.chat_focus_in_panel = true;
    try testing.expect(try L.onAction(&rt, &ctx, .chat_scroll_page_up));
    try testing.expect(rt.chat_inline_view_offset > 0);
    try testing.expect(rt.chat_inline_paint_pending);
}

test "chat scroll: pushTurn re-pins both view offsets to 0" {
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

    const helpers = dialog.Module(L.config, L.Runtime);
    defer helpers.freeTurns(&rt);
    try seedTurns(&rt, helpers, 6);

    // User scrolled both views away from the tail.
    rt.chat_view_offset = 3;
    rt.chat_inline_view_offset = 2;

    const body = try testing.allocator.dupe(u8, "new assistant reply");
    try helpers.pushTurn(&rt, .assistant_exec, body);

    try testing.expectEqual(@as(usize, 0), rt.chat_view_offset);
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_view_offset);
}

test "chat scroll: freeTurns resets both view offsets" {
    // Regression guard: cancel/reset wipes the ring; without this
    // the offsets dangle stale until the first new pushTurn rescues
    // them.
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

    const helpers = dialog.Module(L.config, L.Runtime);
    try seedTurns(&rt, helpers, 6);
    rt.chat_view_offset = 3;
    rt.chat_inline_view_offset = 2;

    helpers.freeTurns(&rt);
    try testing.expectEqual(@as(usize, 0), rt.turns_len);
    try testing.expectEqual(@as(usize, 0), rt.chat_view_offset);
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_view_offset);
}

// ── #167 — inline-chat autofocus on dialog action=exec ─────────────────

test "inline-chat autofocus: ;D edge clears refocus latch + restores panel focus" {
    const L = configure(.{
        .provider = .{ .http = .{
            .model = "x",
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

    // Simulate the post-exec state: chat is open, defocused, latch armed.
    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = false;
    rt.chat_refocus_pending = true;
    rt.dialog_state = .executing;

    // Feed a `;C` (cmd_start) then `;D` (cmd_end). The `;D` edge
    // should fire the refocus latch and flip focus back into the panel.
    try L.onOutput(&rt, &ctx, "\x1b]133;C\x07cmd output\x1b]133;D\x07");
    try testing.expect(rt.chat_focus_in_panel);
    try testing.expect(!rt.chat_refocus_pending);
}

test "inline-chat autofocus: implicit ;A (prompt_start) also restores focus" {
    const L = configure(.{
        .provider = .{ .http = .{
            .model = "x",
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

    // Same setup, but the shell skips `;D` and emits the next `;A`
    // directly — atty's tracker translates that to
    // `prompt_start_implicit_end`. Same refocus behavior expected.
    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = false;
    rt.chat_refocus_pending = true;
    rt.dialog_state = .executing;

    try L.onOutput(&rt, &ctx, "\x1b]133;C\x07cmd output\x1b]133;A\x07");
    try testing.expect(rt.chat_focus_in_panel);
    try testing.expect(!rt.chat_refocus_pending);
}

test "inline-chat autofocus: dialogReset clears the latch" {
    const L = configure(.{
        .provider = .{ .http = .{
            .model = "x",
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = false;
    rt.chat_refocus_pending = true;

    const dialog_helpers = dialog.Module(L.config, L.Runtime);
    dialog_helpers.dialogReset(&rt, real_io);

    try testing.expect(!rt.chat_refocus_pending);
    // dialogReset does NOT touch focus state — it just clears the
    // pending latch so the next `;A` doesn't ambush the user.
    try testing.expect(!rt.chat_focus_in_panel);
}

test "inline-chat autofocus: config knob off — no field-level coverage but pin defaults" {
    // The arming site reads `cfg.inline_chat_autofocus_on_exec` at
    // comptime. Constructing two parallel configure() instances —
    // one with the flag on (default), one off — and checking the
    // CFG value directly is the cheapest pin against the default
    // flipping accidentally.
    const L_on = configure(.{
        .provider = .{ .http = .{ .model = "x", .api_base = "http://x/v1", .api_base_env = "ATTY_TEST_NEVER", .api_base_fallback_env = "ATTY_TEST_NEVER", .api_key_env = "ATTY_TEST_NEVER" } },
    });
    const L_off = configure(.{
        .provider = .{ .http = .{ .model = "x", .api_base = "http://x/v1", .api_base_env = "ATTY_TEST_NEVER", .api_base_fallback_env = "ATTY_TEST_NEVER", .api_key_env = "ATTY_TEST_NEVER" } },
        .inline_chat_autofocus_on_exec = false,
    });
    try testing.expect(L_on.config.inline_chat_autofocus_on_exec);
    try testing.expect(!L_off.config.inline_chat_autofocus_on_exec);
}

// ── #173 #7 — Alt+M cycle gate works inside chat ─────────────────────

test "Alt+M cycle: fires inside chat panel without ai_mode_active" {
    // Before #173 #7 the cycle handler short-circuited unless
    // `ai_mode_active` (i.e. the user had typed `#: ` at the
    // prompt). Inside the inline chat panel that flag is false
    // — so users with a multi-provider config couldn't switch
    // providers from the panel they were chatting in. Test:
    // open the panel WITHOUT typing `#: `, hit Alt+M, verify
    // current_provider_idx advanced.
    const llm = @import("../llm.zig");
    const L = configure(.{
        .provider = .{ .http = .{
            .model = "x",
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .providers = &.{
            .{ .name = "a", .config = .{ .http = .{ .model = "a" } } },
            .{ .name = "b", .config = .{ .http = .{ .model = "b" } } },
        },
        .statusbar_icon_color = null,
        .statusbar_shortcut_color = null,
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

    // Pre-conditions: chat open + NO ai_mode_active.
    rt.chat_inline_open = true;
    try testing.expect(!rt.ai_mode_active);
    try testing.expectEqual(@as(usize, 0), rt.current_provider_idx);

    // Fire Alt+M.
    const consumed = try L.onAction(&rt, &ctx, .llm_exec_cycle_model);
    try testing.expect(consumed);
    try testing.expectEqual(@as(usize, 1), rt.current_provider_idx);
    _ = llm;
}

test "Alt+M cycle: returns .forward when neither chat nor ai mode active" {
    const L = configure(.{
        .provider = .{ .http = .{
            .model = "x",
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .providers = &.{
            .{ .name = "a", .config = .{ .http = .{ .model = "a" } } },
            .{ .name = "b", .config = .{ .http = .{ .model = "b" } } },
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

    // Nothing active — Alt+M must NOT swallow the key (returns
    // false so the proxy forwards). User typing Alt+M at the
    // shell prompt shouldn't get eaten by atty.
    try testing.expect(!rt.ai_mode_active);
    try testing.expect(!rt.chat_inline_open);
    try testing.expect(!rt.chat_overlay_open);
    const consumed = try L.onAction(&rt, &ctx, .llm_exec_cycle_model);
    try testing.expect(!consumed);
    try testing.expectEqual(@as(usize, 0), rt.current_provider_idx);
}

test "Alt+M cycle: fires when chat OVERLAY is open" {
    const L = configure(.{
        .provider = .{ .http = .{ .model = "x", .api_base = "http://test/v1", .api_base_env = "ATTY_TEST_NEVER", .api_base_fallback_env = "ATTY_TEST_NEVER", .api_key_env = "ATTY_TEST_NEVER" } },
        .providers = &.{
            .{ .name = "a", .config = .{ .http = .{ .model = "a" } } },
            .{ .name = "b", .config = .{ .http = .{ .model = "b" } } },
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

    rt.chat_overlay_open = true;
    try testing.expect(!rt.ai_mode_active);
    try testing.expect(!rt.chat_inline_open);
    const consumed = try L.onAction(&rt, &ctx, .llm_exec_cycle_model);
    try testing.expect(consumed);
    try testing.expectEqual(@as(usize, 1), rt.current_provider_idx);
}

test "Alt+M cycle: fires when dialog_persistent_mode is on (no chat surface)" {
    // Mid-dialog state: user pressed Alt+S, persistent dialog
    // mode is set, but neither chat surface is open and the
    // `#: ` prompt buffer was wiped post-commit so
    // ai_mode_active is false. Alt+M should still cycle.
    const L = configure(.{
        .provider = .{ .http = .{ .model = "x", .api_base = "http://test/v1", .api_base_env = "ATTY_TEST_NEVER", .api_base_fallback_env = "ATTY_TEST_NEVER", .api_key_env = "ATTY_TEST_NEVER" } },
        .providers = &.{
            .{ .name = "a", .config = .{ .http = .{ .model = "a" } } },
            .{ .name = "b", .config = .{ .http = .{ .model = "b" } } },
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

    rt.dialog_persistent_mode = .dialog;
    try testing.expect(!rt.ai_mode_active);
    try testing.expect(!rt.chat_inline_open);
    try testing.expect(!rt.chat_overlay_open);
    const consumed = try L.onAction(&rt, &ctx, .llm_exec_cycle_model);
    try testing.expect(consumed);
    try testing.expectEqual(@as(usize, 1), rt.current_provider_idx);
}

test "inline chat: Shift+Enter (CSI-u 13;2u) inserts a newline into the input buffer" {
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;

    _ = try L.onInput(&rt, &ctx, "hi");
    _ = try L.onInput(&rt, &ctx, "\x1B[13;2u");
    _ = try L.onInput(&rt, &ctx, "there");

    try testing.expectEqualStrings("hi\nthere", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
    try testing.expectEqual(@as(usize, 8), rt.chat_inline_input_cursor);
}

test "inline chat: Enter on all-whitespace buffer (incl. embedded newlines) is a no-op" {
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;

    // Two Shift+Enter presses then plain Enter — buffer is `\n\n`,
    // empty of actual content. The .enter path should clear without
    // pushing a turn.
    _ = try L.onInput(&rt, &ctx, "\x1B[13;2u");
    _ = try L.onInput(&rt, &ctx, "\x1B[13;2u");
    try testing.expectEqual(@as(usize, 2), rt.chat_inline_input_len);
    try testing.expectEqual(@as(usize, 0), rt.turns_len);

    _ = try L.onInput(&rt, &ctx, "\r");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_len);
    try testing.expectEqual(@as(usize, 0), rt.turns_len);
}

test "inline chat: Ctrl+Alt+Up grows panel height by one row" {
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

    // No-op when the panel is closed — action returns false so the
    // keystroke can flow through to whatever else binds it.
    try testing.expectEqual(false, try L.onAction(&rt, &ctx, .llm_chat_inline_grow));
    try testing.expectEqual(@as(?u16, null), rt.chat_inline_rows_override);

    rt.chat_inline_open = true;
    // Grow once — override jumps from null (= cfg default, 10) to 11.
    try testing.expectEqual(true, try L.onAction(&rt, &ctx, .llm_chat_inline_grow));
    try testing.expect(rt.chat_inline_rows_override != null);
    try testing.expectEqual(@as(u16, 11), rt.chat_inline_rows_override.?);

    // Shrink twice — once back to 10, once to 9.
    _ = try L.onAction(&rt, &ctx, .llm_chat_inline_shrink);
    _ = try L.onAction(&rt, &ctx, .llm_chat_inline_shrink);
    try testing.expectEqual(@as(u16, 9), rt.chat_inline_rows_override.?);
}

test "inline chat: shrink clamps at min height (3)" {
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

    rt.chat_inline_open = true;
    rt.chat_inline_rows_override = 3;
    // Already at min — shrink is a no-op (still consumes the action).
    try testing.expectEqual(true, try L.onAction(&rt, &ctx, .llm_chat_inline_shrink));
    try testing.expectEqual(@as(u16, 3), rt.chat_inline_rows_override.?);
}

test "inline chat: closing the panel clears the height override" {
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

    rt.chat_inline_open = true;
    rt.chat_inline_rows_override = 12;
    // Alt+C closes the panel — handler should drop the override.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(false, rt.chat_inline_open);
    try testing.expectEqual(@as(?u16, null), rt.chat_inline_rows_override);
}

test "inline chat: pasted UTF-8 (e.g. `•` = 0xE2 0x80 0xA2) lands in the buffer" {
    // Regression for Copilot review on #175 — parseChatKey's
    // printable-insert arm previously only accepted 0x20..0x7E
    // and dropped 0x80..0xFF as `.none`, so a paste of `•`
    // (3 UTF-8 bytes, all in the high range) silently vanished.
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;

    _ = try L.onInput(&rt, &ctx, "\u{2022} bullet");
    try testing.expectEqualStrings("\u{2022} bullet", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
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
