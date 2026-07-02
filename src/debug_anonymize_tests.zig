const std = @import("std");
const testing = std.testing;
const anon = @import("debug_anonymize.zig");
const report = @import("debug_report.zig");
const rec = @import("debug_recorder.zig");
const replay = @import("debug_replay.zig");

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
        const got = try anon.scrub(a, c[0], opts, false);
        defer a.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "scrub: short user/host names are not mangled" {
    const a = testing.allocator;
    // user "al" (<3) must not turn every "al" into USER.
    const got = try anon.scrub(a, "alpha always all", .{ .home = "", .user = "al", .host = "" }, false);
    defer a.free(got);
    try testing.expectEqualStrings("alpha always all", got);
}

test "anonymize: scrubbed report stays valid JSON with the secret gone" {
    const a = testing.allocator;
    const json =
        \\{"atty_version":"1.0","terminal":{"cols":80,"rows":24},"streams":[[0.0,"in","export TOKEN=AKIA1234567890ABCDEFGHIJ"]]}
    ;
    const scrubbed = try anon.scrub(a, json, .{}, true);
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
    try testing.expectEqual(@as(u8, 2), anon.run(a, &.{ "anonymize", "x.json", "--stream", "term" })); // --stream is to-cast-only

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
    try testing.expectEqual(@as(u8, 0), anon.run(a, &.{"help"})); // help → stdout, exit 0
}

test "anonymize: a token right after a JSON escape stays valid JSON" {
    const a = testing.allocator;
    // The \n escape abuts a 23-char token — the pre-fix scanner orphaned the \.
    const json =
        \\{"streams":[[0.0,"term","x\ndeadbeefcafebabe1234567 done"]]}
    ;
    const scrubbed = try anon.scrub(a, json, .{}, true);
    defer a.free(scrubbed);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, scrubbed, .{}); // valid JSON
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, scrubbed, "deadbeefcafebabe1234567") == null); // token redacted
    try testing.expect(std.mem.indexOf(u8, scrubbed, "\\n") != null); // escape preserved
}

test "to-cast emits a valid asciinema v2 header + event" {
    const a = testing.allocator;
    var r = try rec.Recorder.init(a, 4096);
    defer r.deinit();
    r.push(.term, 0, "hi\x1b[K caf\xc3\xa9\n"); // includes a multibyte UTF-8 char (é)
    const path = try report.save(a, "/tmp/atty-anon-cast", .{
        .atty_version = "t",
        .cols = 40,
        .rows = 10,
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

    const outpath = "/tmp/atty-anon-cast-out.txt";
    const O_WR: c_int = @bitCast(std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true });
    const ofd = open(outpath, O_WR, @as(std.c.mode_t, 0o600));
    if (ofd < 0) return error.OpenFailed;
    const saved = dup(1);
    _ = dup2(ofd, 1);
    const code = anon.run(a, &.{ "to-cast", path });
    _ = dup2(saved, 1);
    _ = std.c.close(saved);
    _ = std.c.close(ofd);
    try testing.expectEqual(@as(u8, 0), code);

    const cast = try replay.readFile(a, outpath);
    defer a.free(cast);
    defer _ = unlink("/tmp/atty-anon-cast-out.txt");
    try testing.expect(std.mem.startsWith(u8, cast, "{\"version\":2,\"width\":40,\"height\":10"));
    try testing.expect(std.mem.indexOf(u8, cast, "[0.000, \"o\", \"") != null);
    // Valid multibyte UTF-8 passes through raw (not latin-1 \u-escaped).
    try testing.expect(std.mem.indexOf(u8, cast, "caf\xc3\xa9") != null);
    try testing.expect(std.mem.indexOf(u8, cast, "\\u00c3") == null);
    // ...but the cast is still valid JSON (each event line parses).
    const l0 = std.mem.indexOfScalar(u8, cast, '\n').?;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, cast[l0 + 1 .. std.mem.indexOfScalarPos(u8, cast, l0 + 1, '\n').?], .{});
    parsed.deinit();
}

test "anonymize: a hex user value cannot corrupt a JSON u-escape" {
    const a = testing.allocator;
    // A JSON \u escape whose hex body a pure-hex USER value overlaps.
    const json = "{\"streams\":[[0.0,\"term\",\"x\\u000ey\"]]}";
    const scrubbed = try anon.scrub(a, json, .{ .user = "000e" }, true);
    defer a.free(scrubbed);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, scrubbed, .{}); // still valid JSON
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, scrubbed, "\\u000e") != null); // escape untouched
}
