const std = @import("std");
const testing = std.testing;
const mod = @import("trust_cache.zig");
const patterns = @import("patterns.zig");

test "hashCategoryMatch is deterministic + 64 hex chars" {
    var out1: [mod.hex_len]u8 = undefined;
    var out2: [mod.hex_len]u8 = undefined;
    const h1 = mod.hashCategoryMatch(.curl_pipe_sh, "curl x|sh", &out1);
    const h2 = mod.hashCategoryMatch(.curl_pipe_sh, "curl x|sh", &out2);
    try testing.expectEqual(@as(usize, mod.hex_len), h1.len);
    try testing.expectEqualSlices(u8, h1, h2);
}

test "hashCategoryMatch — category changes the digest" {
    var out1: [mod.hex_len]u8 = undefined;
    var out2: [mod.hex_len]u8 = undefined;
    const h1 = mod.hashCategoryMatch(.curl_pipe_sh, "x", &out1);
    const h2 = mod.hashCategoryMatch(.npm_unsafe_install, "x", &out2);
    try testing.expect(!std.mem.eql(u8, h1, h2));
}

test "TrustCache: add + contains roundtrip" {
    var cache: mod.TrustCache = .{};
    defer cache.deinit(testing.allocator);

    var hash_buf: [mod.hex_len]u8 = undefined;
    const hash = mod.hashCategoryMatch(.bash_c_base64, "abc", &hash_buf);

    try testing.expect(!cache.contains(hash));
    const added = try cache.add(testing.allocator, hash);
    try testing.expect(added);
    try testing.expect(cache.contains(hash));

    // Re-adding the same hash returns false (no duplicate).
    const re_added = try cache.add(testing.allocator, hash);
    try testing.expect(!re_added);
    try testing.expectEqual(@as(usize, 1), cache.entries.items.len);
}

test "TrustCache: contains rejects wrong length" {
    var cache: mod.TrustCache = .{};
    defer cache.deinit(testing.allocator);

    var hash_buf: [mod.hex_len]u8 = undefined;
    const hash = mod.hashCategoryMatch(.curl_pipe_sh, "x", &hash_buf);
    _ = try cache.add(testing.allocator, hash);

    // Shorter / longer strings shouldn't match.
    try testing.expect(!cache.contains(hash[0..32]));
    try testing.expect(!cache.contains("nope"));
}

test "TrustCache: load skips invalid lines, keeps valid ones" {
    const path = "/tmp/atty-secguard-test-load-mixed.txt";
    _ = std.c.unlink(path);
    defer _ = std.c.unlink(path);

    // Write a file with 2 valid + 3 invalid lines.
    const fd = std.c.open(path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, @as(std.c.mode_t, 0o644));
    try testing.expect(fd >= 0);
    const content =
        "abc\n" ++ // too short
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++ // valid 1
        "ZZ\n" ++ // wrong length
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++ // valid 2
        "0123456789abcdefghijklmnopqrstuvwxyz...not_hex_at_all............\n"; // not hex
    _ = std.c.write(fd, content.ptr, content.len);
    _ = std.c.close(fd);

    var cache: mod.TrustCache = .{};
    defer cache.deinit(testing.allocator);
    try cache.load(testing.allocator, path);

    try testing.expectEqual(@as(usize, 2), cache.entries.items.len);
    try testing.expect(cache.contains("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try testing.expect(cache.contains("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"));
}

test "TrustCache: persist + load round-trip" {
    const path = "/tmp/atty-secguard-test-roundtrip.txt";
    _ = std.c.unlink(path);
    defer _ = std.c.unlink(path);

    var cache1: mod.TrustCache = .{};
    defer cache1.deinit(testing.allocator);

    var hash_buf1: [mod.hex_len]u8 = undefined;
    var hash_buf2: [mod.hex_len]u8 = undefined;
    const h1 = mod.hashCategoryMatch(.curl_pipe_sh, "curl x | sh", &hash_buf1);
    const h2 = mod.hashCategoryMatch(.npm_unsafe_install, "npm install event-stream", &hash_buf2);
    _ = try cache1.add(testing.allocator, h1);
    _ = try cache1.add(testing.allocator, h2);
    try cache1.persist(path);

    // Re-read from disk.
    var cache2: mod.TrustCache = .{};
    defer cache2.deinit(testing.allocator);
    try cache2.load(testing.allocator, path);
    try testing.expectEqual(@as(usize, 2), cache2.entries.items.len);
    try testing.expect(cache2.contains(h1));
    try testing.expect(cache2.contains(h2));
}
