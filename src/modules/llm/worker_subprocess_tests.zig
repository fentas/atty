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

fn expectArgv(p: @import("types.zig").Provider, expected: []const []const u8) !void {
    switch (p) {
        .http => return error.TestUnexpectedHttp,
        .subprocess => |sub| {
            try testing.expectEqual(types.SubprocessProvider.PromptVia.final_arg, sub.prompt_via);
            switch (sub.output) {
                .raw => {},
                .json_field, .json_stream => return error.TestUnexpectedJson,
            }
            try testing.expectEqual(expected.len, sub.argv.len);
            for (expected, sub.argv) |want, got| try testing.expectEqualStrings(want, got);
        },
    }
}

test "geminiCli factory: exact argv pins order — skip-trust, model, -o text, trailing -p" {
    const llm = @import("../llm.zig");
    // With a model: --skip-trust precedes the model; argv ENDS in -p so
    // atty's appended prompt lands as `-p <prompt>`; -o text → .raw.
    try expectArgv(llm.providers.gemini_2_5_pro, &.{ "gemini", "--skip-trust", "-m", "gemini-2.5-pro", "-o", "text", "-p" });
    try expectArgv(llm.providers.gemini_2_5_flash, &.{ "gemini", "--skip-trust", "-m", "gemini-2.5-flash", "-o", "text", "-p" });
}

test "geminiCli factory: no-model + extra_argv branch lands extras before -p" {
    const llm = @import("../llm.zig");
    // No model → the -m/MODEL pair is dropped (CLI default); extra_argv
    // is inserted before the trailing -p.
    try expectArgv(llm.providers.geminiCli(.{ .extra_argv = &.{"--yolo"} }), &.{ "gemini", "--skip-trust", "-o", "text", "--yolo", "-p" });
    try expectArgv(llm.providers.geminiCli(.{}), &.{ "gemini", "--skip-trust", "-o", "text", "-p" });
    // has_model + extra_argv together: extras still land after -o text,
    // before the trailing -p, with the -m MODEL pair intact.
    try expectArgv(
        llm.providers.geminiCli(.{ .model = "gemini-2.5-pro", .extra_argv = &.{ "--yolo", "--approval-mode", "yolo" } }),
        &.{ "gemini", "--skip-trust", "-m", "gemini-2.5-pro", "-o", "text", "--yolo", "--approval-mode", "yolo", "-p" },
    );
}

test "prompt_ext: agentic CLI presets carry the steering text, plain providers don't" {
    const llm = @import("../llm.zig");
    const agentic = llm.prompts.agentic_cli_ext;
    try testing.expect(agentic.len > 0);
    // Agentic CLIs (own tools) default to the steering extension.
    try testing.expectEqualStrings(agentic, types.providerPromptExt(llm.providers.gemini_2_5_pro));
    try testing.expectEqualStrings(agentic, types.providerPromptExt(llm.providers.gemini_2_5_flash));
    try testing.expectEqualStrings(agentic, types.providerPromptExt(llm.providers.claude_opus_4_7));
    try testing.expectEqualStrings(agentic, types.providerPromptExt(llm.providers.claudeCodeStream(.{ .model = "claude-opus-4-7" })));
    // Plain transports have no built-in tools → no extension.
    try testing.expectEqualStrings("", types.providerPromptExt(llm.providers.openai));
    try testing.expectEqualStrings("", types.providerPromptExt(llm.providers.ollama));
    try testing.expectEqualStrings("", types.providerPromptExt(llm.providers.simonwLlm(.{ .model = "gpt-4o-mini" })));
}

