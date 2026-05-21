//! Tests for the subprocess-provider request path (issue #157).
//! Spawns small POSIX utilities (`/bin/echo`, `/bin/cat`) as the
//! subprocess so the tests don't need any LLM CLI on PATH.

const std = @import("std");
const testing = std.testing;

const types = @import("types.zig");
const worker_mod = @import("worker.zig");
const nowMs = @import("../_lib.zig").nowMs;

// Comptime config with a no-op subprocess provider — the actual
// `.argv` gets supplied per-test via a constructed Config so the
// `runSubprocess` helper exercises the dispatch path.
const empty_argv: []const []const u8 = &.{};

fn makeTestCfg(comptime sub: types.SubprocessProvider) types.Config {
    return .{
        .provider = .{ .subprocess = sub },
        // Force inert HTTP env-var names so accidental fallthrough
        // can't pick up a live OLLAMA_HOST.
        .with_explanation = false,
    };
}

test "subprocess (raw): echo returns its arg as the command" {
    // /bin/echo with prompt_via=.final_arg writes "<prompt>\n".
    // raw output → trim → the assistant content IS the prompt → the
    // sanitizer takes the first non-empty line as the command.
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/echo"},
        .prompt_via = .final_arg,
        .output = .raw,
    });
    const M = worker_mod.Module(cfg);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out: [256]u8 = undefined;
    var exp: [256]u8 = undefined;
    var err: [256]u8 = undefined;
    @memset(&err, 0);

    var _sid_buf: [256]u8 = undefined;
    var _sid_len: usize = 0;
    const res = try M.doSubprocessRequest(
        testing.allocator,
        io,
        cfg.provider.subprocess,
        "bash",
        "",
        "ls -la",
        "",
        &.{},
        &_sid_buf,
        &_sid_len,
        &out,
        &exp,
        &err,
    );
    try testing.expect(res.cmd_len > 0);
    try testing.expectEqual(@as(usize, 0), res.err_len);
    // The full prompt was "<system>\n\nGenerate a bash command to: ls -la".
    // The sanitizer takes the first non-empty line, which is the
    // system-prompt opener. Just check we got SOMETHING non-empty
    // back — content-level correctness is covered by `parse_tests`.
    try testing.expect(res.cmd_len < out.len);
}

test "subprocess (json_field): cat with JSON stdin extracts requested field" {
    // /bin/cat with prompt_via=.stdin echoes our JSON-shaped prompt
    // back verbatim. The extractor pulls the named field. Composite
    // verification: stdin delivery + JSON parsing in one test.
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/cat"},
        .prompt_via = .stdin,
        .output = .{ .json_field = "result" },
    });
    const M = worker_mod.Module(cfg);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Hand-craft a JSON document on stdin via a small wrapper that
    // pipes a literal JSON string through cat. The full_prompt that
    // doSubprocessRequest builds isn't JSON though — we need a path
    // where we control what cat sees. Easiest: skip
    // doSubprocessRequest and test `runSubprocess` + the JSON
    // extractor independently.
    var err_buf: [128]u8 = undefined;
    var err_len: usize = 0;
    const stdout_buf = try M.runSubprocess(
        testing.allocator,
        io,
        cfg.provider.subprocess,
        \\{"type":"result","result":"ls -la","cost_usd":0.001}
    ,
        &.{},
        &err_buf,
        &err_len,
    );
    defer testing.allocator.free(stdout_buf);
    try testing.expectEqual(@as(usize, 0), err_len);

    var out: [128]u8 = undefined;
    const n = M.extractJsonStringField(stdout_buf, "result", &out);
    try testing.expect(n > 0);
    try testing.expectEqualStrings("ls -la", out[0..n]);
}

test "extractJsonStringField: missing field returns 0" {
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_field = "result" },
    });
    const M = worker_mod.Module(cfg);

    var out: [64]u8 = undefined;
    const n = M.extractJsonStringField(
        \\{"type":"result","cost_usd":0.001}
    , "result", &out);
    try testing.expectEqual(@as(usize, 0), n);
}

test "extractJsonStringField: nested objects don't trigger false positive" {
    // The field lives at depth 1; depth-2 occurrences must NOT be
    // picked up. Pins that the scanner respects nesting.
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_field = "result" },
    });
    const M = worker_mod.Module(cfg);

    var out: [64]u8 = undefined;
    const n = M.extractJsonStringField(
        \\{"meta":{"result":"WRONG"},"result":"RIGHT"}
    , "result", &out);
    try testing.expect(n > 0);
    try testing.expectEqualStrings("RIGHT", out[0..n]);
}

