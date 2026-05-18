//! Tests for `modules/llm.zig`. Lifted out so the implementation
//! file stays readable — the inline-tests pattern was costing ~1700
//! lines and made the configure() body hard to scan.
//!
//! Naming follows the project-wide convention: source-file siblings
//! live as `<name>_tests.zig` in the SAME directory.

const std = @import("std");
const testing = std.testing;

const llm = @import("llm.zig");
const configure = llm.configure;
const m = @import("../module.zig");
const dialog = llm.dialog_ns;
const parse = @import("llm/parse.zig");

const test_io: std.Io = std.Io.failing;

// Pull in sibling parse-tests so test discovery cascades.
test {
    _ = parse;
}

test "configure exposes the expected hooks" {
    const L = configure(.{});
    try testing.expect(@hasDecl(L, "onInput"));
    try testing.expect(@hasDecl(L, "pollShellInput"));
    try testing.expect(@hasDecl(L, "statusText"));
    try testing.expectEqualStrings("llm", L.name);
}

test "buildRequestBody produces well-formed OpenAI chat-completion JSON" {
    const L = configure(.{ .model = "test-model" });
    const body = try L.buildRequestBody(testing.allocator, "test-model", "be terse", "bash", "", "list zig files");
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"test-model\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "be terse") != null);
    try testing.expect(std.mem.indexOf(u8, body, "Generate a bash command to: list zig files") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
    // No raw newlines in the JSON — system prompt may have them
    // and they must be escaped to \n.
    for (body) |c| try testing.expect(c != '\n');
}

test "buildRequestBody escapes user content correctly (quotes + backslashes)" {
    const L = configure(.{});
    const body = try L.buildRequestBody(
        testing.allocator,
        "m",
        "sys",
        "bash",
        "",
        "echo \"hello\\world\"",
    );
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\\\"hello") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\\\\world") != null);
}

test "buildRequestBody appends a context blob when provided" {
    const L = configure(.{});
    const body = try L.buildRequestBody(
        testing.allocator,
        "m",
        "sys",
        "bash",
        "PATH_BASE=/opt/foo, PROJECT=acme",
        "list files",
    );
    defer testing.allocator.free(body);
    // The user message should now include "Context: …" after the
    // task; the literal commas + paths must survive JSON encoding
    // (commas are not escaped — `/` may be encoded as `\/` but
    // we expect it bare since we don't request slash escapes).
    try testing.expect(std.mem.indexOf(u8, body, "Generate a bash command to: list files") != null);
    try testing.expect(std.mem.indexOf(u8, body, "Context: PATH_BASE=/opt/foo, PROJECT=acme") != null);
}

test "buildRequestBody omits the context section entirely when blob is empty" {
    const L = configure(.{});
    const body = try L.buildRequestBody(
        testing.allocator,
        "m",
        "sys",
        "bash",
        "",
        "list files",
    );
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "Context:") == null);
}

test "extractCommand pulls choices[0].message.content out of a chat response" {
    const L = configure(.{});
    var out: [64]u8 = undefined;
    const sample =
        \\{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":"ls *.zig"}}]}
    ;
    const n = L.extractCommand(sample, &out);
    try testing.expectEqualStrings("ls *.zig", out[0..n]);
}

test "extractCommand strips ```bash code fences" {
    const L = configure(.{});
    var out: [128]u8 = undefined;
    const sample =
        "{\"choices\":[{\"message\":{\"content\":\"```bash\\nls -la\\n```\"}}]}";
    const n = L.extractCommand(sample, &out);
    try testing.expectEqualStrings("ls -la", out[0..n]);
}

test "extractCommand decodes the common JSON escapes" {
    const L = configure(.{});
    var out: [128]u8 = undefined;
    const sample = "{\"choices\":[{\"message\":{\"content\":\"echo \\\"hi\\\"\"}}]}";
    const n = L.extractCommand(sample, &out);
    try testing.expectEqualStrings("echo \"hi\"", out[0..n]);
}

test "extractCommand skips uncommon escapes (\\b, \\f) without leaking the escape code char" {
    const L = configure(.{});
    var out: [128]u8 = undefined;
    // `\b` (backspace): both \ and b must be skipped, output is "ab" not "abb".
    const sample_b = "{\"choices\":[{\"message\":{\"content\":\"a\\bb\"}}]}";
    try testing.expectEqualStrings("ab", out[0..L.extractCommand(sample_b, &out)]);
    // `\f` (form feed): both \ and f must be skipped.
    const sample_f = "{\"choices\":[{\"message\":{\"content\":\"a\\fb\"}}]}";
    try testing.expectEqualStrings("ab", out[0..L.extractCommand(sample_f, &out)]);
}

test "extractCommand skips \\uXXXX unicode escapes cleanly" {
    const L = configure(.{});
    var out: [128]u8 = undefined;
    // Valid \u0020: skipped entirely (not decoded to a space), "ls-la" not "lsu0020-la".
    const sample_valid = "{\"choices\":[{\"message\":{\"content\":\"ls\\u0020-la\"}}]}";
    try testing.expectEqualStrings("ls-la", out[0..L.extractCommand(sample_valid, &out)]);
    // Malformed \u with only 2 hex digits before the closing quote: must not
    // skip past the closing " and extract garbage from the surrounding JSON.
    const sample_malformed = "{\"choices\":[{\"message\":{\"content\":\"ls\\u01\"}}]}";
    try testing.expectEqualStrings("ls", out[0..L.extractCommand(sample_malformed, &out)]);
}

test "extractCommand only takes the first non-empty line (multi-line replies)" {
    const L = configure(.{});
    var out: [128]u8 = undefined;
    // Model returned a one-liner + chatter. We want only the command.
    const sample = "{\"choices\":[{\"message\":{\"content\":\"ls -la\\n# this lists all files\"}}]}";
    const n = L.extractCommand(sample, &out);
    try testing.expectEqualStrings("ls -la", out[0..n]);
}

test "extractCommand returns 0 on missing content field" {
    const L = configure(.{});
    var out: [32]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), L.extractCommand("{\"error\":\"bad\"}", &out));
}

