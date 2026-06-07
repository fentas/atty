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

const libc = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

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