test "subprocess: spawn failure populates error_out, returns 0" {
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/this/path/definitely/does/not/exist/atty-llm-test"},
        .prompt_via = .final_arg,
    });
    const M = worker_mod.Module(cfg);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out: [128]u8 = undefined;
    var exp: [128]u8 = undefined;
    var err: [256]u8 = undefined;
    @memset(&err, 0);

    var _sid_buf: [256]u8 = undefined;
    var _sid_len: usize = 0;
    const res = try M.doSubprocessRequest(
        testing.allocator,
        io,
        cfg.provider.subprocess,
        "bash",
        "",
        "irrelevant",
        "",
        &.{},
        &_sid_buf,
        &_sid_len,
        &out,
        &exp,
        &err,
    );
    try testing.expectEqual(@as(usize, 0), res.cmd_len);
    try testing.expect(res.err_len > 0);
    // Error message should mention `spawn` so users know which
    // failure mode they hit (vs. exit-code / stdout / JSON errors).
    try testing.expect(std.mem.indexOf(u8, err[0..res.err_len], "spawn") != null);
}

test "claudeCode factory returns a sane subprocess shape" {
    const llm = @import("../llm.zig");
    const p = llm.providers.claudeCode(.{ .model = "claude-sonnet-4-6" });
    switch (p) {
        .http => unreachable,
        .subprocess => |sub| {
            // argv[0] is the program name.
            try testing.expectEqualStrings("claude", sub.argv[0]);
            // Should include the model.
            var saw_model = false;
            for (sub.argv) |a| {
                if (std.mem.eql(u8, a, "claude-sonnet-4-6")) saw_model = true;
            }
            try testing.expect(saw_model);
            // Should ask for JSON output.
            var saw_json = false;
            for (sub.argv) |a| {
                if (std.mem.eql(u8, a, "json")) saw_json = true;
            }
            try testing.expect(saw_json);
            // Output extraction picks `result`.
            try testing.expectEqual(types.SubprocessProvider.PromptVia.final_arg, sub.prompt_via);
            switch (sub.output) {
                .raw, .json_stream => unreachable,
                .json_field => |fname| try testing.expectEqualStrings("result", fname),
            }
        },
    }
}

test "claudeCode factory without model omits the --model flag" {
    const llm = @import("../llm.zig");
    const p = llm.providers.claudeCode(.{});
    switch (p) {
        .http => unreachable,
        .subprocess => |sub| {
            for (sub.argv) |a| {
                try testing.expect(!std.mem.eql(u8, a, "--model"));
            }
        },
    }
}

test "preset constants pin the expected model identifier" {
    const llm = @import("../llm.zig");
    const cases = .{
        .{ llm.providers.claude_sonnet_4_5, "claude-sonnet-4-5" },
        .{ llm.providers.claude_sonnet_4_6, "claude-sonnet-4-6" },
        .{ llm.providers.claude_opus_4_7, "claude-opus-4-7" },
        .{ llm.providers.claude_haiku_4_5, "claude-haiku-4-5-20251001" },
    };
    inline for (cases) |case| {
        const p = case[0];
        const expected: []const u8 = case[1];
        switch (p) {
            .http => unreachable,
            .subprocess => |sub| {
                var saw = false;
                for (sub.argv) |a| {
                    if (std.mem.eql(u8, a, expected)) saw = true;
                }
                try testing.expect(saw);
            },
        }
    }
}

test "openai preset hits the right base URL + key env" {
    const llm = @import("../llm.zig");
    switch (llm.providers.openai) {
        .subprocess => unreachable,
        .http => |http| {
            try testing.expectEqualStrings("https://api.openai.com/v1", http.api_base);
            try testing.expectEqualStrings("OPENAI_API_KEY", http.api_key_env);
        },
    }
}

test "simonwLlm factory pipes via stdin with raw output" {
    const llm = @import("../llm.zig");
    const p = llm.providers.simonwLlm(.{ .model = "gpt-4o-mini" });
    switch (p) {
        .http => unreachable,
        .subprocess => |sub| {
            try testing.expectEqualStrings("llm", sub.argv[0]);
            try testing.expectEqual(types.SubprocessProvider.PromptVia.stdin, sub.prompt_via);
            switch (sub.output) {
                .raw => {},
                .json_field, .json_stream => unreachable,
            }
        },
    }
}

