const std = @import("std");
const testing = std.testing;
const anon = @import("debug_anonymize.zig");
const report = @import("debug_report.zig");
const rec = @import("debug_recorder.zig");

test "scrub: literal env replacements + pattern redaction" {
    const a = testing.allocator;
    const opts = anon.ScrubOpts{ .home = "/home/alice", .user = "alice", .host = "devbox" };
    const cases = .{
        .{ "/home/alice/secret.txt", "~/secret.txt" },
        .{ "logged in as alice on devbox", "logged in as USER on HOST" },
        .{ "mail bob@example.com now", "mail [EMAIL] now" },
        .{ "connect 192.168.1.42 ok", "connect [IP] ok" },
        .{ "tok=eyJhdr.eyJpayload012345.sigABC done", "tok=[REDACTED] done" },
        .{ "key AKIA1234567890ABCDEFGHIJ end", "key [REDACTED] end" },
        .{ "hello world 1.2.3 v4", "hello world 1.2.3 v4" }, // untouched: short, 3-octet, no long run
    };
    inline for (cases) |c| {
        const got = try anon.scrub(a, c[0], opts);
        defer a.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "scrub: short user/host names are not mangled" {
    const a = testing.allocator;
    // user "al" (<3) must not turn every "al" into USER.
    const got = try anon.scrub(a, "alpha always all", .{ .home = "", .user = "al", .host = "" });
    defer a.free(got);
    try testing.expectEqualStrings("alpha always all", got);
}

test "anonymize: scrubbed report stays valid JSON with the secret gone" {
    const a = testing.allocator;
    const json =
        \\{"atty_version":"1.0","terminal":{"cols":80,"rows":24},"streams":[[0.0,"in","export TOKEN=AKIA1234567890ABCDEFGHIJ"]]}
    ;
    const scrubbed = try anon.scrub(a, json, .{});
    defer a.free(scrubbed);
    try testing.expect(std.mem.indexOf(u8, scrubbed, "AKIA1234567890ABCDEFGHIJ") == null);
    try testing.expect(std.mem.indexOf(u8, scrubbed, "[REDACTED]") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, scrubbed, .{});
    defer parsed.deinit();
}

// run() writes to fd 1 (the `zig build test` IPC channel) → redirect to /dev/null.
extern "c" fn dup(fd: c_int) c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;

test "anonymize run: exit codes + happy path" {
    const a = testing.allocator;
    try testing.expectEqual(@as(u8, 2), anon.run(a, &.{})); // no verb
    try testing.expectEqual(@as(u8, 2), anon.run(a, &.{"frob"})); // unknown verb
    try testing.expectEqual(@as(u8, 2), anon.run(a, &.{"anonymize"})); // missing path
    try testing.expectEqual(@as(u8, 1), anon.run(a, &.{ "anonymize", "/no/such-xyz.json" })); // unreadable

    var r = try rec.Recorder.init(a, 4096);
    defer r.deinit();
    r.push(.term, 0, "hi\n");
    const path = try report.save(a, "/tmp/atty-anon-selftest", .{
        .atty_version = "t",
        .cols = 4,
        .rows = 2,
        .term = "",
        .shell = "",
        .lang = "",
        .line_buffer = "",
        .line_cursor = 0,
        .line_uncertain = false,
        .incognito = false,
    }, &r);
    defer a.free(path);
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    defer _ = unlink(path_z.ptr);

    const O_WRONLY: c_int = @bitCast(std.posix.O{ .ACCMODE = .WRONLY });
    const devnull = open("/dev/null", O_WRONLY);
    if (devnull < 0) return error.OpenFailed;
    const saved = dup(1);
    defer {
        _ = dup2(saved, 1);
        _ = std.c.close(saved);
        _ = std.c.close(devnull);
    }
    _ = dup2(devnull, 1);
    try testing.expectEqual(@as(u8, 0), anon.run(a, &.{ "anonymize", path }));
    try testing.expectEqual(@as(u8, 0), anon.run(a, &.{ "to-cast", path }));
    try testing.expectEqual(@as(u8, 0), anon.run(a, &.{ "to-cast", path, "--stream", "term" }));
}
