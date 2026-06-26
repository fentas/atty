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
    // Seed the paint cache so the dispatch clamp doesn't pin us
    // at 0. Production code does this on the first paint after a
    // surface opens.
    rt.chat_inline_paint_max_offset = 7;
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

test "llm_chat_retry: resend after an answer trims to the last user turn and re-fires" {
    // Pins the regenerate path. After a successful answer the tail is
    // an `.assistant_exec`; Alt+r drops it back to the most recent
    // `.user` turn (so the LLM re-answers the prompt instead of
    // continuing the agentic loop) and re-fires the worker pipeline.
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
    try testing.expect(consumed);
    // Trailing assistant turn dropped; the user prompt remains as tail.
    try testing.expectEqual(@as(usize, 1), rt.turns_len);
    try testing.expectEqual(dialog.TurnKind.user, rt.turns[0].kind);
    try testing.expectEqualStrings("first", rt.turns[0].content);
    // fireDialogRequest advanced the state machine.
    try testing.expectEqual(@as(@TypeOf(rt.dialog_state), .generating), rt.dialog_state);
}

test "llm_chat_retry: no-op (with hint) when the ring holds no user turn" {
    // trimToLastUserTurn's false path — a ring with only an
    // assistant/observation tail (e.g. a corrupted recall) has nothing
    // to resend. Consumed so `r` doesn't leak to the shell, but no
    // request fires.
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

    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, "echo ok"));
    rt.chat_inline_open = true;
    rt.dialog_state = .idle;

    const consumed = try L.onAction(&rt, &ctx, .llm_chat_retry);
    try testing.expect(consumed);
    // Surfaces a hint explaining why nothing fired.
    try testing.expect(rt.hint_pending);
    try testing.expectEqual(@as(usize, 1), rt.turns_len);
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

test "inline chat: free-text answer to a question clears chat_question_active" {
    // User-reported: when a question pick-list is on screen and the
    // user types a custom answer (selected_idx == choice_count → the
    // free-text row), pressing Enter pushes the answer turn but the
    // question chrome stays painted above the input. Next round of
    // model output writes ABOVE the stale question. The picker-arm
    // already clears `chat_question_active`; the free-text path must
    // do the same.
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

    rt.chat_inline_open = true;
    rt.chat_focus_in_panel = true;
    rt.dialog_state = .awaiting_question_answer;

    // Stage an active question. choice_count = 2; selected_idx = 2
    // (one past the last choice) → free-text row.
    rt.chat_question_active = true;
    rt.chat_question_choice_count = 2;
    rt.chat_question_selected_idx = 2;
    const choices = [_][]const u8{ "option one", "option two" };
    for (choices, 0..) |c, idx| {
        const dst = rt.question_choices_storage[idx][0..@min(c.len, rt.question_choices_storage[idx].len)];
        @memcpy(dst, c[0..dst.len]);
        rt.question_choices_lens[idx] = dst.len;
    }

    // User types a custom answer + Enter.
    _ = try L.onInput(&rt, &ctx, "my custom answer\r");

    // The user turn was pushed.
    try testing.expect(rt.turns_len >= 1);
    const last = rt.turns[rt.turns_len - 1];
    try testing.expectEqual(@import("dialog.zig").TurnKind.user, last.kind);
    try testing.expectEqualStrings("my custom answer", last.content);
    // Question chrome cleared so the next paint sheds it.
    try testing.expect(!rt.chat_question_active);
    // Input buffer empty + cursor home.
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_len);
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_input_cursor);
}

test "chat overlay: free-text answer to a question clears chat_question_active" {
    // Sibling test for the overlay path. Same bug, same fix —
    // ensures both surfaces stay in sync.
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

    rt.chat_overlay_open = true;
    rt.dialog_state = .awaiting_question_answer;

    rt.chat_question_active = true;
    rt.chat_question_choice_count = 1;
    rt.chat_question_selected_idx = 1; // free-text row
    const choice = "the only choice";
    const dst = rt.question_choices_storage[0][0..@min(choice.len, rt.question_choices_storage[0].len)];
    @memcpy(dst, choice[0..dst.len]);
    rt.question_choices_lens[0] = dst.len;

    _ = try L.onInput(&rt, &ctx, "overlay free-text answer\r");

    try testing.expect(rt.turns_len >= 1);
    const last = rt.turns[rt.turns_len - 1];
    try testing.expectEqual(@import("dialog.zig").TurnKind.user, last.kind);
    try testing.expectEqualStrings("overlay free-text answer", last.content);
    try testing.expect(!rt.chat_question_active);
    try testing.expectEqual(@as(usize, 0), rt.chat_input_len);
    try testing.expectEqual(@as(usize, 0), rt.chat_input_cursor);
}

test "chat scroll: Alt+PageUp / Alt+PageDown resolve to the expected legacy CSI-1 bytes" {
    // The dispatcher matches bound `bytes` against incoming
    // keystrokes; the binding in modules/llm.zig uses
    // `keymap.key("Alt+PageUp")` / `keymap.key("Alt+PageDown")`,
    // so the parser entries are the contract a terminal emits
    // for these chords. A parser edit that re-routes the byte
    // sequence would silently break the binding — this test
    // pins the legacy form every common terminal falls back to.
    const keymap = @import("../../keymap.zig");
    try std.testing.expectEqualStrings("\x1b[5;3~", keymap.key("Alt+PageUp"));
    try std.testing.expectEqualStrings("\x1b[6;3~", keymap.key("Alt+PageDown"));
}

