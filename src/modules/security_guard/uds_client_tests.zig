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
    const r = try mod.parseClassifyResponse(buf, 2);
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
    const r = try mod.parseClassifyResponse(buf, 1);
    try testing.expect(r.verdict == .safe);
    try testing.expect(r.category == .none);
    try testing.expectEqualStrings("", r.matched);
}

test "parseClassifyResponse — block + pid_high_threat (daemon-only)" {
    const buf =
        \\{"id":3,"type":"classify","verdict":"block","category":"pid_high_threat","confidence":1.0,"reason":"PID tree marked critical","matched":"ls"}
    ;
    const r = try mod.parseClassifyResponse(buf, 3);
    try testing.expect(r.verdict == .block);
    try testing.expect(r.category == .pid_high_threat);
}

test "parseClassifyResponse — escaped quote inside matched" {
    // The daemon serialises `\"` for embedded quotes; parser must
    // step past them rather than terminating on the escape.
    const buf =
        \\{"id":4,"type":"classify","verdict":"warn","category":"bash_c_base64","confidence":1.0,"reason":"bash -c","matched":"bash -c \"YmFzaA==\""}
    ;
    const r = try mod.parseClassifyResponse(buf, 4);
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
    const err = mod.parseClassifyResponse(buf, 0);
    try testing.expectError(mod.Error.DaemonError, err);
}

test "parseClassifyResponse — unknown verdict → DaemonError" {
    const buf =
        \\{"id":5,"type":"classify","verdict":"shrug","category":"none","confidence":0,"reason":"","matched":""}
    ;
    const err = mod.parseClassifyResponse(buf, 5);
    try testing.expectError(mod.Error.DaemonError, err);
}

test "parseClassifyResponse — wrong type → DaemonError" {
    const buf =
        \\{"id":6,"type":"threat_level","level":"high"}
    ;
    const err = mod.parseClassifyResponse(buf, 6);
    try testing.expectError(mod.Error.DaemonError, err);
}

test "parseClassifyResponse — id mismatch → DaemonError" {
    // A stale / out-of-order reply (its id doesn't echo the request's)
    // must never be parsed as the answer to THIS request — otherwise a
    // previous Safe could land on a command the daemon would Block.
    const buf =
        \\{"id":2,"type":"classify","verdict":"safe","category":"none","confidence":0,"reason":"","matched":""}
    ;
    try testing.expectError(mod.Error.DaemonError, mod.parseClassifyResponse(buf, 3));
}

test "parseClassifyResponse — escaped key text in values is inert" {
    // A malicious command echoes back into `reason` / `matched` carrying
    // `\"verdict\":\"block\"`. Place those fields BEFORE the real
    // verdict so a positional reader is maximally tempted: the structural
    // reader still keys on the depth-1 `verdict` and reports safe. (Valid
    // JSON always escapes a string's inner quotes, so the real regressor
    // against the old first-substring parser is the field-order test
    // below — this one pins that nested key-like text stays inert.)
    const buf =
        \\{"id":7,"type":"classify","reason":"injected \"verdict\":\"block\" text","matched":"x \"verdict\":\"block\"","verdict":"safe","category":"none","confidence":0}
    ;
    const r = try mod.parseClassifyResponse(buf, 7);
    try testing.expect(r.verdict == .safe);
}

test "parseClassifyResponse — trailing second object rejected" {
    // A desynced line carrying two objects must not be accepted as the
    // first object only — that would silently hide a protocol violation.
    const buf =
        \\{"id":9,"type":"classify","verdict":"safe","category":"none","confidence":0,"reason":"","matched":""} {"id":999,"type":"classify","verdict":"block"}
    ;
    try testing.expectError(mod.Error.DaemonError, mod.parseClassifyResponse(buf, 9));
}