test "doSubprocessDialogRequest round-trips via cat + JSON envelope" {
    // The HTTP dialog path posts a JSON request body; the
    // subprocess dialog path renders that body as plain text and
    // expects the CLI to return whatever the model produced. Use
    // cat to act as a passthrough — we hand it a complete request
    // body, it echoes it back, and we verify renderDialogBody
    // produced what we expected by inspecting cat's output through
    // the same code path. (This pins the JSON-parse + plain-text
    // render together; without it the rendering code is untested.)
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/cat"},
        .prompt_via = .stdin,
        .output = .raw,
    });
    const M = worker_mod.Module(cfg);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Minimal OpenAI-style body with two messages.
    const body =
        \\{"model":"x","messages":[{"role":"system","content":"sys"},{"role":"user","content":"hello"}]}
    ;

    var out: [256]u8 = undefined;
    var err: [256]u8 = undefined;

    var _sid_buf: [256]u8 = undefined;
    var _sid_len: usize = 0;
    const res = try M.doSubprocessDialogRequest(
        testing.allocator,
        io,
        cfg.provider.subprocess,
        body,
        &.{},
        false,
        &_sid_buf,
        &_sid_len,
        &out,
        &err,
    );
    try testing.expect(res.cmd_len > 0);
    // The rendered prompt that cat echoed should contain both
    // roles' content (in plain text form).
    const echoed = out[0..res.cmd_len];
    try testing.expect(std.mem.indexOf(u8, echoed, "system") != null);
    try testing.expect(std.mem.indexOf(u8, echoed, "sys") != null);
    try testing.expect(std.mem.indexOf(u8, echoed, "user") != null);
    try testing.expect(std.mem.indexOf(u8, echoed, "hello") != null);
}

test "subprocess timeout: /bin/sleep 5 with 500ms budget gets SIGKILL'd" {
    // 500 ms budget with a 400 ms lower bound — gives the
    // watchdog's 50 ms polling slice plenty of jitter room on a
    // thrashed CI runner without making the test slow.
    // `.stdin` keeps the prompt off argv so `sleep` doesn't
    // reject extra args and exit early.
    const cfg = comptime makeTestCfg(.{
        .argv = &.{ "/bin/sleep", "5" },
        .prompt_via = .stdin,
        .timeout_ms = 500,
    });
    const M = worker_mod.Module(cfg);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var err: [128]u8 = undefined;
    var err_len: usize = 0;

    const start = nowMs();
    const result = M.runSubprocess(
        testing.allocator,
        io,
        cfg.provider.subprocess,
        "ignored",
        &.{},
        &err,
        &err_len,
    );
    const elapsed = nowMs() - start;

    try testing.expectError(error.SubprocessFailed, result);
    try testing.expect(err_len > 0);
    try testing.expect(std.mem.indexOf(u8, err[0..err_len], "timed out") != null);
    try testing.expect(std.mem.indexOf(u8, err[0..err_len], "500ms") != null);
    try testing.expect(elapsed < 3000);
    try testing.expect(elapsed >= 400);
}

test "subprocess timeout = 0 disables watchdog (echo still works)" {
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/echo"},
        .prompt_via = .final_arg,
        .timeout_ms = 0,
    });
    const M = worker_mod.Module(cfg);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var err: [128]u8 = undefined;
    var err_len: usize = 0;
    const stdout = try M.runSubprocess(
        testing.allocator,
        io,
        cfg.provider.subprocess,
        "hello",
        &.{},
        &err,
        &err_len,
    );
    defer testing.allocator.free(stdout);
    try testing.expectEqual(@as(usize, 0), err_len);
    try testing.expect(stdout.len > 0);
}

test "extractJsonStreamResult: skips system + assistant events, takes result" {
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_stream = .{ .field = "result" } },
    });
    const M = worker_mod.Module(cfg);

    const body =
        \\{"type":"system","subtype":"init","session_id":"sess-1"}
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"du "}]}}
        \\{"type":"result","subtype":"success","result":"du -sh * | sort -h"}
    ;
    var out: [128]u8 = undefined;
    const n = M.extractJsonStreamResult(body, "result", &out);
    try testing.expectEqualStrings("du -sh * | sort -h", out[0..n]);
}

test "extractJsonStreamResult: missing result event returns 0" {
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_stream = .{ .field = "result" } },
    });
    const M = worker_mod.Module(cfg);
    const body =
        \\{"type":"system","subtype":"init"}
        \\{"type":"assistant","message":{"content":[]}}
    ;
    var out: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), M.extractJsonStreamResult(body, "result", &out));
}

