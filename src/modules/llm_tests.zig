//! Tests for `modules/llm.zig`. Lifted out so the implementation
//! file stays readable — the inline-tests pattern was costing ~1700
//! lines and made the configure() body hard to scan.
//!
//! Naming follows the project-wide convention: source-file siblings
//! live as `<name>_tests.zig` in the SAME directory.

const std = @import("std");
const testing = std.testing;

const mod = @import("llm.zig");
const configure = mod.configure;
const m = @import("../module.zig");
const dialog = mod.dialog_ns;
const parse = @import("llm/parse.zig");
const shutdownAndFree = @import("llm/test_helpers.zig").shutdownAndFree;

const test_io: std.Io = std.Io.failing;

// Pull in sibling parse-tests so test discovery cascades.
test {
    _ = parse;
}

// Cascade discovery into the sibling test files that live next
// to paint.zig and hooks.zig — keeps unit_tests.zig from
// having to enumerate every individual test sibling.
test {
    _ = @import("llm/paint_tests.zig");
    _ = @import("llm/paint_width.zig");
    _ = @import("llm/hooks_tests.zig");
}

test "configure exposes the expected hooks" {
    const L = configure(.{});
    try testing.expect(@hasDecl(L, "onInput"));
    try testing.expect(@hasDecl(L, "pollShellInput"));
    try testing.expect(@hasDecl(L, "statusText"));
    try testing.expectEqualStrings("llm", L.name);
}

test "buildRequestBody produces well-formed OpenAI chat-completion JSON" {
    const L = configure(.{ .provider = .{ .http = .{ .model = "test-model" } } });
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

test "extractCommand decodes \\uXXXX unicode escapes (regression: previously skipped)" {
    const L = configure(.{});
    var out: [128]u8 = undefined;
    // Valid   decodes to a space → "ls -la".
    const sample_space = "{\"choices\":[{\"message\":{\"content\":\"ls\\u0020-la\"}}]}";
    try testing.expectEqualStrings("ls -la", out[0..L.extractCommand(sample_space, &out)]);
    // The real-world regression: > is `>`. Without decoding,
    // `2>/dev/null` arrives as `2/dev/null` and the user wonders
    // where the redirect went.
    const sample_redirect = "{\"choices\":[{\"message\":{\"content\":\"echo a 2\\u003e/dev/null\"}}]}";
    try testing.expectEqualStrings("echo a 2>/dev/null", out[0..L.extractCommand(sample_redirect, &out)]);
    // Same for & = `&`.
    const sample_amp = "{\"choices\":[{\"message\":{\"content\":\"echo a \\u0026\\u0026 echo b\"}}]}";
    try testing.expectEqualStrings("echo a && echo b", out[0..L.extractCommand(sample_amp, &out)]);
    // Multi-byte UTF-8: → is `→` (RIGHTWARDS ARROW, 3-byte
    // UTF-8 sequence). Should encode correctly.
    const sample_arrow = "{\"choices\":[{\"message\":{\"content\":\"echo \\u2192\"}}]}";
    try testing.expectEqualStrings("echo \u{2192}", out[0..L.extractCommand(sample_arrow, &out)]);
    // Malformed \u with only 2 hex digits before the closing quote
    // must not run past the boundary. The decoder bails on the `"`
    // and the loop terminates at it.
    const sample_malformed = "{\"choices\":[{\"message\":{\"content\":\"ls\\u01\"}}]}";
    try testing.expectEqualStrings("ls", out[0..L.extractCommand(sample_malformed, &out)]);
    // \r (carriage return) MUST drop — writing CR to the PTY
    // would act as Enter and auto-execute the partial command.
    const sample_cr = "{\"choices\":[{\"message\":{\"content\":\"echo a\\u000Decho b\"}}]}";
    try testing.expectEqualStrings("echo aecho b", out[0..L.extractCommand(sample_cr, &out)]);
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

test "effective_system_prompt defaults to atty's fenced-action protocol" {
    const L = configure(.{});
    // atty's protocol mentions the ```exec fenced action — the
    // contract the parser depends on.
    try testing.expect(std.mem.indexOf(u8, L.effective_system_prompt, "```exec") != null);
    // The "raw — no escaping" rule appears — defining the key
    // difference from the legacy JSON-envelope protocol.
    try testing.expect(std.mem.indexOf(u8, L.effective_system_prompt, "raw") != null);
}

test "effective_system_prompt prepends atty's protocol; user override appends" {
    const L = configure(.{ .system_prompt = "Prefer ripgrep over grep when available." });
    // atty's fenced-action contract stays at the head — the parser
    // can't function without it.
    try testing.expect(std.mem.indexOf(u8, L.effective_system_prompt, "```exec") != null);
    // User's additional domain context appears in full at the tail.
    try testing.expect(std.mem.endsWith(u8, L.effective_system_prompt, "Prefer ripgrep over grep when available."));
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
        .provider = .{ .http = .{
            .api_base = "http://static-config:9999/v1",
            .api_base_env = "ATTY_TEST_BASE_PRIMARY",
            .api_base_fallback_env = "ATTY_TEST_BASE_FALLBACK",
            .api_key_env = "ATTY_TEST_BASE_NEVER",
        } },
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
        .provider = .{ .http = .{
            .api_base_env = "ATTY_TEST_BASE_PRIMARY2",
            .api_base_fallback_env = "ATTY_TEST_BASE_NEVER",
            .api_key_env = "ATTY_TEST_BASE_NEVER",
        } },
    });
    var rt = try L.attach(testing.allocator, real_io);
    defer shutdownAndFree(L, &rt, real_io);

    try testing.expectEqualStrings("http://from-env:1234/v1", rt.api_base);
}