test "prompt_ext: override replaces the preset default" {
    const llm = @import("../llm.zig");
    try testing.expectEqualStrings("just exec please", types.providerPromptExt(llm.providers.geminiCli(.{ .model = "gemini-2.5-pro", .prompt_ext = "just exec please" })));
    // Explicitly empty drops the steering text.
    try testing.expectEqualStrings("", types.providerPromptExt(llm.providers.geminiCli(.{ .model = "gemini-2.5-pro", .prompt_ext = "" })));
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

test "subprocess timeout kills the whole process group (grandchildren too)" {
    // Invariant: a timeout-driven kill MUST reach helpers and
    // grandchildren that the spawned CLI may have forked, not
    // just the direct child. Achieved by spawning with
    // `pgid = 0` (child becomes its own process-group leader)
    // and sending the kill via `kill(-pid, …)` (negative PID =
    // process-group target per POSIX `kill(2)`).
    //
    // Fixture: `sh -c 'sleep 99 & echo $! >/tmp/.. ; sleep 99'`
    // forks a backgrounded grandchild, writes its PID to a
    // tempfile, then sleeps itself. Both processes must be
    // gone after the watchdog fires.
    const seed: u64 = blk: {
        var ts: std.posix.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        break :blk @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    };
    var pid_path_buf: [80]u8 = undefined;
    const pid_path = try std.fmt.bufPrint(&pid_path_buf, "/tmp/atty-pgid-test-{x}.pid", .{seed});
    var pid_path_z_buf: [128]u8 = undefined;
    const pid_path_z = try std.fmt.bufPrintZ(&pid_path_z_buf, "{s}", .{pid_path});
    defer _ = std.c.unlink(pid_path_z.ptr);

    var script_buf: [256]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buf, "sleep 99 & echo $! > {s}; sleep 99", .{pid_path});

    const cfg = comptime makeTestCfg(.{
        .argv = &.{ "/bin/sh", "-c", "PLACEHOLDER" },
        .prompt_via = .stdin,
        .timeout_ms = 500,
    });
    const M = worker_mod.Module(cfg);

    // Override the argv at runtime — comptime cfg has a placeholder.
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(testing.allocator);
    try argv_list.appendSlice(testing.allocator, &.{ "/bin/sh", "-c", script });

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var err: [128]u8 = undefined;
    var err_len: usize = 0;
    const sub_override: @import("types.zig").SubprocessProvider = .{
        .argv = argv_list.items,
        .prompt_via = .stdin,
        .timeout_ms = 500,
    };
    const result = M.runSubprocess(
        testing.allocator,
        io,
        sub_override,
        "ignored",
        &.{},
        &err,
        &err_len,
    );
    try testing.expectError(error.SubprocessFailed, result);
    try testing.expect(std.mem.indexOf(u8, err[0..err_len], "timed out") != null);

    // Read the grandchild's PID from the tempfile. The shell
    // wrote it BEFORE its own sleep started, so the PID is
    // recorded even if the watchdog killed the shell before
    // its second `sleep` ran.
    // Poll for the pidfile rather than reading once — under
    // load the shell might still be racing the redirect when
    // the watchdog fires. 1s overall deadline is well past
    // the fork+write+sleep schedule (~microseconds) but tight
    // enough that a regression (shell killed before write)
    // surfaces as a test failure rather than a hang.
    const Libc = struct {
        extern "c" fn open(path: [*:0]const u8, flags: c_int) c_int;
        extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
        extern "c" fn close(fd: c_int) c_int;
        extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
    };
    var pid_buf: [32]u8 = undefined;
    var pid_len: usize = 0;
    {
        const poll_deadline_ms: i64 = 1000;
        const start = nowMs();
        while ((nowMs() - start) < poll_deadline_ms) {
            const fd = Libc.open(pid_path_z.ptr, 0);
            if (fd >= 0) {
                defer _ = Libc.close(fd);
                const n = Libc.read(fd, &pid_buf, pid_buf.len);
                if (n > 0) {
                    pid_len = @intCast(n);
                    break;
                }
            }
            var s: std.c.timespec = .{ .sec = 0, .nsec = @intCast(10 * std.time.ns_per_ms) };
            _ = std.c.nanosleep(&s, null);
        }
        try testing.expect(pid_len > 0);
    }
    const pid_str = std.mem.trimEnd(u8, pid_buf[0..pid_len], " \t\r\n");
    const grandchild_pid = try std.fmt.parseInt(std.c.pid_t, pid_str, 10);

    // Poll for /proc/<grandchild_pid> to disappear. The
    // watchdog already ran (we observed "timed out"), so the
    // group kill has already been sent — we just need the
    // kernel to deliver + reap. 2s overall deadline is
    // generous for any sane CI runner; the kill cycle
    // typically completes in single-digit ms.
    var proc_path_buf: [64]u8 = undefined;
    const proc_path = try std.fmt.bufPrintZ(
        &proc_path_buf,
        "/proc/{d}",
        .{grandchild_pid},
    );
    const kill_deadline_ms: i64 = 2000;
    const kill_start = nowMs();
    var gone = false;
    while ((nowMs() - kill_start) < kill_deadline_ms) {
        if (Libc.access(proc_path.ptr, 0) < 0) {
            gone = true;
            break;
        }
        var s: std.c.timespec = .{ .sec = 0, .nsec = @intCast(20 * std.time.ns_per_ms) };
        _ = std.c.nanosleep(&s, null);
    }
    try testing.expect(gone);
}

test "subprocess: large stdin prompt to a streaming echo completes without deadlock" {
    // Regression for audit #430. `/bin/cat` is a full-duplex streaming
    // echo: it writes stdout as it reads stdin. With a prompt larger
    // than the ~64 KiB pipe buffer, the pre-fix synchronous "write all
    // of stdin, THEN read stdout" order deadlocks — cat blocks writing
    // stdout (pipe full) while atty blocks writing stdin (pipe full) —
    // and the watchdog SIGKILLs at the budget, surfacing a spurious
    // timeout. Writing stdin from its own thread (concurrent with the
    // stdout drainer) breaks the cycle.
    const cfg = comptime types.Config{
        .provider = .{
            .subprocess = .{
                .argv = &.{"/bin/cat"},
                .prompt_via = .stdin,
                .output = .raw,
                // Generous budget: a working run finishes in milliseconds,
                // so any timeout here means the deadlock regressed.
                .timeout_ms = 5000,
            },
        },
        .with_explanation = false,
        // read_cap = max_response_bytes * 16; keep it well above the
        // echoed prompt so the read isn't what bounds the test.
        .max_response_bytes = 1024 * 1024,
    };
    const M = worker_mod.Module(cfg);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 256 KiB — 4× the default Linux pipe buffer, so both the stdin
    // and stdout pipes fill mid-transfer.
    const prompt_size = 256 * 1024;
    const prompt = try testing.allocator.alloc(u8, prompt_size);
    defer testing.allocator.free(prompt);
    @memset(prompt, 'x');

    var err: [128]u8 = undefined;
    var err_len: usize = 0;
    const start = nowMs();
    const stdout = try M.runSubprocess(
        testing.allocator,
        io,
        cfg.provider.subprocess,
        prompt,
        &.{},
        &err,
        &err_len,
    );
    defer testing.allocator.free(stdout);
    const elapsed = nowMs() - start;

    try testing.expectEqual(@as(usize, 0), err_len);
    // cat is a pure echo — every byte comes back.
    try testing.expectEqual(prompt_size, stdout.len);
    // A deadlock would have run to the 5s budget; a healthy concurrent
    // transfer is near-instant. Bound well under the budget.
    try testing.expect(elapsed < 4000);
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
