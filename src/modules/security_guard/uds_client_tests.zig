const std = @import("std");
const testing = std.testing;
const mod = @import("uds_client.zig");

test "Verdict.fromString round-trip" {
    try testing.expect(mod.Verdict.fromString("safe") == .safe);
    try testing.expect(mod.Verdict.fromString("warn") == .warn);
    try testing.expect(mod.Verdict.fromString("block") == .block);
    try testing.expect(mod.Verdict.fromString("bogus") == null);
    try testing.expect(mod.Verdict.fromString("") == null);
}

test "Category.fromString + toLocal" {
    try testing.expect(mod.Category.fromString("curl_pipe_sh") == .curl_pipe_sh);
    try testing.expect(mod.Category.fromString("npm_unsafe_install") == .npm_unsafe_install);
    try testing.expect(mod.Category.fromString("bash_c_base64") == .bash_c_base64);
    try testing.expect(mod.Category.fromString("pid_high_threat") == .pid_high_threat);
    try testing.expect(mod.Category.fromString("none") == .none);
    try testing.expect(mod.Category.fromString("unknown") == null);

    // pid_high_threat has no in-proc equivalent.
    try testing.expect(mod.Category.pid_high_threat.toLocal() == null);
    try testing.expect(mod.Category.curl_pipe_sh.toLocal().? == .curl_pipe_sh);
}

test "parseClassifyResponse — full Tier-1 hit" {
    const buf =
        \\{"id":2,"type":"classify","verdict":"warn","category":"curl_pipe_sh","confidence":1.0,"reason":"remote-fetch-and-execute","matched":"curl x | sh"}
    ;
    const r = try mod.parseClassifyResponse(buf);
    try testing.expect(r.verdict == .warn);
    try testing.expect(r.category == .curl_pipe_sh);
    try testing.expectApproxEqAbs(@as(f32, 1.0), r.confidence, 0.001);
    try testing.expectEqualStrings("remote-fetch-and-execute", r.reason);
    try testing.expectEqualStrings("curl x | sh", r.matched);
}

test "parseClassifyResponse — safe verdict, empty matched" {
    const buf =
        \\{"id":1,"type":"classify","verdict":"safe","category":"none","confidence":0.0,"reason":"","matched":""}
    ;
    const r = try mod.parseClassifyResponse(buf);
    try testing.expect(r.verdict == .safe);
    try testing.expect(r.category == .none);
    try testing.expectEqualStrings("", r.matched);
}

test "parseClassifyResponse — block + pid_high_threat (daemon-only)" {
    const buf =
        \\{"id":3,"type":"classify","verdict":"block","category":"pid_high_threat","confidence":1.0,"reason":"PID tree marked critical","matched":"ls"}
    ;
    const r = try mod.parseClassifyResponse(buf);
    try testing.expect(r.verdict == .block);
    try testing.expect(r.category == .pid_high_threat);
}

test "parseClassifyResponse — escaped quote inside matched" {
    // The daemon serialises `\"` for embedded quotes; parser must
    // step past them rather than terminating on the escape.
    const buf =
        \\{"id":4,"type":"classify","verdict":"warn","category":"bash_c_base64","confidence":1.0,"reason":"bash -c","matched":"bash -c \"YmFzaA==\""}
    ;
    const r = try mod.parseClassifyResponse(buf);
    try testing.expect(r.verdict == .warn);
    // Embedded escape stays in the slice — caller can unescape if
    // it cares; for our purposes (banner display + hash) it's fine
    // as-is.
    try testing.expect(std.mem.indexOf(u8, r.matched, "YmFzaA==") != null);
}

test "parseClassifyResponse — error envelope → DaemonError" {
    const buf =
        \\{"id":0,"type":"error","message":"invalid request"}
    ;
    const err = mod.parseClassifyResponse(buf);
    try testing.expectError(mod.Error.DaemonError, err);
}

test "parseClassifyResponse — unknown verdict → DaemonError" {
    const buf =
        \\{"id":5,"type":"classify","verdict":"shrug","category":"none","confidence":0,"reason":"","matched":""}
    ;
    const err = mod.parseClassifyResponse(buf);
    try testing.expectError(mod.Error.DaemonError, err);
}

test "parseClassifyResponse — wrong type → DaemonError" {
    const buf =
        \\{"id":6,"type":"threat_level","level":"high"}
    ;
    const err = mod.parseClassifyResponse(buf);
    try testing.expectError(mod.Error.DaemonError, err);
}

test "Client.init constructs without connecting" {
    var c = mod.Client.init("/nonexistent.sock");
    defer c.deinit();
    try testing.expectEqual(@as(i32, -1), c.fd);
}

test "Client.classifyOrErr on missing socket → Unavailable" {
    var c = mod.Client.init("/tmp/atty-guard-nonexistent-XYZ.sock");
    defer c.deinit();
    const err = c.classifyOrErr("anything", .{});
    try testing.expectError(mod.Error.Unavailable, err);
}

test "Client.health on missing socket → false (doesn't panic)" {
    var c = mod.Client.init("/tmp/atty-guard-nonexistent-XYZ.sock");
    defer c.deinit();
    try testing.expect(!c.health());
}

test "buildClassifyJson — empty context emits empty context object" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try mod.buildClassifyJson(&w, 7, "ls -la", .{});
    const out = buf[0..w.end];
    try testing.expectEqualStrings(
        "{\"id\":7,\"method\":\"classify\",\"command\":\"ls -la\",\"context\":{}}\n",
        out,
    );
}

test "buildClassifyJson — pid forwarded into wire envelope" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try mod.buildClassifyJson(&w, 7, "rm -rf /", .{ .pid = 4242 });
    const out = buf[0..w.end];
    try testing.expectEqualStrings(
        "{\"id\":7,\"method\":\"classify\",\"command\":\"rm -rf /\",\"context\":{\"pid\":4242}}\n",
        out,
    );
}

test "buildClassifyJson — pid + incognito both forwarded" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try mod.buildClassifyJson(&w, 7, "cmd", .{ .pid = 4242, .incognito = true });
    const out = buf[0..w.end];
    try testing.expectEqualStrings(
        "{\"id\":7,\"method\":\"classify\",\"command\":\"cmd\",\"context\":{\"pid\":4242,\"incognito\":true}}\n",
        out,
    );
}

test "buildClassifyJson — incognito only (no pid)" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try mod.buildClassifyJson(&w, 7, "cmd", .{ .incognito = true });
    const out = buf[0..w.end];
    try testing.expectEqualStrings(
        "{\"id\":7,\"method\":\"classify\",\"command\":\"cmd\",\"context\":{\"incognito\":true}}\n",
        out,
    );
}