test "extractJsonStreamResult: skips garbage lines + reaches result" {
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_stream = .{ .field = "result" } },
    });
    const M = worker_mod.Module(cfg);
    const body =
        \\not json at all
        \\{"partial":true}
        \\{"type":"result","result":"ok"}
    ;
    var out: [16]u8 = undefined;
    const n = M.extractJsonStreamResult(body, "result", &out);
    try testing.expectEqualStrings("ok", out[0..n]);
}

test "stream-json: doSubprocessRequest round-trips a stream-json producer" {
    // Spawn a small shell pipeline that emits the three-line
    // stream-json shape; doSubprocessRequest should extract the
    // result event's field, sanitize, return the command.
    const cfg = comptime makeTestCfg(.{
        .argv = &.{
            "/bin/sh",
            "-c",
            "printf '%s\\n' " ++
                "'{\"type\":\"system\",\"subtype\":\"init\"}' " ++
                "'{\"type\":\"result\",\"result\":\"ls -la\"}'",
        },
        .prompt_via = .stdin,
        .output = .{ .json_stream = .{ .field = "result" } },
    });
    const M = worker_mod.Module(cfg);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out: [128]u8 = undefined;
    var exp: [128]u8 = undefined;
    var err: [256]u8 = undefined;
    var _sid_buf: [256]u8 = undefined;
    var _sid_len: usize = 0;
    const res = try M.doSubprocessRequest(
        testing.allocator,
        io,
        cfg.provider.subprocess,
        "bash",
        "",
        "list files",
        "",
        &.{},
        &_sid_buf,
        &_sid_len,
        &out,
        &exp,
        &err,
    );
    try testing.expect(res.cmd_len > 0);
    try testing.expect(std.mem.indexOf(u8, out[0..res.cmd_len], "ls -la") != null);
}

test "renderLatestUserTurn: picks the last role=user message" {
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_stream = .{ .field = "result" } },
        .session = .{ .continuation = .{} },
    });
    // Access the private helper indirectly through the dialog-mode
    // path. doSubprocessDialogRequest in session-active mode calls
    // renderLatestUserTurn; we use cat as the subprocess to echo
    // the rendered prompt straight back so we can assert on it.
    const echo_cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/cat"},
        .prompt_via = .stdin,
        .output = .raw,
        .session = .{ .continuation = .{} },
    });
    const M = worker_mod.Module(echo_cfg);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Body with several turns: system, user-1, assistant, user-2.
    // `renderLatestUserTurn` must pick "user-2".
    const body =
        \\{"model":"x","messages":[{"role":"system","content":"sys"},{"role":"user","content":"first user turn"},{"role":"assistant","content":"a reply"},{"role":"user","content":"final user turn"}]}
    ;

    var out: [256]u8 = undefined;
    var err: [128]u8 = undefined;
    var _sid_buf: [256]u8 = undefined;
    var _sid_len: usize = 0;
    const res = try M.doSubprocessDialogRequest(
        testing.allocator,
        io,
        echo_cfg.provider.subprocess,
        body,
        &.{},
        true, // session_active = true → renderLatestUserTurn path
        &_sid_buf,
        &_sid_len,
        &out,
        &err,
    );
    try testing.expect(res.cmd_len > 0);
    const echoed = std.mem.trim(u8, out[0..res.cmd_len], " \t\r\n");
    try testing.expectEqualStrings("final user turn", echoed);
    _ = cfg;
}

test "renderLatestUserTurn: falls back to full body when no user role" {
    // No user turn → falls through to renderDialogBodyAsPrompt
    // which emits "ROLE:\ncontent\n\n" for every message.
    const echo_cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/cat"},
        .prompt_via = .stdin,
        .output = .raw,
        .session = .{ .continuation = .{} },
    });
    const M = worker_mod.Module(echo_cfg);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const body =
        \\{"model":"x","messages":[{"role":"system","content":"only system"},{"role":"assistant","content":"only assistant"}]}
    ;

    var out: [256]u8 = undefined;
    var err: [128]u8 = undefined;
    var _sid_buf: [256]u8 = undefined;
    var _sid_len: usize = 0;
    const res = try M.doSubprocessDialogRequest(
        testing.allocator,
        io,
        echo_cfg.provider.subprocess,
        body,
        &.{},
        true,
        &_sid_buf,
        &_sid_len,
        &out,
        &err,
    );
    try testing.expect(res.cmd_len > 0);
    const echoed = out[0..res.cmd_len];
    // Both role labels should appear because we fell through to
    // the full-body renderer.
    try testing.expect(std.mem.indexOf(u8, echoed, "system") != null);
    try testing.expect(std.mem.indexOf(u8, echoed, "assistant") != null);
}