test "extractCommand tolerates whitespace around the `\"content\":` key (pretty-printed JSON)" {
    // Not every OpenAI-compatible server emits compact JSON. Some
    // proxies and llama.cpp builds pretty-print the response. The
    // scanner has to skip whitespace + tabs + newlines between
    // `"content"`, `:`, and the opening quote of the value.
    const L = configure(.{});
    var out: [32]u8 = undefined;

    const pretty =
        \\{
        \\  "choices": [
        \\    { "message": { "role": "assistant", "content": "ls -la" } }
        \\  ]
        \\}
    ;
    try testing.expectEqual(@as(usize, 6), L.extractCommand(pretty, &out));
    try testing.expectEqualStrings("ls -la", out[0..6]);

    // Tabs between key/colon/value should also work.
    const tabbed = "{\"content\"\t:\t\"echo hi\"}";
    try testing.expectEqual(@as(usize, 7), L.extractCommand(tabbed, &out));
    try testing.expectEqualStrings("echo hi", out[0..7]);
}

test "extractCommand drops decoded \\r — never inject a CR that would auto-execute (security)" {
    // Attack scenario: model returns `cmd1\\r cmd2` in JSON. A
    // naive decoder would convert `\\r` to a literal CR; writing
    // that to the PTY acts as Enter, so cmd1 runs without user
    // review and `cmd2` lands on the next prompt. With the
    // 'r' arm dropping the byte entirely, the user sees the full
    // string and decides whether to run it.
    const L = configure(.{});
    var out: [128]u8 = undefined;
    const sample = "{\"choices\":[{\"message\":{\"content\":\"echo hi\\r && rm -rf /\"}}]}";
    const n = L.extractCommand(sample, &out);
    try testing.expectEqualStrings("echo hi && rm -rf /", out[0..n]);
    // And no raw \r anywhere in the output.
    for (out[0..n]) |b| try testing.expect(b != '\r');
}

test "extractResponse splits explanation + fenced command" {
    const L = configure(.{});
    var cmd_out: [128]u8 = undefined;
    var exp_out: [256]u8 = undefined;
    // Compact JSON body with the explanation+fence format.
    const body = "{\"choices\":[{\"message\":{\"content\":\"Lists files in long format.\\n```\\nls -la\\n```\"}}]}";
    const r = L.extractResponse(body, &cmd_out, &exp_out);
    try testing.expectEqualStrings("ls -la", cmd_out[0..r.cmd_len]);
    try testing.expectEqualStrings("Lists files in long format.", exp_out[0..r.explanation_len]);
}

test "extractResponse — no fence falls back to command-only (legacy model)" {
    const L = configure(.{});
    var cmd_out: [128]u8 = undefined;
    var exp_out: [256]u8 = undefined;
    const body = "{\"choices\":[{\"message\":{\"content\":\"ls -la\"}}]}";
    const r = L.extractResponse(body, &cmd_out, &exp_out);
    try testing.expectEqualStrings("ls -la", cmd_out[0..r.cmd_len]);
    try testing.expectEqual(@as(usize, 0), r.explanation_len);
}

test "extractResponse — missing content field returns zero lengths" {
    const L = configure(.{});
    var cmd_out: [128]u8 = undefined;
    var exp_out: [256]u8 = undefined;
    const r = L.extractResponse("{\"error\":\"bad\"}", &cmd_out, &exp_out);
    try testing.expectEqual(@as(usize, 0), r.cmd_len);
    try testing.expectEqual(@as(usize, 0), r.explanation_len);
}

test "effective_system_prompt picks the with-explanation default" {
    const L_on = configure(.{ .with_explanation = true });
    const L_off = configure(.{ .with_explanation = false });
    // The two defaults differ in their guidance about fences /
    // explanations; pin that they don't collapse to the same string.
    try testing.expect(!std.mem.eql(u8, L_on.effective_system_prompt, L_off.effective_system_prompt));
    // The with-explanation prompt should reference the fence /
    // explanation guidance.
    try testing.expect(std.mem.indexOf(u8, L_on.effective_system_prompt, "fenced") != null);
    try testing.expect(std.mem.indexOf(u8, L_off.effective_system_prompt, "No markdown") != null);
}

test "effective_system_prompt honours an explicit override" {
    const L = configure(.{ .with_explanation = true, .system_prompt = "be terse" });
    // User override replaces the task-framing slot but the
    // invariant atty preamble stays at the head. The override
    // must appear in full at the tail.
    try testing.expect(std.mem.endsWith(u8, L.effective_system_prompt, "be terse"));
    // Preamble survives — meta-question routing isn't lost on
    // override.
    try testing.expect(std.mem.indexOf(u8, L.effective_system_prompt, "inside atty") != null);
    try testing.expect(std.mem.indexOf(u8, L.effective_system_prompt, "Alt+S") != null);
}

