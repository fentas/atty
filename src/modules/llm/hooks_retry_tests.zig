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

test "retry banner: Esc dismisses without firing" {
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

    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "explain"));
    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;
    rt.chat_retry_pending = true;
    rt.dialog_state = .idle;

    _ = try L.onInput(&rt, &ctx, "\x1B");
    try testing.expect(!rt.chat_retry_pending);
    try testing.expectEqual(@as(@TypeOf(rt.dialog_state), .idle), rt.dialog_state);
}

test "retry banner: typing a printable clears the banner and lands in the buffer" {
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

    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "explain"));
    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;
    rt.chat_retry_pending = true;

    _ = try L.onInput(&rt, &ctx, "hi");
    try testing.expect(!rt.chat_retry_pending);
    try testing.expectEqualStrings("hi", rt.chat_inline_input_buf[0..rt.chat_inline_input_len]);
}

test "retry banner: panel close (Ctrl+D) clears the pending flag" {
    // Otherwise the banner would survive a panel close → reopen
    // cycle and ambush the user on the next session.
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

    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "explain"));
    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;
    rt.chat_retry_pending = true;

    _ = try L.onInput(&rt, &ctx, "\x04"); // Ctrl+D close
    try testing.expect(!rt.chat_inline_open);
    try testing.expect(!rt.chat_retry_pending);
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
