const std = @import("std");
const testing = std.testing;
const mod = @import("detect.zig");

const find = mod.find;
const Hit = mod.Hit;
const Options = mod.Options;
const default: Options = .{};

fn expectHit(line: []const u8, col: u16, url: []const u8, host: []const u8, scheme: []const u8) !void {
    const hit = find(line, col, default) orelse {
        std.debug.print("no URL hit at col={d} in {s}\n", .{ col, line });
        return error.TestExpectedHit;
    };
    try testing.expectEqualStrings(url, hit.url);
    try testing.expectEqualStrings(host, hit.host);
    try testing.expectEqualStrings(scheme, hit.scheme);
}

fn expectMiss(line: []const u8, col: u16) !void {
    if (find(line, col, default) != null) {
        std.debug.print("expected miss at col={d} in {s}\n", .{ col, line });
        return error.TestExpectedMiss;
    }
}

test "plain https" {
    try expectHit("https://example.com/foo", 5, "https://example.com/foo", "example.com", "https");
}

test "http" {
    try expectHit("http://example.com", 5, "http://example.com", "example.com", "http");
}

test "URL with path query and fragment" {
    try expectHit(
        "https://example.com/path?q=1&r=2#section",
        10,
        "https://example.com/path?q=1&r=2#section",
        "example.com",
        "https",
    );
}

test "URL preceded by prose" {
    try expectHit(
        "see https://example.com/x for details",
        6,
        "https://example.com/x",
        "example.com",
        "https",
    );
}

test "trailing period stripped" {
    try expectHit(
        "Open https://example.com.",
        7,
        "https://example.com",
        "example.com",
        "https",
    );
}

test "matched parens stripped from wrapper" {
    try expectHit(
        "(see https://example.com/x)",
        7,
        "https://example.com/x",
        "example.com",
        "https",
    );
}

test "parens inside URL preserved" {
    try expectHit(
        "https://en.wikipedia.org/wiki/Foo_(bar)",
        10,
        "https://en.wikipedia.org/wiki/Foo_(bar)",
        "en.wikipedia.org",
        "https",
    );
}

test "URL with port" {
    try expectHit(
        "http://localhost:8080/api",
        5,
        "http://localhost:8080/api",
        "localhost:8080",
        "http",
    );
}

test "URL with user:pass strips userinfo from host" {
    try expectHit(
        "https://user:pass@example.com/x",
        5,
        "https://user:pass@example.com/x",
        "example.com",
        "https",
    );
}

test "click outside URL run is miss" {
    try expectMiss("Open https://example.com today", 1);
    try expectMiss("Open https://example.com today", 26);
}

test "multiple URLs — picks the one under the click" {
    try expectHit(
        "see https://a.com and https://b.com",
        24,
        "https://b.com",
        "b.com",
        "https",
    );
}

test "scheme not in allow-list rejected" {
    try expectMiss("javascript://alert(1)", 5);
}

test "explicit accept_schemes restricts" {
    const opts: Options = .{ .accept_schemes = &.{"https"} };
    const hit = find("http://example.com", 5, opts);
    try testing.expect(hit == null);
}

test "case insensitive scheme" {
    try expectHit(
        "HTTPS://Example.COM/x",
        5,
        "HTTPS://Example.COM/x",
        "Example.COM",
        "HTTPS",
    );
}

test "URL in angle brackets is bounded" {
    // RFC 3986 style <URL> bracketing; the `<` and `>` are
    // terminators, not part of the URL.
    try expectHit(
        "see <https://example.com/x>",
        10,
        "https://example.com/x",
        "example.com",
        "https",
    );
}

test "trailing semicolon stripped" {
    try expectHit("https://example.com;", 5, "https://example.com", "example.com", "https");
}

test "URL with backtick rejected mid-token" {
    // backtick is a terminator
    try expectHit(
        "see https://a.com `b`",
        6,
        "https://a.com",
        "a.com",
        "https",
    );
}

test "URL at end of line no terminator" {
    try expectHit(
        "go to https://api.example.com/v2",
        10,
        "https://api.example.com/v2",
        "api.example.com",
        "https",
    );
}

test "ssh URL" {
    try expectHit(
        "git clone ssh://git@github.com/u/r.git",
        15,
        "ssh://git@github.com/u/r.git",
        "github.com",
        "ssh",
    );
}

test "git URL" {
    try expectHit(
        "git://git.example.org/repo",
        5,
        "git://git.example.org/repo",
        "git.example.org",
        "git",
    );
}

test "file:/// URL miss — empty host is not a trust target" {
    // `file:///path` lacks a host for trust-store lookup. mouse_urls
    // skips it; mouse_links would handle the `/etc/passwd` portion
    // via its path detector if the user clicked there instead.
    try expectMiss("open file:///etc/passwd", 7);
}

test "file://host/ URL hit" {
    try expectHit(
        "file://share.local/etc/passwd",
        10,
        "file://share.local/etc/passwd",
        "share.local",
        "file",
    );
}

test "empty line" {
    try expectMiss("", 1);
}

test "col 0 rejected" {
    try expectMiss("https://example.com", 0);
}

test "click past line length rejected" {
    try expectMiss("https://example.com", 100);
}

test "scheme prefix without `://` is not a URL" {
    try expectMiss("https:foo", 3);
}

test "fragment-only doesn't break host extraction" {
    try expectHit(
        "https://example.com#top",
        5,
        "https://example.com#top",
        "example.com",
        "https",
    );
}

test "quoted URL strips the quote" {
    try expectHit(
        "got \"https://example.com\" today",
        10,
        "https://example.com",
        "example.com",
        "https",
    );
}

test "percent-encoded path preserved" {
    try expectHit(
        "https://example.com/path%20with%20spaces",
        10,
        "https://example.com/path%20with%20spaces",
        "example.com",
        "https",
    );
}

test "IPv6 literal — host slice includes brackets" {
    // RFC 3986 §3.2.2: IPv6 lives inside `[]` so the `:` between
    // segments isn't confused with the port `:`. Detector captures
    // the brackets verbatim; trust-store comparison is up to the
    // module wrapper (mouse_urls.stripPort handles `[::1]:8080`).
    try expectHit(
        "see http://[::1]:8080/api",
        15,
        "http://[::1]:8080/api",
        "[::1]:8080",
        "http",
    );
}

test "OAuth-style URL with commas in query string" {
    // Commas inside `?` should be preserved; only trailing-prose
    // commas get stripped.
    try expectHit(
        "see https://example.com/cb?state=a,b,c then",
        10,
        "https://example.com/cb?state=a,b,c",
        "example.com",
        "https",
    );
}