// Helper: attach the module and (eagerly) tear down the worker
// thread synchronously so leak detection stays happy for tests
// that only care about config resolution. Production `detach()`
// uses `t.detach()` which intentionally leaks at process exit.
fn shutdownAndFree(comptime L: type, rt: *L.Runtime, io: std.Io) void {
    if (rt.thread) |t| {
        {
            rt.shared.mutex.lockUncancelable(io);
            defer rt.shared.mutex.unlock(io);
            rt.shared.shutdown = true;
            rt.shared.cv.signal(io);
        }
        t.join();
    }
    rt.allocator.destroy(rt.shared);
    rt.allocator.free(rt.api_base);
    rt.allocator.free(rt.api_key);
    rt.allocator.free(rt.shell);
    rt.allocator.free(rt.context_blob);
    rt.allocator.free(rt.os_info);
    rt.allocator.destroy(rt.captured_output);
    rt.allocator.destroy(rt.last_assistant_json);
}

test "resolveApiBase priority — static cfg.api_base beats both env vars" {
    // With cfg.api_base set, the env vars must NOT be consulted.
    _ = libc.setenv("ATTY_TEST_BASE_PRIMARY", "http://from-env-primary:1234/v1", 1);
    _ = libc.setenv("ATTY_TEST_BASE_FALLBACK", "http://from-env-fallback:5678", 1);
    defer _ = libc.unsetenv("ATTY_TEST_BASE_PRIMARY");
    defer _ = libc.unsetenv("ATTY_TEST_BASE_FALLBACK");

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();

    const L = configure(.{
        .api_base = "http://static-config:9999/v1",
        .api_base_env = "ATTY_TEST_BASE_PRIMARY",
        .api_base_fallback_env = "ATTY_TEST_BASE_FALLBACK",
        .api_key_env = "ATTY_TEST_BASE_NEVER",
    });
    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);

    try testing.expectEqualStrings("http://static-config:9999/v1", rt.api_base);
}

test "resolveApiBase priority — env wins when cfg.api_base is empty" {
    _ = libc.setenv("ATTY_TEST_BASE_PRIMARY2", "http://from-env:1234/v1", 1);
    defer _ = libc.unsetenv("ATTY_TEST_BASE_PRIMARY2");

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();

    const L = configure(.{
        // .api_base default = ""
        .api_base_env = "ATTY_TEST_BASE_PRIMARY2",
        .api_base_fallback_env = "ATTY_TEST_BASE_NEVER",
        .api_key_env = "ATTY_TEST_BASE_NEVER",
    });
    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);

    try testing.expectEqualStrings("http://from-env:1234/v1", rt.api_base);
}

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

    var line: @import("../line_state.zig").LineState = .{};
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

test "chat overlay (Alt+Shift+C): toggle emits alt-screen enter then exit" {
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

    var line: @import("../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = real_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    // Inject a fake turn so the overlay has content to render.
    // `pushTurn` is internal to `configure()`, so reach it via the
    // dialog factory the same way the module's own hooks do.
    const helpers = dialog.Module(L.config, L.Runtime);
    try helpers.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "explain X"));
    defer helpers.freeTurns(&rt);

    // Open.
    _ = try L.onAction(&rt, &ctx, .llm_chat_overlay_toggle);
    try testing.expect(rt.chat_overlay_open);
    try testing.expect(rt.chat_overlay_paint_pending);
    const opened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(opened != null);
    // Alt-screen enter + clear + home + title bar present.
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[?1049h") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[2J") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "atty chat") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "You:") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "explain X") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "[Alt+Shift+C close") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "Enter send") != null);
    // DECSTBM scroll region is set so long content can't clobber
    // the input + footer at the bottom (regression for the
    // "broken overlay" screenshot bug). Match `\x1B[1;<digits>r`
    // — the trailing `r` is the DECSTBM terminator and rules out
    // false positives from the cursor-home `\x1B[1;1H` also emitted
    // by the open sequence.
    {
        const idx = std.mem.indexOf(u8, opened.?, "\x1B[1;") orelse return error.TestUnexpectedResult;
        var j = idx + 4;
        while (j < opened.?.len and opened.?[j] >= '0' and opened.?[j] <= '9') : (j += 1) {}
        try testing.expect(j < opened.?.len);
        try testing.expectEqual(@as(u8, 'r'), opened.?[j]);
    }
    // Cyan chat input prompt glyph (input row).
    try testing.expect(std.mem.indexOf(u8, opened.?, "\u{276F}") != null);

    // Close.
    _ = try L.onAction(&rt, &ctx, .llm_chat_overlay_toggle);
    try testing.expect(!rt.chat_overlay_open);
    try testing.expect(rt.chat_overlay_paint_pending);
    const closed = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(closed != null);
    // Cursor-show + alt-screen exit, in that order (real cursor
    // was hidden on open so the overlay's reverse-video block
    // cursor wasn't doubled).
    // Close emits DECSTBM reset (defensive — even though
    // alt-screen exit should restore the primary screen's
    // scroll region), then show-cursor, then alt-screen exit.
    try testing.expectEqualStrings("\x1B[r\x1B[?25h\x1B[?1049l", closed.?);
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

    var line: @import("../line_state.zig").LineState = .{};
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