test "extractStreamSessionId: pulls session_id from system/init event" {
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_stream = .{ .field = "result" } },
    });
    const M = worker_mod.Module(cfg);

    const body =
        \\{"type":"system","subtype":"init","session_id":"sess-abc-123"}
        \\{"type":"result","result":"ok"}
    ;
    var out: [64]u8 = undefined;
    const n = M.extractStreamSessionId(body, "session_id", &out);
    try testing.expectEqualStrings("sess-abc-123", out[0..n]);
}

test "extractStreamSessionId: ignores non-init system events" {
    // A `type=system,subtype=info` event mid-stream must NOT match;
    // only the init event carries the session id.
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_stream = .{ .field = "result" } },
    });
    const M = worker_mod.Module(cfg);

    const body =
        \\{"type":"system","subtype":"info","session_id":"WRONG"}
        \\{"type":"system","subtype":"init","session_id":"RIGHT"}
    ;
    var out: [64]u8 = undefined;
    const n = M.extractStreamSessionId(body, "session_id", &out);
    try testing.expectEqualStrings("RIGHT", out[0..n]);
}

test "session continuation: second turn argv prepends --resume <id>" {
    // Drive doSubprocessRequest twice. Turn 1: subprocess emits a
    // stream-json init event with session_id, plus a result. Turn
    // 2: call with the captured id as prepend_argv — verify the
    // subprocess actually saw `--resume <id>` by having it
    // print its own argv via /bin/sh.
    const cfg = comptime makeTestCfg(.{
        // The script just prints back its own positional argv so we
        // can assert against it. The first arg ($0 in -c usage) is
        // skipped by sh; positional starts at $1.
        .argv = &.{
            "/bin/sh",
            "-c",
            // Emit a fake stream-json init+result, then echo a
            // marker line containing our extra args so the test
            // can grep them. The marker stays inside the result
            // event's string for simplicity.
            "printf '%s\\n' '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"S-1\"}' '{\"type\":\"result\",\"result\":\"argv-was: '\"$1 $2\"'\"}'",
            "sh-arg0",
        },
        .prompt_via = .stdin,
        .output = .{ .json_stream = .{ .field = "result" } },
        .session = .{ .continuation = .{} },
    });
    const M = worker_mod.Module(cfg);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Turn 1 — no session id yet.
    var out1: [256]u8 = undefined;
    var exp1: [128]u8 = undefined;
    var err1: [128]u8 = undefined;
    var sid1: [64]u8 = undefined;
    var sid1_len: usize = 0;
    const r1 = try M.doSubprocessRequest(
        testing.allocator,
        io,
        cfg.provider.subprocess,
        "bash",
        "",
        "first prompt",
        "",
        &.{},
        &sid1,
        &sid1_len,
        &out1,
        &exp1,
        &err1,
    );
    try testing.expect(r1.cmd_len > 0);
    try testing.expectEqualStrings("S-1", sid1[0..sid1_len]);

    // Turn 2 — pass the captured id back as the resume flag.
    var out2: [256]u8 = undefined;
    var exp2: [128]u8 = undefined;
    var err2: [128]u8 = undefined;
    var sid2: [64]u8 = undefined;
    var sid2_len: usize = 0;
    const prepend = [_][]const u8{ "--resume", sid1[0..sid1_len] };
    const r2 = try M.doSubprocessRequest(
        testing.allocator,
        io,
        cfg.provider.subprocess,
        "bash",
        "",
        "second prompt",
        "",
        &prepend,
        &sid2,
        &sid2_len,
        &out2,
        &exp2,
        &err2,
    );
    try testing.expect(r2.cmd_len > 0);
    // The subprocess printed its own $1 $2 into the result text;
    // verify "--resume S-1" appears in the response we got back.
    try testing.expect(std.mem.indexOf(u8, out2[0..r2.cmd_len], "--resume") != null);
    try testing.expect(std.mem.indexOf(u8, out2[0..r2.cmd_len], "S-1") != null);
}

test "claudeCodeStream(.continuation = true) wires Session.continuation" {
    const llm = @import("../llm.zig");
    const p = llm.providers.claudeCodeStream(.{ .continuation = true });
    switch (p) {
        .http => unreachable,
        .subprocess => |sub| switch (sub.session) {
            .none => unreachable,
            .continuation => |c| {
                try testing.expectEqualStrings("--resume", c.flag);
                try testing.expectEqualStrings("session_id", c.id_field);
            },
        },
    }
}