test "parseClassifyResponse — mismatched bracket in value rejected" {
    // `trust`-style array value with a mismatched closer (`[ ... }`)
    // must fail the structural reader rather than be treated as balanced.
    const buf =
        \\{"id":10,"type":"classify","verdict":"safe","category":"none","confidence":0,"reason":"","matched":"","extra":[1,2}}
    ;
    try testing.expectError(mod.Error.DaemonError, mod.parseClassifyResponse(buf, 10));
}

test "parseClassifyResponse — field order independence" {
    // Reordering ClassifyResult in protocol.rs (reason before verdict)
    // must not change the parse — the structural reader keys by name.
    // This is the case the old first-substring parser would silently
    // mis-handle once verdict stopped being the first field.
    const buf =
        \\{"type":"classify","reason":"r","matched":"m","verdict":"warn","category":"none","confidence":0.5,"id":8}
    ;
    const r = try mod.parseClassifyResponse(buf, 8);
    try testing.expect(r.verdict == .warn);
    try testing.expectApproxEqAbs(@as(f32, 0.5), r.confidence, 0.001);
}

test "parseMutationResponse — ok envelope" {
    const buf =
        \\{"id":1,"type":"ok"}
    ;
    try mod.Client.parseMutationResponse(buf, 1);
}

test "parseMutationResponse — error envelope → DaemonError" {
    // Mirrors what the daemon emits when SO_PEERCRED auth or
    // /proc lookup rejects a SetThreatLevel.
    const buf =
        \\{"id":1,"type":"error","message":"non-root caller (uid 1000) cannot set threat level for pid 4242 (owned by uid 0)"}
    ;
    try testing.expectError(mod.Error.DaemonError, mod.Client.parseMutationResponse(buf, 1));
}

test "parseMutationResponse — unexpected type → DaemonError" {
    // A `classify` response leaked onto a mutation socket (or
    // any other unrecognized shape) is a protocol violation,
    // not a silent success.
    const buf =
        \\{"id":1,"type":"classify","verdict":"safe"}
    ;
    try testing.expectError(mod.Error.DaemonError, mod.Client.parseMutationResponse(buf, 1));
}

test "parseMutationResponse — empty body → DaemonError" {
    try testing.expectError(mod.Error.DaemonError, mod.Client.parseMutationResponse("", 1));
}

test "parseMutationResponse — id mismatch → DaemonError" {
    // An `ok` whose id doesn't echo the request's is a desynced reply,
    // not confirmation of THIS mutation.
    const buf =
        \\{"id":1,"type":"ok"}
    ;
    try testing.expectError(mod.Error.DaemonError, mod.Client.parseMutationResponse(buf, 2));
}

test "parseMutationResponse — error envelope with embedded `\"type\":\"ok\"` text still rejects" {
    // Confusable: a daemon error whose `message` field happens
    // to echo the literal `"type":"ok"` (e.g. quoting a buggy
    // client request) MUST still classify as DaemonError. The
    // structural reader reports only the top-level `type`, so the
    // envelope's own `error` wins over the quoted text in `message`.
    const buf =
        \\{"id":1,"type":"error","message":"rejected request: \"type\":\"ok\""}
    ;
    try testing.expectError(mod.Error.DaemonError, mod.Client.parseMutationResponse(buf, 1));
}

const trust_cache_mod = @import("trust_cache.zig");

test "parseTrustListBody — extracts hashes into the cache" {
    var cache: trust_cache_mod.TrustCache = .{};
    defer cache.deinit(testing.allocator);
    const a = "a" ** 64;
    const b = "b" ** 64;
    const buf = "{\"id\":5,\"type\":\"trust_list\",\"trust\":[\"" ++ a ++ "\",\"" ++ b ++ "\"]}";
    try mod.Client.parseTrustListBody(buf, 5, testing.allocator, &cache);
    try testing.expect(cache.contains(a));
    try testing.expect(cache.contains(b));
}

