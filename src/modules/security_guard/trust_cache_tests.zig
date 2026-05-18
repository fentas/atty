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