test "inline chat (Alt+C): toggle flips reserve-rows request and paints panel" {
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

    var line: @import("../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = real_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
        // Pretend a statusbar exists — the toggle handler refuses
        // to open inline chat when statusbar_reserve is null
        // (round 5 fix); these tests focus on the toggle/paint path,
        // not the no-statusbar guard.
        .statusbar_base_reserve = 3,
        .statusbar_reserve = 3,
        .terminal_rows = 24,
        .terminal_cols = 80,
    };

    // Closed by default — no reserve request, getter reports false.
    try testing.expectEqual(@as(u16, 0), L.extraReserveRows(&rt));
    try testing.expect(!L.isInlineChatActive(&rt));

    // Toggle open — reserve grows by `cfg.inline_chat_rows`, the
    // inline-active getter flips, and the paint latch is armed.
    const consumed = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(consumed);
    try testing.expect(rt.chat_inline_open);
    try testing.expect(rt.chat_inline_paint_pending);
    try testing.expect(L.isInlineChatActive(&rt));
    try testing.expect(L.extraReserveRows(&rt) >= 3);

    // Simulate the proxy growing the reservation in response: the
    // real proxy bumps `ctx.statusbar_reserve` to base + extra on
    // the next iteration top. Without this, paintInlineChat would
    // bail because `live_reserve == base_reserve` (no panel room).
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);

    // Paint must render the divider chrome + input prompt glyph.
    // (Cannot pin the exact CUP rows because tty size isn't
    // queryable in the test environment — paintInlineChat falls
    // back to 24×80 so the input row lands somewhere in 1..24.)
    const opened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(opened != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "atty chat") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "\u{276F}") != null); // input ❯
    try testing.expect(std.mem.indexOf(u8, opened.?, "Alt+C") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "Enter") != null);
    // Save-cursor on open so close can restore.
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[s") != null);
    // Invariant: open paint ends with explicit CUP to the shell
    // row, so the real terminal cursor doesn't stay parked at the
    // panel input row. Snapshot is 0 here (is_tty=false), so the
    // helper falls back to shell_bottom = 24 - 3 = 21.
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[21;1H") != null);

    // Toggle closed — reserve request returns to zero, paint emits
    // the saved-cursor restore + leaves clearing to the proxy.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(!rt.chat_inline_open);
    try testing.expectEqual(@as(u16, 0), L.extraReserveRows(&rt));
    const closed = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(closed != null);
    // Close emits cursor-show + explicit CUP to the shell-bottom
    // row (rather than DECRC, which the proxy's applyReserveRows
    // would have clobbered with its own DECSC/DECRC pair).
    // Pin the EXACT row — terminal_rows=24, base_reserve=3 →
    // shell_bottom = 21. Catches a regression that emits CUP to a
    // wrong row (e.g. the old `\x1B[1;1H` home-position drift).
    try testing.expect(std.mem.indexOf(u8, closed.?, "\x1B[?25h") != null);
    try testing.expect(std.mem.indexOf(u8, closed.?, "\x1B[21;1H") != null);
}

test "inline chat (Alt+C): open paint CUP-restores to the cursor_row snapshot taken at toggle time" {
    // Invariant: toggle-open snapshots `ctx.cursor_row` into the
    // Runtime; every subsequent paint ends with CUP back to that
    // row so the real terminal cursor sits on the shell prompt
    // (not the panel input row) when paint returns.
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

    var line: @import("../line_state.zig").LineState = .{};
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
        // Shell prompt is currently at row 8 (e.g. plenty of output
        // above). The open-paint must CUP back here, NOT shell_bottom.
        .cursor_row = 8,
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expect(rt.chat_inline_open);
    try testing.expectEqual(@as(u16, 8), rt.chat_open_cursor_row);

    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const opened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(opened != null);
    // Paint must end with CUP to row 8 (the snapshot), NOT row 21
    // (the fallback shell_bottom).
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[8;1H") != null);

    // Close also routes through the same helper — CUP to row 8.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    const closed = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(closed != null);
    try testing.expect(std.mem.indexOf(u8, closed.?, "\x1B[8;1H") != null);
}

test "inline chat: cursor_row snapshot clamps to shell_bottom when it overshoots the shell area" {
    // Invariant: a snapshot that lands inside the reserved
    // statusbar/panel zone (cursor_tracker drift, SIGWINCH races)
    // must clamp to shell_bottom — never CUP into the reservation.
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

    var line: @import("../line_state.zig").LineState = .{};
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
        // Bogus row (in the reservation): helper must clamp to 21.
        .cursor_row = 23,
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const opened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(opened != null);
    // CUP to row 21 (shell_bottom), NOT row 23 (the bogus snapshot).
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[21;1H") != null);
    try testing.expect(std.mem.indexOf(u8, opened.?, "\x1B[23;1H") == null);
}

test "inline chat: re-open with null ctx.cursor_row clears the previous snapshot via the open branch" {
    // Invariant: the open branch unconditionally writes
    // `ctx.cursor_row orelse 0` into the snapshot. A re-open with
    // `cursor_row = null` (e.g. cursor_tracker not wired this tick)
    // must NOT reuse the previous open's row — it falls back to
    // shell_bottom via the helper's 0-sentinel branch.
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

    var line: @import("../line_state.zig").LineState = .{};
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
    };

    // First open captures row 8.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 8), rt.chat_open_cursor_row);
    // Close leaves the snapshot intact — the close paint still
    // needs it to know where to restore.
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 8), rt.chat_open_cursor_row);

    // Re-open with no cursor_row available — open branch writes 0.
    ctx.cursor_row = null;
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 0), rt.chat_open_cursor_row);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const reopened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(reopened != null);
    // CUP to row 21 (shell_bottom fallback), NOT row 8 (stale).
    try testing.expect(std.mem.indexOf(u8, reopened.?, "\x1B[21;1H") != null);
    try testing.expect(std.mem.indexOf(u8, reopened.?, "\x1B[8;1H") == null);
}

