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

test "sanitizeForStatus: ESC bytes stripped from env-derived endpoint" {
    var buf: [128]u8 = undefined;
    const out = hooks.sanitizeForStatus(&buf, "http://x\x1b[2J\x1b[0m");
    try testing.expectEqualStrings("http://x[2J[0m", out);
}

test "sanitizeForStatus: raw C1 (0x9B CSI) stripped" {
    var buf: [128]u8 = undefined;
    const out = hooks.sanitizeForStatus(&buf, "http://x\x9b" ++ "31m");
    try testing.expectEqualStrings("http://x31m", out);
}

test "sanitizeForStatus: UTF-8-encoded C1 (0xC2 0x9B) stripped" {
    var buf: [128]u8 = undefined;
    const out = hooks.sanitizeForStatus(&buf, "http://x\xc2\x9b" ++ "31m");
    try testing.expectEqualStrings("http://x31m", out);
}

test "sanitizeForStatus: legitimate UTF-8 multi-byte preserved" {
    var buf: [128]u8 = undefined;
    // U+00A3 POUND SIGN = 0xC2 0xA3 — outside the C1 range, passes
    // through unchanged.
    const out = hooks.sanitizeForStatus(&buf, "http://\xc2\xa3.example");
    try testing.expectEqualStrings("http://\xc2\xa3.example", out);
}

test "sanitizeForStatus: C0 + DEL stripped" {
    var buf: [128]u8 = undefined;
    const out = hooks.sanitizeForStatus(&buf, "\x01http://x\x07\x7fy");
    try testing.expectEqualStrings("http://xy", out);
}

test "sanitizeForStatus: empty input produces empty output" {
    var buf: [128]u8 = undefined;
    const out = hooks.sanitizeForStatus(&buf, "");
    try testing.expectEqualStrings("", out);
}

test "containsClearSequence: CSI 2J detected" {
    try testing.expect(hooks.containsClearSequence("\x1B[2J"));
    try testing.expect(hooks.containsClearSequence("foo\x1B[H\x1B[2Jbar"));
}

test "containsClearSequence: CSI 3J (scrollback) detected" {
    try testing.expect(hooks.containsClearSequence("\x1B[3J"));
}

test "containsClearSequence: RIS (ESC c) detected" {
    try testing.expect(hooks.containsClearSequence("\x1Bcfoo"));
}

test "containsClearSequence: SGR / cursor-only sequences do NOT trigger" {
    try testing.expect(!hooks.containsClearSequence("\x1B[31mred\x1B[0m"));
    try testing.expect(!hooks.containsClearSequence("\x1B[5;10H"));
    try testing.expect(!hooks.containsClearSequence("\x1B[K"));
    try testing.expect(!hooks.containsClearSequence("plain text"));
}

test "containsClearSequence: bare ESC at end-of-buf is not a false positive" {
    try testing.expect(!hooks.containsClearSequence("foo\x1B"));
    try testing.expect(!hooks.containsClearSequence("\x1B"));
    try testing.expect(!hooks.containsClearSequence(""));
}

test "containsClearSequence: detects sequence split across boundary via carry" {
    // Simulates the carry-buffer probe in onOutput: the previous
    // chunk ended with "\x1B[" and the next starts with "2J". The
    // probe concatenates carry + head and runs containsClearSequence
    // on the merged view, so the split sequence is still recognised.
    var probe: [12]u8 = undefined;
    const carry = "\x1B[";
    const head = "2Jfoo";
    @memcpy(probe[0..carry.len], carry);
    @memcpy(probe[carry.len .. carry.len + head.len], head);
    try testing.expect(hooks.containsClearSequence(probe[0 .. carry.len + head.len]));
}