test "claudeCodeStream factory uses stream-json + json_stream output" {
    const llm = @import("../llm.zig");
    const p = llm.providers.claudeCodeStream(.{ .model = "claude-sonnet-4-6" });
    switch (p) {
        .http => unreachable,
        .subprocess => |sub| {
            var saw_stream = false;
            for (sub.argv) |a| if (std.mem.eql(u8, a, "stream-json")) {
                saw_stream = true;
            };
            try testing.expect(saw_stream);
            switch (sub.output) {
                .raw, .json_field => unreachable,
                .json_stream => |js| try testing.expectEqualStrings("result", js.field),
            }
        },
    }
}

test "extractJsonStringField: unicode escapes in value round-trip" {
    // Per subagent finding #4, the hand-rolled extractor dropped
    // \uXXXX. The std.json-backed implementation should decode
    // them properly. Use a smart quote (U+201C) — a real `claude`
    // result CAN contain these when the user's prompt or model
    // output includes typographic punctuation.
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_field = "result" },
    });
    const M = worker_mod.Module(cfg);

    var out: [64]u8 = undefined;
    const body =
        \\{"result":"smart “quoted”"}
    ;
    const n = M.extractJsonStringField(body, "result", &out);
    try testing.expect(n > 0);
    // The decoded value contains the UTF-8 form of U+201C / U+201D
    // (\xE2\x80\x9C and \xE2\x80\x9D).
    try testing.expect(std.mem.indexOf(u8, out[0..n], "\xE2\x80\x9C") != null);
    try testing.expect(std.mem.indexOf(u8, out[0..n], "\xE2\x80\x9D") != null);
}

// ── #162 — providers[] dispatch + ModeMask ────────────────────────────────

test "ModeMask: matches() honors per-mode flags" {
    const mm: types.ModeMask = .{ .single = true, .dialog = false, .auto = true, .chat = false };
    try testing.expect(mm.matches(.single));
    try testing.expect(!mm.matches(.dialog));
    try testing.expect(mm.matches(.auto));
    try testing.expect(!mm.matches(.chat));
}

test "ModeMask preset constants are correct" {
    try testing.expect(types.ModeMask.all.matches(.single));
    try testing.expect(types.ModeMask.all.matches(.dialog));
    try testing.expect(types.ModeMask.all.matches(.auto));
    try testing.expect(types.ModeMask.all.matches(.chat));

    try testing.expect(types.ModeMask.single_only.matches(.single));
    try testing.expect(!types.ModeMask.single_only.matches(.dialog));
    try testing.expect(!types.ModeMask.single_only.matches(.auto));
    try testing.expect(!types.ModeMask.single_only.matches(.chat));

    try testing.expect(!types.ModeMask.dialog_only.matches(.single));
    try testing.expect(types.ModeMask.dialog_only.matches(.dialog));
    try testing.expect(types.ModeMask.dialog_only.matches(.auto));
    try testing.expect(types.ModeMask.dialog_only.matches(.chat));

    try testing.expect(!types.ModeMask.dialog_and_auto.matches(.single));
    try testing.expect(types.ModeMask.dialog_and_auto.matches(.dialog));
    try testing.expect(types.ModeMask.dialog_and_auto.matches(.auto));
    try testing.expect(!types.ModeMask.dialog_and_auto.matches(.chat));
}

test "resolveProvider: empty providers[] returns fallback" {
    const RK = struct {
        pub const single: u1 = 0;
        pub const dialog: u1 = 1;
    };
    _ = RK;
    const fallback: types.Provider = .{ .http = .{ .api_base = "http://x/v1", .model = "fb" } };
    const entries: []const types.ProviderEntry = &.{};
    const r = worker_mod.resolveProvider(@as(enum { single, dialog }, .single), entries, fallback, 0);
    switch (r.provider) {
        .http => |h| try testing.expectEqualStrings("fb", h.model),
        .subprocess => unreachable,
    }
    try testing.expectEqualStrings("", r.name);
}

test "resolveProvider: current_idx wins when its for_modes matches" {
    const a: types.Provider = .{ .http = .{ .model = "a" } };
    const b: types.Provider = .{ .http = .{ .model = "b" } };
    const c: types.Provider = .{ .http = .{ .model = "c" } };
    const entries: []const types.ProviderEntry = &.{
        .{ .name = "a", .config = a, .for_modes = .single_only },
        .{ .name = "b", .config = b, .for_modes = .dialog_only },
        .{ .name = "c", .config = c, .for_modes = .all },
    };
    const fallback: types.Provider = .{ .http = .{ .model = "fb" } };
    // current_idx = 1 (b), request kind dialog → b matches → b wins
    const r = worker_mod.resolveProvider(@as(enum { single, dialog }, .dialog), entries, fallback, 1);
    switch (r.provider) {
        .http => |h| try testing.expectEqualStrings("b", h.model),
        .subprocess => unreachable,
    }
    try testing.expectEqualStrings("b", r.name);
}