test "inline chat: re-open with a different non-null cursor_row overwrites the previous snapshot" {
    // Symmetric to the null-cursor_row test: the open branch
    // unconditionally writes `ctx.cursor_row orelse 0`, so a fresh
    // value MUST overwrite the previous open's snapshot — paint
    // CUPs to the new row, not the old one.
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

    var line: @import("../line_state.zig").LineState = .{};
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
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 8), rt.chat_open_cursor_row);
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);

    // Re-open at a different row. New snapshot must replace the
    // previous one and the paint must use it.
    ctx.cursor_row = 12;
    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 12), rt.chat_open_cursor_row);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);
    const reopened = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(reopened != null);
    try testing.expect(std.mem.indexOf(u8, reopened.?, "\x1B[12;1H") != null);
    try testing.expect(std.mem.indexOf(u8, reopened.?, "\x1B[8;1H") == null);
}

test "inline chat: paint ignores live ctx.cursor_row drift while panel is open" {
    // Regression guard: paint MUST anchor to the snapshot, not the
    // live `ctx.cursor_row`. The shell can still emit output that
    // updates cursor_tracker between paints; if a future refactor
    // swaps the snapshot for the live value, the panel would
    // chase the cursor around instead of restoring to the prompt.
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

    var line: @import("../line_state.zig").LineState = .{};
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
        .cursor_row = 10,
    };

    _ = try L.onAction(&rt, &ctx, .llm_inline_chat_toggle);
    try testing.expectEqual(@as(u16, 10), rt.chat_open_cursor_row);
    ctx.statusbar_reserve = 3 + L.extraReserveRows(&rt);

    const first = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(first != null);
    // The restore CUP is the LAST bytes the paint emits.
    try testing.expect(std.mem.endsWith(u8, first.?, "\x1B[10;1H"));

    // Live cursor drifts (shell printed output between ticks).
    // Snapshot must NOT update — the closing restore CUP must
    // still target row 10, never row 5 / row 18 / etc.
    ctx.cursor_row = 5;
    rt.chat_inline_paint_pending = true;
    const second = try L.provideTermBytes(&rt, &ctx);
    try testing.expect(second != null);
    try testing.expect(std.mem.endsWith(u8, second.?, "\x1B[10;1H"));
    try testing.expectEqual(@as(u16, 10), rt.chat_open_cursor_row);
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

    var line: @import("../line_state.zig").LineState = .{};
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

    var line: @import("../line_state.zig").LineState = .{};
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

    var line: @import("../line_state.zig").LineState = .{};
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

    var line: @import("../line_state.zig").LineState = .{};
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

    var line: @import("../line_state.zig").LineState = .{};
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

    var line: @import("../line_state.zig").LineState = .{};
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

test "provideTermBytes emits OSC 12 on prefix-match edge, OSC 112 on un-match" {
    const L = configure(.{
        .api_base = "http://test/v1",
        .api_base_env = "ATTY_TEST_NEVER",
        .api_base_fallback_env = "ATTY_TEST_NEVER",
        .api_key_env = "ATTY_TEST_NEVER",
        .prefix_signal_cursor_color = "cyan",
    });

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();

    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);

    var line: @import("../line_state.zig").LineState = .{};
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

test "statusText: idle hint shows Alt+C/Alt+S/Alt+H when no AI mode (discoverability)" {
    const L = configure(.{
        .api_base = "http://test/v1",
        .api_base_env = "ATTY_TEST_NEVER",
        .api_base_fallback_env = "ATTY_TEST_NEVER",
        .api_key_env = "ATTY_TEST_NEVER",
        // Default `.show_idle_keys_hint = true` so a fresh shell
        // surfaces the LLM bindings without the user having to
        // type `#: ` first to discover them exist.
    });

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();
    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);

    var line: @import("../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = real_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    // Empty line, no AI mode, no dialog, no in-flight — should
    // surface the compact discoverability hint instead of null.
    const got = try L.statusText(&rt, &ctx);
    try testing.expect(got != null);
    try testing.expect(std.mem.indexOf(u8, got.?, "Alt+C") != null);
    try testing.expect(std.mem.indexOf(u8, got.?, "Alt+S") != null);
    try testing.expect(std.mem.indexOf(u8, got.?, "Alt+H") != null);
}

test "statusText flips to prefix_signal_status_text while prefix matches" {
    const L = configure(.{
        .api_base = "http://test/v1",
        .api_base_env = "ATTY_TEST_NEVER",
        .api_base_fallback_env = "ATTY_TEST_NEVER",
        .api_key_env = "ATTY_TEST_NEVER",
        .prefix_signal_status_text = "TEST_SIGNAL",
        // Disable the discoverability hint so the idle path still
        // returns null (the original contract this test pins).
        .show_idle_keys_hint = false,
    });

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();

    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);

    var line: @import("../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = real_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    // Empty line, not in flight → no segment.
    try testing.expectEqual(@as(?[]const u8, null), try L.statusText(&rt, &ctx));

    // Prefix typed → custom segment text appears.
    _ = line.applyInput("#: list files");
    const got = try L.statusText(&rt, &ctx);
    try testing.expect(got != null);
    try testing.expectEqualStrings("TEST_SIGNAL", got.?);

    // In-flight takes precedence over prefix-match (thinking…
    // spinner wins for status real estate).
    rt.in_flight = true;
    const got2 = try L.statusText(&rt, &ctx);
    try testing.expect(got2 != null);
    try testing.expect(std.mem.indexOf(u8, got2.?, "thinking") != null);
}