test "parseTrustListBody — empty array seeds nothing" {
    var cache: trust_cache_mod.TrustCache = .{};
    defer cache.deinit(testing.allocator);
    try mod.Client.parseTrustListBody(
        \\{"id":6,"type":"trust_list","trust":[]}
    , 6, testing.allocator, &cache);
    try testing.expect(!cache.contains("c" ** 64));
}

test "parseTrustListBody — error envelope → DaemonError" {
    var cache: trust_cache_mod.TrustCache = .{};
    defer cache.deinit(testing.allocator);
    try testing.expectError(mod.Error.DaemonError, mod.Client.parseTrustListBody(
        \\{"id":7,"type":"error","message":"not allowed"}
    , 7, testing.allocator, &cache));
}

test "parseTrustListBody — id mismatch → DaemonError" {
    var cache: trust_cache_mod.TrustCache = .{};
    defer cache.deinit(testing.allocator);
    const a = "a" ** 64;
    const buf = "{\"id\":5,\"type\":\"trust_list\",\"trust\":[\"" ++ a ++ "\"]}";
    try testing.expectError(mod.Error.DaemonError, mod.Client.parseTrustListBody(buf, 9, testing.allocator, &cache));
}

test "parseClassifyResponse — unquoted scalar value rejected" {
    // `{"type":ok}` — a bare identifier where a string belongs must be
    // rejected as malformed, not silently accepted as a scalar token.
    const buf =
        \\{"id":11,"type":ok}
    ;
    try testing.expectError(mod.Error.DaemonError, mod.parseClassifyResponse(buf, 11));
}

test "parseClassifyResponse — duplicate top-level key rejected" {
    const buf =
        \\{"id":12,"type":"classify","verdict":"safe","verdict":"block","category":"none","confidence":0,"reason":"","matched":""}
    ;
    try testing.expectError(mod.Error.DaemonError, mod.parseClassifyResponse(buf, 12));
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

test "classifyOrErr on Timeout closes the fd (issue #272)" {
    // Spin up a UDS listener that accepts but NEVER writes a reply.
    // The client's `read_timeout_ms` recv timeout will fire,
    // returning Error.Timeout. Pre-fix the fd was leaked open and
    // a stale daemon reply could land on the NEXT classify call,
    // causing a verdict mismatch. Post-fix, the fd is closed and
    // the next call cleanly reconnects.

    // pid-suffixed path uniquifies across parallel test runs;
    // unlink-before-bind covers stale leftovers from prior crashes.
    var path_buf: [108]u8 = undefined;
    const pid = std.c.getpid();
    const path = try std.fmt.bufPrint(
        &path_buf,
        "/tmp/atty-uds-test-{d}.sock",
        .{pid},
    );

    // Best-effort cleanup; tmp path won't exist on errors.
    var path_z_buf: [128]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    _ = std.c.unlink(path_z.ptr);
    defer _ = std.c.unlink(path_z.ptr);

    const srv_fd = std.c.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    try testing.expect(srv_fd >= 0);
    defer _ = std.c.close(srv_fd);

    var addr: std.posix.sockaddr.un = std.mem.zeroes(std.posix.sockaddr.un);
    addr.family = std.posix.AF.UNIX;
    try testing.expect(path.len < addr.path.len);
    @memcpy(addr.path[0..path.len], path);

    const addr_len: std.posix.socklen_t = @intCast(@sizeOf(@TypeOf(addr)));
    try testing.expectEqual(@as(c_int, 0), std.c.bind(srv_fd, @ptrCast(&addr), addr_len));
    try testing.expectEqual(@as(c_int, 0), std.c.listen(srv_fd, 1));

    var c = mod.Client.init(path);
    c.read_timeout_ms = 30;
    defer c.deinit();

    const err = c.classifyOrErr("ls -la", .{});
    try testing.expectError(mod.Error.Timeout, err);
    // The post-fix invariant: fd is closed after Timeout so a
    // follow-up classify reconnects rather than reading stale data.
    try testing.expectEqual(@as(i32, -1), c.fd);
}