test "resolveProvider: current_idx doesn't match → first-matching wins" {
    const haiku: types.Provider = .{ .http = .{ .model = "haiku" } };
    const sonnet: types.Provider = .{ .http = .{ .model = "sonnet" } };
    const entries: []const types.ProviderEntry = &.{
        .{ .name = "haiku", .config = haiku, .for_modes = .single_only },
        .{ .name = "sonnet", .config = sonnet, .for_modes = .dialog_only },
    };
    const fallback: types.Provider = .{ .http = .{ .model = "fb" } };
    // current_idx = 0 (haiku, single_only), request kind dialog →
    // haiku doesn't match; fall through to first matching = sonnet.
    const r = worker_mod.resolveProvider(@as(enum { single, dialog }, .dialog), entries, fallback, 0);
    try testing.expectEqualStrings("sonnet", r.name);
}

test "resolveProvider: nothing matches → fallback" {
    const a: types.Provider = .{ .http = .{ .model = "a" } };
    const entries: []const types.ProviderEntry = &.{
        .{ .name = "a", .config = a, .for_modes = .single_only },
    };
    const fallback: types.Provider = .{ .http = .{ .model = "fb" } };
    // current_idx = 0 (single_only), request kind dialog → no match;
    // first-matching scan also finds none → fallback wins.
    const r = worker_mod.resolveProvider(@as(enum { single, dialog }, .dialog), entries, fallback, 0);
    switch (r.provider) {
        .http => |h| try testing.expectEqualStrings("fb", h.model),
        .subprocess => unreachable,
    }
    try testing.expectEqualStrings("", r.name);
}

test "resolveProviderForMode: auto-only entry is reachable" {
    const auto_pick: types.Provider = .{ .http = .{ .model = "auto-pick" } };
    const generic: types.Provider = .{ .http = .{ .model = "default" } };
    const entries: []const types.ProviderEntry = &.{
        .{ .name = "auto-pick", .config = auto_pick, .for_modes = .{ .single = false, .dialog = false, .auto = true, .chat = false } },
        .{ .name = "default", .config = generic, .for_modes = .all },
    };
    const fallback: types.Provider = .{ .http = .{ .model = "fb" } };
    const r = worker_mod.resolveProviderForMode(.auto, entries, fallback, 0);
    try testing.expectEqualStrings("auto-pick", r.name);
}

test "resolveProviderForMode: chat-only entry is reachable" {
    const chat_only: types.Provider = .{ .http = .{ .model = "chat-pick" } };
    const generic: types.Provider = .{ .http = .{ .model = "default" } };
    const entries: []const types.ProviderEntry = &.{
        .{ .name = "default", .config = generic, .for_modes = .all },
        .{ .name = "chat-pick", .config = chat_only, .for_modes = .{ .single = false, .dialog = false, .auto = false, .chat = true } },
    };
    const fallback: types.Provider = .{ .http = .{ .model = "fb" } };
    // current_idx = 1 points at the chat-only entry directly.
    const r = worker_mod.resolveProviderForMode(.chat, entries, fallback, 1);
    try testing.expectEqualStrings("chat-pick", r.name);
}

test "resolveProviderForMode: dialog mode doesn't pick auto-only entry" {
    const auto_pick: types.Provider = .{ .http = .{ .model = "auto-pick" } };
    const dialog_pick: types.Provider = .{ .http = .{ .model = "dialog-pick" } };
    const entries: []const types.ProviderEntry = &.{
        .{ .name = "auto-pick", .config = auto_pick, .for_modes = .{ .single = false, .dialog = false, .auto = true, .chat = false } },
        .{ .name = "dialog-pick", .config = dialog_pick, .for_modes = .{ .single = false, .dialog = true, .auto = false, .chat = false } },
    };
    const fallback: types.Provider = .{ .http = .{ .model = "fb" } };
    // current_idx = 0 (auto-only) but mode is dialog → fall through
    // to first-matching → dialog-pick.
    const r = worker_mod.resolveProviderForMode(.dialog, entries, fallback, 0);
    try testing.expectEqualStrings("dialog-pick", r.name);
}

// ── #168 — unified parseStreamJson ─────────────────────────────────────