test "statusText: idle hint shows Alt+C/Alt+S/Alt+H when no AI mode (discoverability)" {
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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

test "statusText: DIALOG mode hint covers state-engaged-but-mode-already-reset window" {
    // Regression guard: when `dialog_persistent_mode` resets to .off
    // (LLM said action=done) but the dialog state machine is still
    // cycling (observation_ready, etc.), the statusbar previously
    // fell through to the discovery hint — making the user think
    // they were idle when they were actually waiting for the next
    // turn. Surface DIALOG mode for any non-.idle state too.
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

    // Mode reset (LLM done), but state machine still mid-cycle.
    rt.dialog_persistent_mode = .off;
    rt.dialog_state = .observation_ready;
    rt.in_flight = false;

    const got = try L.statusText(&rt, &ctx);
    try testing.expect(got != null);
    // Should see "DIALOG", NOT the discovery "Alt+C chat" segment.
    try testing.expect(std.mem.indexOf(u8, got.?, "DIALOG") != null);
}

test "statusText: single-shot in_flight returns thinking_hint, not DIALOG" {
    // Alt+A single-shot path: no persistent mode, dialog_state
    // stays .idle, just `in_flight = true` while the worker runs.
    // Must show the transient brain glyph — claiming "DIALOG mode"
    // when the user didn't enter a dialog would be misleading.
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

    rt.dialog_persistent_mode = .off;
    rt.dialog_state = .idle;
    rt.in_flight = true; // single-shot Alt+A worker mid-flight

    const got = try L.statusText(&rt, &ctx);
    try testing.expect(got != null);
    // Brain glyph U+1F9E0 — encoded as the UTF-8 sequence \xF0\x9F\xA7\xA0.
    try testing.expect(std.mem.indexOf(u8, got.?, "\u{1F9E0}") != null);
    try testing.expect(std.mem.indexOf(u8, got.?, "thinking") != null);
    // Must NOT show DIALOG or AUTO labels.
    try testing.expect(std.mem.indexOf(u8, got.?, "DIALOG") == null);
    try testing.expect(std.mem.indexOf(u8, got.?, "AUTO") == null);
}

test "statusText: mode=.dialog keeps DIALOG label even if auto_mode_active leaks" {
    // Defense-in-depth: if the auto_mode_active flag is set while
    // dialog_persistent_mode is still .dialog (a known leak path
    // through cfg.enter_action=.auto + .llm_exec_dialog), the
    // statusbar should still render DIALOG — the persistent mode
    // is the source of truth.
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

    rt.dialog_persistent_mode = .dialog;
    rt.auto_mode_active = true; // leaky combo
    rt.in_flight = false;

    const got = try L.statusText(&rt, &ctx);
    try testing.expect(got != null);
    try testing.expect(std.mem.indexOf(u8, got.?, "DIALOG") != null);
    try testing.expect(std.mem.indexOf(u8, got.?, "AUTO") == null);
}

test "statusText: AUTO mode hint covers state-engaged-with-auto-flag window" {
    // Same as the dialog regression, but for auto-exec mode where
    // `auto_mode_active` is the engaged flag.
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

    // mode=.off + state engaged + auto flag — the state machine
    // is mid-flow with auto-exec active even though the persistent
    // mode reset (LLM action=done). Auto label is correct.
    rt.dialog_persistent_mode = .off;
    rt.dialog_state = .observation_ready;
    rt.auto_mode_active = true;
    rt.in_flight = false;

    const got = try L.statusText(&rt, &ctx);
    try testing.expect(got != null);
    try testing.expect(std.mem.indexOf(u8, got.?, "AUTO") != null);
    try testing.expect(std.mem.indexOf(u8, got.?, "DIALOG") == null);
}

test "statusText flips to prefix_signal_status_text while prefix matches" {
    const L = configure(.{
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
        .provider = .{ .http = .{
            .api_base = "http://test/v1",
            .api_base_env = "ATTY_TEST_NEVER",
            .api_base_fallback_env = "ATTY_TEST_NEVER",
            .api_key_env = "ATTY_TEST_NEVER",
        } },
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
        .provider = .{ .http = .{
            .api_base = "http://static:9999/v1/",
            .api_base_env = "ATTY_TEST_BASE_NEVER",
            .api_base_fallback_env = "ATTY_TEST_BASE_NEVER",
            .api_key_env = "ATTY_TEST_BASE_NEVER",
        } },
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
        // Use a fallback name that's never set so the fallback doesn't
        // fire and accidentally produce a non-empty api_base from
        // $OLLAMA_HOST.
        .provider = .{ .http = .{
            .api_base_env = "ATTY_TEST_LLM_API_BASE",
            .api_base_fallback_env = "ATTY_TEST_LLM_NEVER",
            .api_key_env = "ATTY_TEST_LLM_NEVER",
            .model = "test-model",
        } },
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
        .provider = .{ .http = .{
            .api_base_env = "ATTY_TEST_INERT_BASE",
            .api_base_fallback_env = "ATTY_TEST_INERT_FALLBACK",
            .api_key_env = "ATTY_TEST_INERT_KEY_NEVER",
        } },
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
    // `Config.provider.http.api_base_env` / `api_base_fallback_env`.
    try testing.expect(std.mem.indexOf(u8, err.?, "ATTY_TEST_INERT_BASE") != null);
    try testing.expect(std.mem.indexOf(u8, err.?, "ATTY_TEST_INERT_FALLBACK") != null);
    try testing.expect(std.mem.indexOf(u8, err.?, "Config.provider.http.api_base") != null);

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
        .provider = .{ .http = .{
            .api_base_env = "ATTY_TEST_LLM_500_BASE",
            .api_base_fallback_env = "ATTY_TEST_LLM_500_NEVER",
            .api_key_env = "ATTY_TEST_LLM_500_NEVER",
            .model = "test-model",
        } },
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

/// Hung handler — accepts the connection but never reads / writes.
/// The fetch on the other side blocks forever, exercising the
/// `runHttpFetchWithDeadline` deadline path. The connection fd
/// holds open until the test exits.
fn mockServerHungHandler(ctx: *MockServerCtx) void {
    const conn_fd = libc.accept(ctx.listen_fd, null, null);
    if (conn_fd < 0) return;
    defer _ = libc.close(conn_fd);
    // Hold the connection without responding. POSIX `usleep`
    // rejects values >= 1_000_000 with EINVAL (musl is strict
    // about this; glibc is more permissive). Loop in 500 ms
    // slices so the handler doesn't busy-spin if usleep returns
    // early. The test exits well before any reasonable upper
    // bound, breaking the loop via process teardown.
    while (true) {
        _ = libc.usleep(500_000);
    }
}

test "runHttpFetchWithDeadline timeout_ms=0 runs inline + returns ok" {
    // Pins the no-deadline fast-path: `timeout_ms == 0` should
    // skip the thread spawn and run the fetch inline on the
    // worker thread, then consume the task normally. A regression
    // here (e.g. inline path failing to publish the outcome or
    // returning a wrong FetchKind) would otherwise ship silent
    // because all existing HTTP tests go through the deadlined
    // path.
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

    const body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hello\"}}]}";
    var mock_ctx: MockServerCtx = .{ .listen_fd = listen_fd, .response_body = body };
    const mock_thread = try std.Thread.spawn(.{}, mockServerHandler, .{&mock_ctx});
    defer mock_thread.join();

    const worker = @import("llm/worker.zig");
    const M = worker.Module(.{ .provider = .{ .http = .{} } });

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1", .{port});

    const outcome = M.runHttpFetchWithDeadline(
        testing.allocator,
        real_io,
        url,
        "{\"x\":1}",
        null,
        4096,
        0, // no-deadline — inline path
    );
    // testing.allocator is fine here: the inline path always
    // owns + frees its task before returning, so no orphan
    // can outlive the test.
    try testing.expectEqual(M.FetchKind.ok, outcome.kind);
    try testing.expect(outcome.response_buf != null);
    defer testing.allocator.free(outcome.response_buf.?);
    try testing.expectEqual(@as(u16, 200), outcome.status);
    try testing.expect(outcome.response_len > 0);
}

test "HTTP request against a hung endpoint times out within the configured deadline" {
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
    const mock_thread = try std.Thread.spawn(.{}, mockServerHungHandler, .{&mock_ctx});
    defer mock_thread.detach(); // never joins — the handler sleeps forever.

    // Drive `runHttpFetchWithDeadline` directly with a short
    // deadline. Going through the full Module/attach path would
    // mean the worker thread itself blocks until the deadline,
    // which is also a valid test but adds 20× the harness.
    const worker = @import("llm/worker.zig");
    const M = worker.Module(.{
        .provider = .{ .http = .{} },
    });

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1", .{port});

    // Use page_allocator here, NOT testing.allocator: the
    // intentional behavior on timeout is to detach the fetch
    // sub-thread, which keeps owning the heap-allocated task.
    // testing.allocator's leak detector would otherwise fail
    // the test for exactly the behavior we're trying to pin.
    const alloc = std.heap.page_allocator;

    const start_ms = @import("_lib.zig").nowMs();
    const outcome = M.runHttpFetchWithDeadline(
        alloc,
        real_io,
        url,
        "{\"x\":1}",
        null,
        4096,
        300, // 300 ms deadline
    );
    const elapsed = @import("_lib.zig").nowMs() - start_ms;

    try testing.expectEqual(M.FetchKind.timed_out, outcome.kind);
    // Lower bound pins "the poll loop actually waited" — without
    // this a regression that returned .timed_out immediately
    // (e.g. broken deadline math) would still pass with just the
    // upper bound. Threshold = deadline minus one polling slice
    // so a tick-late return still passes.
    try testing.expect(elapsed >= 250);
    // The polling cadence is 50 ms; 300 ms deadline + one extra
    // tick = ≤ 400 ms theoretical max. Allow generous slack for
    // CI variance. Anything past 2 s means the deadline plumbing
    // is broken.
    try testing.expect(elapsed < 2000);
}
