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

test "exec-no-return: ;D fires refocus + state advance even when ;C raced state .suggesting" {
    // User-reported regression: "sometimes I execute a command from
    // the LLM but it does not return to it (also does not refocus
    // chat)." Root cause: the previous early-return at onOutput
    // line ~2063 (gated on `dialog_state == .executing or
    // .capturing_output`) dropped every edge that arrived while
    // dialog_state was still `.suggesting` — including the `;C`
    // for the just-confirmed command, IF the shell raced ahead of
    // the proxy's `.suggesting → .executing` transition. Capture
    // never started, `;D` was a no-op for the state machine, AND
    // refocus never fired because the early-return ran ABOVE the
    // refocus block.
    //
    // The fix walks every edge regardless of dialog_state; the
    // inner gates guard transitions and `;C` now also accepts
    // `.suggesting` as a valid starting state. Net: even when
    // `;C → ;D` arrives in a single chunk with state `.suggesting`,
    // capturing kicks off, the buffer fills, state advances to
    // `.observation_ready`, AND refocus fires.
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = false;
    rt.chat_refocus_pending = true;
    // The race: state still `.suggesting` when `;C`/`;D` arrive.
    rt.dialog_state = .suggesting;

    try L.onOutput(&rt, &ctx, "\x1b]133;C\x07hello world\x1b]133;D\x07");

    try testing.expect(rt.chat_focus_in_panel);
    try testing.expect(!rt.chat_refocus_pending);
    try testing.expectEqual(@as(@TypeOf(rt.dialog_state), .observation_ready), rt.dialog_state);
    try testing.expectEqualStrings("hello world", rt.captured_output[0..rt.captured_output_len]);
}

test "exec-no-return: refocus fires even when no capture is in progress (state .idle)" {
    // The defensive sub-case: the early-return previously also blocked
    // refocus on a stray `;D` (e.g. the user ran an unrelated shell
    // command in between Alt+S and Enter, the chain emitted `;C`/`;D`
    // with the LLM dialog stuck at `.idle`/`.suggesting`). Refocus
    // should fire on ANY `;D` while `chat_refocus_pending` is armed —
    // the latch is a one-shot, the panel rejoining focus is always
    // the right call.
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = false;
    rt.chat_refocus_pending = true;
    rt.dialog_state = .idle; // no dialog active at all

    // No `;C` — just a bare `;D` (e.g. an unrelated shell command
    // finishing). The refocus block must still fire.
    try L.onOutput(&rt, &ctx, "stuff\x1b]133;D\x07");

    try testing.expect(rt.chat_focus_in_panel);
    try testing.expect(!rt.chat_refocus_pending);
}

test "chat exec continuation: onLineCommit advances .suggesting → .executing on a non-empty line" {
    // Module-side contract that the proxy-side bugfix relies on.
    //
    // Background (the full chain): after the LLM emitted `.exec`,
    // the panel defocused (chat_focus_in_panel=false) so the Enter
    // that runs the injected command flows to bash. The proxy used
    // to unconditionally skip line_state.applyInput whenever the
    // panel was open (anyInlineChatActive), which meant submit()
    // never fired on that Enter, lastCommitted() returned null,
    // dispatchLineCommit was short-circuited, and `onLineCommit`
    // never ran at all. Visible as "exec runs but the LLM never
    // continues" — `;C`/`;D` couldn't start capturing because the
    // state never reached `.executing`.
    //
    // The proxy now uses the focus-aware
    // `anyInlineChatConsumingInput` dispatcher so the Enter does
    // reach line_state and dispatchLineCommit fires. This test
    // pins the MODULE-SIDE contract that, once dispatchLineCommit
    // fires, `onLineCommit` advances `.suggesting → .executing`
    // on any non-empty trimmed line (the gate that determines
    // whether `;C`/`;D` start capturing). `onLineCommit` itself
    // doesn't read `chat_focus_in_panel`; the parked-focus state
    // in the setup is documentary, reflecting the user-visible
    // scenario the assertion stands in for.
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

test "dialogResetSoft: preserves turns + session_id for retry-eligible failures" {
    // User complaint: "⚠ subprocess timed out (60000ms)" wipes the
    // complete chat history. Root cause was handleDialogResponse's
    // n==0 path calling the full dialogReset (which freeTurns()
    // unconditionally). dialogResetSoft is the new path used when a
    // chat surface is open — clears in-flight state but keeps turns
    // and session_id so Alt+R can re-fire the same conversation.
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

    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "explain this error"));
    rt.session_id = try testing.allocator.dupe(u8, "sess-abc-123");
    rt.dialog_state = .generating;
    rt.in_flight = true;
    rt.chat_inline_open = true;
    // Seed the question-storage stripe to non-zero so the post-reset
    // assertion below actually proves the soft path clears it (otherwise
    // the field default of 0 would let the test pass vacuously and a
    // future revision that drops the clear would silently fall through).
    rt.question_choices_count = 3;

    helpers.dialogResetSoft(&rt, real_io);

    try testing.expectEqual(@as(@TypeOf(rt.dialog_state), .idle), rt.dialog_state);
    try testing.expect(!rt.in_flight);
    try testing.expectEqual(@as(usize, 1), rt.turns_len);
    try testing.expectEqualStrings("sess-abc-123", rt.session_id);
    // The soft path must also reset the question-storage stripe
    // (`question_choices_count`) — the chat-mode UI count
    // (`chat_question_choice_count`) was already covered, but the
    // storage count drifted in an earlier revision. Reset-list
    // parity with `dialogReset` is documented inline.
    try testing.expectEqual(@as(usize, 0), rt.question_choices_count);
    // dialogResetSoft preserves session_id; shutdownAndFree doesn't
    // free it for non-empty values, so free here to keep the test
    // leak-clean.
    testing.allocator.free(rt.session_id);
    rt.session_id = &.{};
}

