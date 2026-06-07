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
    // Hold the connection past the test's deadline + slack
    // (300 ms deadline + 1700 ms test bound = 2 s) but not
    // forever — once we return, the conn fd closes and the
    // detached HTTP fetch thread sees EOF, runs publishDone,
    // observes ABANDONED, and self-deinits. Bounding the handler
    // (vs `while (true)`) keeps thread + FD pressure from
    // accumulating as the test suite grows. POSIX `usleep`
    // rejects values >= 1_000_000 with EINVAL; loop in 500 ms
    // slices.
    var slept_ms: u32 = 0;
    while (slept_ms < 10_000) : (slept_ms += 500) {
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
    // Use page_allocator (not testing.allocator) for the
    // Threaded IO instance: the timeout path intentionally
    // detaches the HTTP sub-thread, which keeps using this `io`
    // long after the test returns. Tying its lifetime to the
    // test process (via page_allocator + no `deinit`) avoids a
    // UAF when the orphaned thread eventually completes — the
    // testing.allocator + defer-deinit pattern used elsewhere
    // would tear down `io` while the orphan still holds a
    // pointer to it.
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
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
