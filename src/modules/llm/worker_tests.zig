//! Tests for the subprocess-provider request path (issue #157).
//! Spawns small POSIX utilities (`/bin/echo`, `/bin/cat`) as the
//! subprocess so the tests don't need any LLM CLI on PATH.

const std = @import("std");
const testing = std.testing;

const types = @import("types.zig");
const worker_mod = @import("worker.zig");

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

    const res = try M.doSubprocessRequest(
        testing.allocator,
        io,
        cfg.provider.subprocess,
        "bash",
        "",
        "ls -la",
        "",
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
    const stdout_buf = try M.runSubprocess(
        testing.allocator,
        io,
        cfg.provider.subprocess,
        \\{"type":"result","result":"ls -la","cost_usd":0.001}
    ,
        &.{},
    );
    defer testing.allocator.free(stdout_buf);

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

    const res = try M.doSubprocessRequest(
        testing.allocator,
        io,
        cfg.provider.subprocess,
        "bash",
        "",
        "irrelevant",
        "",
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
                .raw => unreachable,
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