test "statusText: AI hint embeds SGR escapes for icon + shortcuts (default colors)" {
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

    var line: @import("../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = real_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    _ = line.applyInput("#: anything");
    rt.ai_mode_active = true;
    const got = try L.statusText(&rt, &ctx);
    try testing.expect(got != null);
    const out = got.?;

    // Default config: icon color 141, shortcut color 14. Both
    // present means the wrap escapes survived the comptime concat
    // and reach the runtime untouched.
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[22;38;5;141m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[22;1;38;5;14m") != null);
    // Visible text is still intact end-to-end.
    try testing.expect(std.mem.indexOf(u8, out, "Alt+A") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Esc") != null);
}

test "statusText: null icon/shortcut colors produce no SGR escapes (legacy look)" {
    const L = configure(.{
        .api_base = "http://test/v1",
        .api_base_env = "ATTY_TEST_NEVER",
        .api_base_fallback_env = "ATTY_TEST_NEVER",
        .api_key_env = "ATTY_TEST_NEVER",
        .statusbar_icon_color = null,
        .statusbar_shortcut_color = null,
    });

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();
    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);

    var line: @import("../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = real_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    _ = line.applyInput("#: anything");
    rt.ai_mode_active = true;
    const got = try L.statusText(&rt, &ctx);
    try testing.expect(got != null);
    const out = got.?;

    // No 256-color SGR codes when both knobs are null — the hint
    // inherits the bar's outer dim styling.
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[38;5;") == null);
    // Visible text still present.
    try testing.expect(std.mem.indexOf(u8, out, "Alt+A") != null);
}

test "resolveApiBase trims a single trailing slash on cfg.api_base" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();

    const L = configure(.{
        .api_base = "http://static:9999/v1/",
        .api_base_env = "ATTY_TEST_BASE_NEVER",
        .api_base_fallback_env = "ATTY_TEST_BASE_NEVER",
        .api_key_env = "ATTY_TEST_BASE_NEVER",
    });
    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);

    try testing.expectEqualStrings("http://static:9999/v1", rt.api_base);
}

// ===========================================================================
// HTTP mock — drive the worker against a localhost server and assert that
// it round-trips a canned ollama-shape response into the latched command +
// hint surfaces. This is the only test that exercises `doRequest`,
// `client.fetch`, the worker thread, and the latch path. Pure helpers test
// the parsers; this catches integration drift (e.g. std API breaks).
// ===========================================================================

const libc = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
    extern "c" fn bind(sockfd: c_int, addr: *const anyopaque, addrlen: u32) c_int;
    extern "c" fn listen(sockfd: c_int, backlog: c_int) c_int;
    extern "c" fn accept(sockfd: c_int, addr: ?*anyopaque, addrlen: ?*u32) c_int;
    extern "c" fn getsockname(sockfd: c_int, addr: *anyopaque, addrlen: *u32) c_int;
    extern "c" fn setsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: u32) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn read_(fd: c_int, buf: [*]u8, count: usize) isize;
    extern "c" fn write_(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern "c" fn usleep(usec: c_uint) c_int;

    // Linux values (this codebase pins x86_64-linux-{gnu,musl}).
    const AF_INET: c_int = 2;
    const SOCK_STREAM: c_int = 1;
    const IPPROTO_TCP: c_int = 6;
    const SOL_SOCKET: c_int = 1;
    const SO_REUSEADDR: c_int = 2;

    const sockaddr_in = extern struct {
        family: u16,
        port: u16, // network byte order
        addr: u32, // network byte order
        zero: [8]u8 = .{0} ** 8,
    };
};

// Aliases so we can use the conventional names without shadowing
// Zig's `read` / `write` builtins inside the mock handler.
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

const MockServerCtx = struct {
    listen_fd: c_int,
    response_body: []const u8,
};

fn mockServerHandler(ctx: *MockServerCtx) void {
    const conn_fd = libc.accept(ctx.listen_fd, null, null);
    if (conn_fd < 0) return;
    defer _ = libc.close(conn_fd);

    // Drain the request — read until we see `\r\n\r\n` (end of headers).
    // The body follows but we don't parse it; we only need to consume
    // enough bytes that the client's send() unblocks.
    var read_buf: [4096]u8 = undefined;
    var total: usize = 0;
    var iters: usize = 0;
    while (iters < 32) : (iters += 1) {
        const n = read(conn_fd, read_buf[total..].ptr, read_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
        if (std.mem.indexOf(u8, read_buf[0..total], "\r\n\r\n") != null) break;
        if (total >= read_buf.len) break;
    }

    var resp_buf: [4096]u8 = undefined;
    const resp = std.fmt.bufPrint(
        &resp_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ ctx.response_body.len, ctx.response_body },
    ) catch return;
    _ = write(conn_fd, resp.ptr, resp.len);
}

test "LLM worker round-trips a mock ollama response into the latch + hint surfaces" {
    // Threaded io is needed so `client.fetch` (used by `doRequest`) has
    // real I/O. The default test_io = std.Io.failing would panic on the
    // first syscall.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();

    // Bind on 127.0.0.1, OS-picked port via raw libc syscalls —
    // std.Io.net's Server in 0.16 has no portable accessor for the
    // assigned port, and std.posix dropped socket/bind/listen/accept
    // into Io.net's vtable. Linux constants are inline-pinned;
    // this codebase only targets x86_64-linux-{gnu,musl}.
    const listen_fd = libc.socket(libc.AF_INET, libc.SOCK_STREAM, libc.IPPROTO_TCP);
    if (listen_fd < 0) return error.SocketFailed;
    defer _ = libc.close(listen_fd);

    const one: c_int = 1;
    _ = libc.setsockopt(listen_fd, libc.SOL_SOCKET, libc.SO_REUSEADDR, &one, @sizeOf(c_int));

    var sa_in: libc.sockaddr_in = .{
        .family = libc.AF_INET,
        .port = 0, // OS picks
        .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
    };
    if (libc.bind(listen_fd, &sa_in, @sizeOf(libc.sockaddr_in)) < 0) return error.BindFailed;
    if (libc.listen(listen_fd, 1) < 0) return error.ListenFailed;

    // Read the assigned port back out via getsockname.
    var bound_addr: libc.sockaddr_in = undefined;
    var bound_len: u32 = @sizeOf(libc.sockaddr_in);
    if (libc.getsockname(listen_fd, &bound_addr, &bound_len) < 0) return error.GetSockNameFailed;
    const port = std.mem.bigToNative(u16, bound_addr.port);

    // Canned ollama-shape response. The content field is a JSON string
    // containing the explanation, a newline, a fenced block with the
    // command, and the closing fence. extractResponse will split on the
    // fence into (explanation, command).
    const body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Greets you.\\n```\\necho hi\\n```\"}}]}";

    var mock_ctx: MockServerCtx = .{ .listen_fd = listen_fd, .response_body = body };
    const mock_thread = try std.Thread.spawn(.{}, mockServerHandler, .{&mock_ctx});
    defer mock_thread.join();

    // Set the test env var to our mock URL. The module reads env vars
    // at attach time only, so the test process's env mutation is
    // observed by the worker exactly once.
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buf, "http://127.0.0.1:{d}/v1", .{port});
    _ = libc.setenv("ATTY_TEST_LLM_API_BASE", url.ptr, 1);
    defer _ = libc.unsetenv("ATTY_TEST_LLM_API_BASE");

    const L = configure(.{
        .api_base_env = "ATTY_TEST_LLM_API_BASE",
        // Use a name that's never set so the fallback doesn't fire and
        // accidentally produce a non-empty api_base from $OLLAMA_HOST.
        .api_base_fallback_env = "ATTY_TEST_LLM_NEVER",
        .api_key_env = "ATTY_TEST_LLM_NEVER",
        .model = "test-model",
        // This test exercises the legacy `#:<Enter>` trigger path —
        // opt back into it via `enter_action = .single` (default is
        // `.none` since Alt+A is now the explicit binding).
        .enter_action = .single,
    });

    var rt = try L.attach(testing.allocator, real_io);
    // Don't call L.detach — it does t.detach() which leaks the heap
    // allocations (intentional, see round-5 fix). For the test we do a
    // sync join so the testing allocator's leak detector stays happy.
    defer shutdownAndFree(L, &rt, real_io);

    // Prime line_state with `#: hello` followed by Enter — onInput
    // expects lastCommitted to hold the prefixed line.
    var line: @import("../line_state.zig").LineState = .{};
    _ = line.applyInput("#: hello\r");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);

    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = real_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    const act = try L.onInput(&rt, &ctx, "\r");
    try testing.expect(act == .replace_commit);
    try testing.expectEqualStrings("\x15", act.replace_commit);

    // Poll the latch until the worker delivers. Generous 2s budget for
    // CI variance — the mock responds immediately so locally this is
    // ~50ms.
    var deadline_iters: usize = 100;
    while (deadline_iters > 0) : (deadline_iters -= 1) {
        if (try L.pollShellInput(&rt, &ctx)) |bytes| {
            try testing.expectEqualStrings("echo hi", bytes);
            const hint = try L.provideHintText(&rt, &ctx);
            try testing.expect(hint != null);
            try testing.expectEqualStrings("Greets you.", hint.?);
            return;
        }
        _ = libc.usleep(20_000); // 20ms
    }
    return error.WorkerTimedOut;
}