test "chat overlay (Alt+Shift+C): opens empty when no conversation exists" {
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

    // Fresh runtime — no turns, no conclusion. The overlay is its
    // own chat entry point; opening it must succeed even with
    // nothing to recall.
    const consumed = try L.onAction(&rt, &ctx, .llm_chat_overlay_toggle);
    try testing.expect(consumed);
    try testing.expect(rt.chat_overlay_open);
    try testing.expect(rt.chat_overlay_paint_pending);
    try testing.expectEqual(@as(usize, 0), rt.turns_len);

    // Toggle again — should close.
    _ = try L.onAction(&rt, &ctx, .llm_chat_overlay_toggle);
    try testing.expect(!rt.chat_overlay_open);
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

    // Ctrl+C clears the typed prompt without closing the overlay
    // (PR follow-up to #390 — quick "scrub and start over" UX).
    try testing.expectEqual(m.Action{ .swallow = {} }, try L.onInput(&rt, &ctx, "\x03"));
    try testing.expectEqual(@as(usize, 0), rt.chat_input_len);
    try testing.expectEqual(@as(usize, 0), rt.chat_input_cursor);
    try testing.expect(rt.chat_overlay_open);
    // Retype so the rest of the assertions have a buffer to consume.
    try testing.expectEqual(m.Action{ .swallow = {} }, try L.onInput(&rt, &ctx, "hell"));

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

    // Seed a turn so the post-toggle overlay paint has content to
    // render — the mutual-exclusion contract is what's under test.
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

test "chat exec continuation: onLineCommit transitions .suggesting → .executing when focus is parked on shell" {
    // Regression for the post-#392 silence: after the LLM emitted
    // `.exec`, the panel defocused (chat_focus_in_panel=false) so
    // the Enter that runs the injected command flows to bash. The
    // proxy used to unconditionally skip line_state.applyInput
    // whenever the panel was open (anyInlineChatActive), which
    // meant submit() never fired, lastCommitted() returned null,
    // dispatchLineCommit was short-circuited, and onLineCommit's
    // .suggesting → .executing transition never ran. Visible as
    // "exec runs but the LLM never continues" — `;C`/`;D` couldn't
    // start capturing because the state never reached .executing.
    //
    // The proxy now uses the focus-aware
    // anyInlineChatConsumingInput dispatcher (panel open AND focus
    // in panel). This test pins the module-side contract that
    // onLineCommit, when invoked with a non-empty line and state
    // .suggesting, advances to .executing.
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

    // Mimic the state immediately after the LLM emitted .exec and
    // the proxy injected the suggested command: chat is open,
    // focus parked on shell, dialog in .suggesting.
    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = false;
    rt.dialog_state = .suggesting;

    // User presses Enter on the injected command. The proxy's
    // focus-aware gate now lets line_state observe the Enter,
    // submit() fires, lastCommitted() returns the line, and
    // dispatchLineCommit routes here.
    try L.onLineCommit(&rt, &ctx, "ls -la");
    try testing.expectEqual(@as(@TypeOf(rt.dialog_state), .executing), rt.dialog_state);
}

test "chat exec continuation: isInlineChatConsumingInput false when focus is parked on shell" {
    // Pins the dispatcher contract that fixes the above stall.
    // Open + focused → consuming (proxy suppresses line_state).
    // Open + parked  → NOT consuming (proxy must feed line_state).
    // Closed         → NOT consuming.
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

    rt.chat_inline_open = false;
    rt.chat_focus_in_panel = true;
    try testing.expect(!L.isInlineChatConsumingInput(&rt));

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;
    try testing.expect(L.isInlineChatConsumingInput(&rt));

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = false;
    try testing.expect(!L.isInlineChatConsumingInput(&rt));
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

test "inline chat: bracketed paste of multi-line text inserts newlines (no submit)" {
    // Without bracketed-paste detection, pasted text containing `\n`
    // hit the `.enter` arm of parseChatKey and submitted at the first
    // newline (the tail was lost). With the `\x1B[200~ … \x1B[201~`
    // framing, every byte between the markers is content: `\n` and
    // `\r` insert as literal newlines, control bytes are dropped, the
    // markers themselves are swallowed silently.
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

    _ = try L.onInput(&rt, &ctx, "\x1B[200~line one\nline two\nline three\x1B[201~");
    try testing.expectEqualStrings("line one\nline two\nline three", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
    try testing.expect(!rt.chat_paste_active);
    // Cursor lands at end of pasted content.
    try testing.expectEqual(rt.chat_inline_input_len, rt.chat_inline_input_cursor);
}

test "inline chat: bracketed paste straddling chunk boundaries (\\r → \\n in content)" {
    // The closing marker can arrive in a separate `onInput` call from
    // the opening marker — verify state survives. Also pin that `\r`
    // inside the paste is normalised to `\n` (some clipboards inject
    // CR line endings).
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

    _ = try L.onInput(&rt, &ctx, "\x1B[200~first\r");
    try testing.expect(rt.chat_paste_active);
    _ = try L.onInput(&rt, &ctx, "second\x1B[201~");
    try testing.expect(!rt.chat_paste_active);
    try testing.expectEqualStrings("first\nsecond", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
}

test "inline chat: panel close resets chat_paste_active (no leaked paste mode)" {
    // Regression: a paste interrupted mid-stream (terminal sends
    // `\x1B[200~` then the user hits Ctrl+D before the closing marker
    // arrives) used to leave `chat_paste_active = true` forever. The
    // next session's Enter then folded to `\n` instead of submit.
    // Every chat-panel close site now resets the flag.
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

    // Start a paste, then close via Ctrl+D before the closing marker
    // arrives.
    _ = try L.onInput(&rt, &ctx, "\x1B[200~half a paste");
    try testing.expect(rt.chat_paste_active);
    _ = try L.onInput(&rt, &ctx, "\x04");
    try testing.expect(!rt.chat_inline_open);
    try testing.expect(!rt.chat_paste_active);
}

test "inline chat: Alt+C toggle close also resets chat_paste_active" {
    // Round-2 subagent caught this site: the panel-close direction of
    // `llm_inline_chat_toggle` flips `chat_inline_open` via `= !…`,
    // which the round-1 textual sweep for `= false` missed. Without
    // the reset there, a paste interrupted by Alt+C-close left the
    // flag stuck `true` and the next session's Enter folded to `\n`.
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

    // Statusbar must be configured for the inline chat toggle action
    // to actually flip `chat_inline_open` — atty refuses to open the
    // inline panel without reserved rows underneath it.
    ctx.statusbar_base_reserve = 3;
    ctx.statusbar_reserve = 3;
    ctx.terminal_rows = 24;
    ctx.terminal_cols = 80;

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(rt.chat_inline_open);
    rt.chat_focus_in_panel = true;

    // Start a paste, then close via Alt+C before the closing marker.
    _ = try L.onInput(&rt, &ctx, "\x1B[200~half a paste");
    try testing.expect(rt.chat_paste_active);
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(!rt.chat_inline_open);
    try testing.expect(!rt.chat_paste_active);
}

test "inline chat: Alt+Enter inserts a newline (legacy Shift+Enter fallback)" {
    // Terminals not in kitty kbd mode can't distinguish Enter from
    // Shift+Enter. Alt+Enter (`\x1B\r` or `\x1B\n`) is the standard
    // chat-UI workaround (Slack, Discord, ChatGPT web, …) and lands
    // on the same `.insert = '\n'` action as the kitty-kbd
    // `\x1B[13;2u`.
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
    _ = try L.onInput(&rt, &ctx, "\x1B\r");
    _ = try L.onInput(&rt, &ctx, "there");
    try testing.expectEqualStrings("hi\nthere", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
}

test "inline chat: Ctrl+C clears the typed prompt (keeps panel open)" {
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

    _ = try L.onInput(&rt, &ctx, "explain this");
    try testing.expectEqual(@as(usize, 12), rt.chat_inline_input_len);
    try testing.expectEqual(@as(usize, 12), rt.chat_inline_input_cursor);

    _ = try L.onInput(&rt, &ctx, "\x03");
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_len);
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_cursor);
    try testing.expect(rt.chat_inline_open);
    try testing.expect(rt.chat_focus_in_panel);
}

test "inline chat: Up/Down arrow navigates between lines (column-preserving)" {
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

    // Buffer: "hello\nworld\nhi"   indices: h(0)e(1)l(2)l(3)o(4)\n(5)w(6)o(7)r(8)l(9)d(10)\n(11)h(12)i(13).
    // Populate directly — onInput would interpret a literal `\n`
    // chunk as Enter and submit; multi-line content comes in via
    // bracketed paste / Alt+Enter / Shift+Enter in practice.
    const buf_contents = "hello\nworld\nhi";
    @memcpy(rt.chat_inline_input_buf[0..buf_contents.len], buf_contents);
    rt.chat_inline_input_len = buf_contents.len;
    rt.chat_inline_input_cursor = buf_contents.len;

    // Up from end-of-last-line (col 2) → land on "world" at col 2 (between `o` and `r`, position 8).
    _ = try L.onInput(&rt, &ctx, "\x1B[A");
    try testing.expectEqual(@as(usize, 8), rt.chat_inline_input_cursor);

    // Up again → "hello" at col 2 (position 2).
    _ = try L.onInput(&rt, &ctx, "\x1B[A");
    try testing.expectEqual(@as(usize, 2), rt.chat_inline_input_cursor);

    // Up from the first line → no-op.
    _ = try L.onInput(&rt, &ctx, "\x1B[A");
    try testing.expectEqual(@as(usize, 2), rt.chat_inline_input_cursor);

    // Down → "world" col 2 (position 8).
    _ = try L.onInput(&rt, &ctx, "\x1B[B");
    try testing.expectEqual(@as(usize, 8), rt.chat_inline_input_cursor);

    // Down → "hi" — only 2 chars, col 2 means EOL (position 14).
    _ = try L.onInput(&rt, &ctx, "\x1B[B");
    try testing.expectEqual(@as(usize, 14), rt.chat_inline_input_cursor);

    // Down from the last line → no-op.
    _ = try L.onInput(&rt, &ctx, "\x1B[B");
    try testing.expectEqual(@as(usize, 14), rt.chat_inline_input_cursor);
}

test "inline chat: Up arrow clamps column when the prior line is shorter" {
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

    // Buffer: "hi\nworld" — cursor at EOL position 8 (col 5 in line "world").
    const buf_contents = "hi\nworld";
    @memcpy(rt.chat_inline_input_buf[0..buf_contents.len], buf_contents);
    rt.chat_inline_input_len = buf_contents.len;
    rt.chat_inline_input_cursor = buf_contents.len;

    // Up: prior line "hi" is only 2 chars — clamp to EOL of "hi" = position 2.
    _ = try L.onInput(&rt, &ctx, "\x1B[A");
    try testing.expectEqual(@as(usize, 2), rt.chat_inline_input_cursor);
}

test "inline chat: grow action clamps the override to terminal height" {
    // A held Ctrl+Alt+Up previously kept incrementing
    // `chat_inline_rows_override` past the terminal's real height —
    // paintInlineChat would then overflow its fixed buffer and trip
    // recoverInlineChatPaintFailure, slamming the panel shut. With
    // the terminal-aware cap in place, grow stops at
    // `terminal_rows - base_reserve - headroom - top_gap`.
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
        .terminal_rows = 24,
        .terminal_cols = 80,
        .statusbar_base_reserve = 3,
        .statusbar_reserve = 3,
    };

    rt.chat_inline_open = true;

    // top_gap default is 1, base_reserve=3, headroom=4 ⇒ cap = 24-3-4-1 = 16.
    // Fire grow 200 times to mimic a held key. After saturation the
    // override should stop at 16 — never exceeding `terminal_rows`.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        _ = try L.onAction(&rt, &ctx, .llm_chat_inline_grow);
    }
    try testing.expect(rt.chat_inline_rows_override != null);
    try testing.expect(rt.chat_inline_rows_override.? <= 16);
    try testing.expect(rt.chat_inline_open);
}

test "inline chat: paint failure clears the height override" {
    // Belt-and-braces for the grow clamp above. Even if some future
    // change re-introduces an unclamped override (or the user
    // shrinks the terminal so a previously-fine value now overflows),
    // recoverInlineChatPaintFailure must drop the override so the
    // next reopen starts at the default size — otherwise the overflow
    // loops forever on every Alt+C.
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

    rt.chat_inline_open = true;
    rt.chat_inline_rows_override = 200;
    rt.chat_inline_paint_pending = true;

    // The paint buffer is ~64 KB; 200 rows of input chrome fit, so
    // we can't reliably force the overflow path via paintInlineChat
    // alone. Hit recoverInlineChatPaintFailure directly — its
    // contract is "panel closed AND override cleared," which is
    // what the held-key recovery relies on.
    paint.Module(L.config, L.Runtime).recoverInlineChatPaintFailureForTest(&rt);
    try testing.expect(!rt.chat_inline_open);
    try testing.expect(rt.chat_inline_rows_override == null);
}

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