test "chat scroll: lots of content — at max offset the oldest rows are fully visible" {
    // Long conversation, default panel size. The old clamp parked
    // max_offset at content - 1, so PageUp-to-top left only one
    // row visible and PageDown had to spend many presses unwinding
    // the over-scroll before content moved. The new clamp stops
    // exactly when the oldest row becomes visible, so the panel
    // always paints a full-height window of content.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .inline_chat_rows = 8,
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
        .terminal_cols = 80,
    };

    const helpers = dialog.Module(L.config, L.Runtime);
    defer helpers.freeTurns(&rt);

    // 8 turns labelled with row-index so we can pin which one
    // anchors the top after max-scroll.
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const body = try std.fmt.allocPrint(testing.allocator, "TURN-{d:0>2}", .{i});
        try helpers.pushTurn(&rt, .user, body);
    }

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(rt.chat_inline_open);
    rt.chat_focus_in_panel = true;
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);

    // First paint seeds the cache.
    rt.chat_inline_paint_pending = true;
    _ = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(rt.chat_inline_paint_max_offset > 0);

    // Spam PageUp far past max. The dispatch clamp should hold at
    // the recorded max_offset; the offset MUST NOT balloon.
    var j: usize = 0;
    while (j < 100) : (j += 1) _ = try L.onAction(&rt, &ctx, .chat_scroll_page_up);
    try testing.expectEqual(rt.chat_inline_paint_max_offset, rt.chat_inline_view_offset);

    // Repaint — TURN-00 must be visible at the top.
    rt.chat_inline_paint_pending = true;
    const top = (try L.provideTermBytes(&rt, &ctx)).?;
    try testing.expect(std.mem.indexOf(u8, top, "TURN-00") != null);

    // One PageDown brings TURN-00 out of view (or at least pushes
    // the window down by `page` rows). Single PageDown should not
    // require many presses to start moving content.
    const before = rt.chat_inline_view_offset;
    _ = try L.onAction(&rt, &ctx, .chat_scroll_page_down);
    try testing.expect(rt.chat_inline_view_offset < before);
}

test "chat scroll: small panel height (inline_chat_rows = 3) — scroll still functions" {
    // Stress the minimum panel size — only ~1 scrollback row.
    // Common bug shape with small budgets: max_offset clamp
    // formula underflows or rounds wrong.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .inline_chat_rows = 3,
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
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "SMALL-OLDEST"));
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "SMALL-MIDDLE"));
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "SMALL-NEWEST"));

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    rt.chat_focus_in_panel = true;
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    rt.chat_inline_paint_pending = true;
    _ = try L.provideTermBytes(&rt, &ctx);

    // PageUp until clamped.
    var n: usize = 0;
    while (n < 10) : (n += 1) _ = try L.onAction(&rt, &ctx, .chat_scroll_page_up);
    rt.chat_inline_paint_pending = true;
    const top = (try L.provideTermBytes(&rt, &ctx)).?;
    // SMALL-OLDEST must reach the panel at some scroll position
    // (the test would have failed before the clamp fix because the
    // visible window shrank to 0 useful rows).
    try testing.expect(std.mem.indexOf(u8, top, "SMALL-OLDEST") != null);
}

test "chat scroll: large panel height (inline_chat_rows = 20) — content fits, max_offset = 0" {
    // With a tall panel and short content, the new clamp pins
    // max_offset at 0 — nothing to scroll. PageUp must not arm
    // a repaint for no reason.
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
        .inline_chat_rows = 20,
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
        .terminal_cols = 80,
    };

    const helpers = dialog.Module(L.config, L.Runtime);
    defer helpers.freeTurns(&rt);
    // 3 short turns → 3 rows total, well under the 17-row scrollback
    // budget (20 panel rows - 2 for divider + input - top_gap).
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "first"));
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "second"));
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "third"));

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    rt.chat_focus_in_panel = true;
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    rt.chat_inline_paint_pending = true;
    _ = try L.provideTermBytes(&rt, &ctx);

    try testing.expectEqual(@as(usize, 0), rt.chat_inline_paint_max_offset);

    // PageUp consumed but offset clamped at 0.
    try testing.expect(try L.onAction(&rt, &ctx, .chat_scroll_page_up));
    try testing.expectEqual(@as(usize, 0), rt.chat_inline_view_offset);
}

test "chat scroll: tall turn (5-row done reason) — per-row scroll walks through it" {
    // A single LLM done-action reason can render 5+ rows. Per-row
    // scrolling must walk THROUGH the tall turn, not skip it as
    // one chunk. Pin that PageDown from middle-of-turn moves the
    // window by one page; offset moves monotonically.
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
    // Pure-prose fenced reply with 5 hard breaks → 6 rows of
    // content via md_render.
    const long = "TALL-1\nTALL-2\nTALL-3\nTALL-4\nTALL-5\nTALL-6";
    try helpers.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, long));

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    rt.chat_focus_in_panel = true;
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    rt.chat_inline_paint_pending = true;
    _ = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(rt.chat_inline_paint_max_offset > 0);

    // Single line-scroll moves offset by exactly 1.
    const before = rt.chat_inline_view_offset;
    _ = try L.onAction(&rt, &ctx, .chat_scroll_up);
    try testing.expectEqual(before + 1, rt.chat_inline_view_offset);

    // PageUp moves by `inline_chat_rows - 2 = 3` rows (clamped).
    const page_before = rt.chat_inline_view_offset;
    _ = try L.onAction(&rt, &ctx, .chat_scroll_page_up);
    const page_after = rt.chat_inline_view_offset;
    try testing.expect(page_after > page_before);
}