test "inert mode (no endpoint env) surfaces a 'no endpoint' hint" {
    // Both env vars unset → api_base resolves to "" → module
    // attaches inert (no worker thread). onInput should still
    // latch a hint so the user sees *why* `#: …` produced no
    // command rather than thinking the feature is broken.
    _ = libc.unsetenv("ATTY_TEST_INERT_BASE");
    _ = libc.unsetenv("ATTY_TEST_INERT_FALLBACK");

    const L = configure(.{
        .api_base_env = "ATTY_TEST_INERT_BASE",
        .api_base_fallback_env = "ATTY_TEST_INERT_FALLBACK",
        .api_key_env = "ATTY_TEST_INERT_KEY_NEVER",
        // Inert-mode assertions rely on the Enter trigger reaching
        // `triggerSinglePrompt` (which latches the "no endpoint"
        // error). The default `.none` skips that path, so this
        // test opts into `.single` explicitly.
        .enter_action = .single,
    });

    var rt = try L.attach(testing.allocator, test_io);
    defer {
        // Inert mode: no worker spawned, detach can run cleanly.
        L.detach(&rt, test_io);
    }

    try testing.expectEqual(@as(usize, 0), rt.api_base.len);
    try testing.expect(rt.thread == null);

    var line: @import("../line_state.zig").LineState = .{};
    _ = line.applyInput("#: hello\r");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);

    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = test_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    const act = try L.onInput(&rt, &ctx, "\r");
    // .forward — the typed `#: …` reaches the shell as a comment;
    // no point killing the line when we never queried the LLM.
    try testing.expect(act == .forward);

    // The notification must mention the missing env var so the
    // user knows what to fix. Surfaced via the *error* channel
    // (muted red + ⚠ in the statusbar) — provideHintText returns
    // null because hint and error are distinct slots now.
    try testing.expectEqual(@as(?[]const u8, null), try L.provideHintText(&rt, &ctx));
    const err = try L.provideErrorText(&rt, &ctx);
    try testing.expect(err != null);
    try testing.expect(std.mem.indexOf(u8, err.?, "no endpoint") != null);
    // Message must mention the configured env-var names, not the
    // upstream defaults — pin that the comptime-built string respects
    // `Config.api_base_env` / `Config.api_base_fallback_env`.
    try testing.expect(std.mem.indexOf(u8, err.?, "ATTY_TEST_INERT_BASE") != null);
    try testing.expect(std.mem.indexOf(u8, err.?, "ATTY_TEST_INERT_FALLBACK") != null);
    try testing.expect(std.mem.indexOf(u8, err.?, "Config.api_base") != null);

    // One-shot — second call returns null.
    try testing.expectEqual(@as(?[]const u8, null), try L.provideErrorText(&rt, &ctx));
}