test "chat exec failure path: handleDialogResponse n=0 preserves turns when chat is open" {
    // Direct integration test for the n==0 (worker failure) branch.
    // Drive the path that the user actually hits on a subprocess
    // timeout: chat panel open, pollShellInput surfaced n=0 with the
    // error slot populated, handleDialogResponse takes the chat-mode
    // soft path and leaves the user's last prompt visible.
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

    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "explain"));
    rt.chat_inline_open = true;
    rt.in_flight = true;
    rt.ai_mode_active = true;

    // Reach into the same internal seam handleDialogResponse uses on
    // n==0 — the soft-reset path. (handleDialogResponse is a private
    // helper; the assertions below pin the contract it must honor.)
    helpers.dialogResetSoft(&rt, real_io);
    try testing.expectEqual(@as(usize, 1), rt.turns_len);
    try testing.expect(!rt.in_flight);
}

test "llm_chat_retry: re-fires fireDialogRequest when chat open + last turn is .user" {
    // Pins the retry-action contract. The user pressed Alt+r after a
    // soft-reset timeout; with a `.user` turn still in the ring, the
    // action should re-fire the worker pipeline (visible here as
    // dialog_state advancing from .idle → .generating).
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
    rt.dialog_state = .idle;
    rt.in_flight = false;

    const consumed = try L.onAction(&rt, &ctx, .llm_chat_retry);
    try testing.expect(consumed);
    // fireDialogRequest sets dialog_state = .generating.
    try testing.expectEqual(@as(@TypeOf(rt.dialog_state), .generating), rt.dialog_state);
}

test "llm_chat_retry: refuses when no chat surface is open" {
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

    // Closed → action returns false so the keystroke can fall
    // through to whatever else binds the byte.
    try testing.expectEqual(false, try L.onAction(&rt, &ctx, .llm_chat_retry));
}

test "llm_chat_retry: no-op (with hint) when last turn isn't a user turn" {
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

    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "first"));
    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, "echo ok"));
    rt.chat_inline_open = true;
    rt.dialog_state = .idle;

    const consumed = try L.onAction(&rt, &ctx, .llm_chat_retry);
    // Consumed (so the binding doesn't fall through and emit `r` to
    // the shell) but dialog_state stays idle — no request fired.
    try testing.expect(consumed);
    try testing.expectEqual(@as(@TypeOf(rt.dialog_state), .idle), rt.dialog_state);
}

test "retry banner: Enter fires the retry when chat_retry_pending + .user turn at tail" {
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

    _ = try L.onInput(&rt, &ctx, "\r");
    try testing.expect(!rt.chat_retry_pending);
    try testing.expectEqual(@as(@TypeOf(rt.dialog_state), .generating), rt.dialog_state);
}