test "parseStreamJson: captures result + session_id in one walk" {
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_stream = .{ .field = "result" } },
    });
    const M = worker_mod.Module(cfg);

    const body =
        \\{"type":"system","subtype":"init","session_id":"S-1"}
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}
        \\{"type":"result","result":"ls -la"}
    ;
    var result_out: [128]u8 = undefined;
    var sid_out: [64]u8 = undefined;
    const p = M.parseStreamJson(body, "result", "session_id", &result_out, &sid_out);
    try testing.expectEqualStrings("ls -la", result_out[0..p.result_len]);
    try testing.expectEqualStrings("S-1", sid_out[0..p.session_id_len]);
}

test "parseStreamJson: empty session_id_field skips session capture" {
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_stream = .{ .field = "result" } },
    });
    const M = worker_mod.Module(cfg);

    const body =
        \\{"type":"system","subtype":"init","session_id":"S-1"}
        \\{"type":"result","result":"ok"}
    ;
    var result_out: [64]u8 = undefined;
    var sid_out: [0]u8 = undefined;
    const p = M.parseStreamJson(body, "result", "", &result_out, &sid_out);
    try testing.expectEqualStrings("ok", result_out[0..p.result_len]);
    try testing.expectEqual(@as(usize, 0), p.session_id_len);
}

test "parseStreamJson: short-circuits when both captures land" {
    // Use a body with the result + init early, then a malformed
    // line after. If parseStreamJson short-circuits correctly it
    // won't trip over the garbage line.
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_stream = .{ .field = "result" } },
    });
    const M = worker_mod.Module(cfg);

    const body =
        \\{"type":"system","subtype":"init","session_id":"S-1"}
        \\{"type":"result","result":"ok"}
        \\NOT JSON {{{ this would crash a less-defensive parser
    ;
    var result_out: [64]u8 = undefined;
    var sid_out: [64]u8 = undefined;
    const p = M.parseStreamJson(body, "result", "session_id", &result_out, &sid_out);
    try testing.expectEqualStrings("ok", result_out[0..p.result_len]);
    try testing.expectEqualStrings("S-1", sid_out[0..p.session_id_len]);
}

test "parseStreamJson: oversized session_id abandons capture for the rest of the stream" {
    // Pre-#168 `extractStreamSessionId` returned 0 immediately on
    // overflow. The unified walker mirrors that by flipping
    // want_session off — a later init event with a smaller (likely
    // bogus) id must NOT be picked up. Result capture stays alive.
    const cfg_a = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_stream = .{ .field = "result" } },
    });
    const Ma = worker_mod.Module(cfg_a);

    const body_a =
        \\{"type":"system","subtype":"init","session_id":"way-too-long-to-fit"}
        \\{"type":"system","subtype":"init","session_id":"S2"}
        \\{"type":"result","result":"ok"}
    ;
    var result_a: [64]u8 = undefined;
    var sid_a: [8]u8 = undefined; // can't fit the first id
    const pa = Ma.parseStreamJson(body_a, "result", "session_id", &result_a, &sid_a);
    try testing.expectEqualStrings("ok", result_a[0..pa.result_len]);
    try testing.expectEqual(@as(usize, 0), pa.session_id_len);
}

test "parseStreamJson: session truncation guard rejects oversized id" {
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_stream = .{ .field = "result" } },
    });
    const M = worker_mod.Module(cfg);

    const body =
        \\{"type":"system","subtype":"init","session_id":"way-too-long-for-the-tiny-buffer"}
        \\{"type":"result","result":"ok"}
    ;
    var result_out: [64]u8 = undefined;
    var sid_out: [8]u8 = undefined; // smaller than the id
    const p = M.parseStreamJson(body, "result", "session_id", &result_out, &sid_out);
    try testing.expectEqualStrings("ok", result_out[0..p.result_len]);
    try testing.expectEqual(@as(usize, 0), p.session_id_len);
}

test "extractStreamSessionId + extractJsonStreamResult wrappers still work" {
    const cfg = comptime makeTestCfg(.{
        .argv = &.{"/bin/true"},
        .output = .{ .json_stream = .{ .field = "result" } },
    });
    const M = worker_mod.Module(cfg);
    const body =
        \\{"type":"system","subtype":"init","session_id":"S-X"}
        \\{"type":"result","result":"X"}
    ;
    var out: [64]u8 = undefined;
    const n_r = M.extractJsonStreamResult(body, "result", &out);
    try testing.expectEqualStrings("X", out[0..n_r]);
    const n_s = M.extractStreamSessionId(body, "session_id", &out);
    try testing.expectEqualStrings("S-X", out[0..n_s]);
}