fn mockServer500Handler(ctx: *MockServerCtx) void {
    const conn_fd = libc.accept(ctx.listen_fd, null, null);
    if (conn_fd < 0) return;
    defer _ = libc.close(conn_fd);

    var read_buf: [4096]u8 = undefined;
    var total: usize = 0;
    var iters: usize = 0;
    while (iters < 32) : (iters += 1) {
        const n = read(conn_fd, read_buf[total..].ptr, read_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
        if (std.mem.indexOf(u8, read_buf[0..total], "\r\n\r\n") != null) break;
        if (total >= read_buf.len) break;
    }

    const resp = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    _ = write(conn_fd, resp.ptr, resp.len);
}

test "HTTP 5xx surfaces a 'HTTP <status>' hint, no command injected" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const real_io = threaded.io();

    const listen_fd = libc.socket(libc.AF_INET, libc.SOCK_STREAM, libc.IPPROTO_TCP);
    if (listen_fd < 0) return error.SocketFailed;
    defer _ = libc.close(listen_fd);
    const one: c_int = 1;
    _ = libc.setsockopt(listen_fd, libc.SOL_SOCKET, libc.SO_REUSEADDR, &one, @sizeOf(c_int));
    var sa_in: libc.sockaddr_in = .{
        .family = libc.AF_INET,
        .port = 0,
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    if (libc.bind(listen_fd, &sa_in, @sizeOf(libc.sockaddr_in)) < 0) return error.BindFailed;
    if (libc.listen(listen_fd, 1) < 0) return error.ListenFailed;
    var bound_addr: libc.sockaddr_in = undefined;
    var bound_len: u32 = @sizeOf(libc.sockaddr_in);
    if (libc.getsockname(listen_fd, &bound_addr, &bound_len) < 0) return error.GetSockNameFailed;
    const port = std.mem.bigToNative(u16, bound_addr.port);

    var mock_ctx: MockServerCtx = .{ .listen_fd = listen_fd, .response_body = "" };
    const mock_thread = try std.Thread.spawn(.{}, mockServer500Handler, .{&mock_ctx});
    defer mock_thread.join();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buf, "http://127.0.0.1:{d}/v1", .{port});
    _ = libc.setenv("ATTY_TEST_LLM_500_BASE", url.ptr, 1);
    defer _ = libc.unsetenv("ATTY_TEST_LLM_500_BASE");

    const L = configure(.{
        .api_base_env = "ATTY_TEST_LLM_500_BASE",
        .api_base_fallback_env = "ATTY_TEST_LLM_500_NEVER",
        .api_key_env = "ATTY_TEST_LLM_500_NEVER",
        .model = "test-model",
        // Opt into the legacy `#:<Enter>` path — this test types
        // Enter to fire the request against the 500 mock.
        .enter_action = .single,
    });

    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);

    var line: @import("../line_state.zig").LineState = .{};
    _ = line.applyInput("#: hello\r");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);

    var ctx: m.Context = .{
        .allocator = testing.allocator,
        .io = real_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    const act = try L.onInput(&rt, &ctx, "\r");
    try testing.expect(act == .replace_commit);

    var deadline_iters: usize = 100;
    while (deadline_iters > 0) : (deadline_iters -= 1) {
        // Worker has fired; if it completed, pollShellInput returns
        // null (no command on failure) but leaves a hint pending.
        const inject = try L.pollShellInput(&rt, &ctx);
        if (inject == null) {
            // pollShellInput only consumes when res_done was set.
            // If it returned null without consuming (still
            // in-flight), keep polling.
            if (rt.in_flight) {
                _ = libc.usleep(20_000);
                continue;
            }
            // Worker has signalled completion + we just consumed it.
            // The error should now be pending with the HTTP code.
            // provideHintText returns null — only the error channel
            // is populated on failure paths.
            try testing.expectEqual(@as(?[]const u8, null), try L.provideHintText(&rt, &ctx));
            const err = try L.provideErrorText(&rt, &ctx);
            try testing.expect(err != null);
            try testing.expect(std.mem.indexOf(u8, err.?, "HTTP 500") != null);
            return;
        }
        // Unexpectedly got bytes — the mock returns 500, so the
        // worker should not have produced anything to inject.
        return error.UnexpectedInjection;
    }
    return error.WorkerTimedOut;
}
