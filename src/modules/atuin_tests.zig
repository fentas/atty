//! Tests for `modules/atuin.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("atuin.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const m = @import("../module.zig");
const lib = @import("_lib.zig");
const subprocess_mod = @import("../subprocess.zig");
const nowMs = lib.nowMs;

// Re-binds of pub decls so test bodies stay short.
const Backend = mod.Backend;
const Config = mod.Config;
const configure = mod.configure;
const DeleteScope = mod.DeleteScope;
const FilterMode = mod.FilterMode;
const SearchMode = mod.SearchMode;

// ===========================================================================
// Tests
// ===========================================================================

const test_io: std.Io = std.Io.failing;

test "configure exposes Runtime + hooks" {
    const A = configure(.{});
    try testing.expect(@hasDecl(A, "Runtime"));
    try testing.expect(@hasDecl(A, "onInput"));
    try testing.expect(@hasDecl(A, "provideGhostText"));
    try testing.expect(@hasDecl(A, "onTick"));
    try testing.expectEqualStrings("atuin", A.name);
}

test "configure with socket backend swaps the lookup arm" {
    const A = configure(.{ .backend = .socket, .socket_path = "/tmp/nope" });
    try testing.expect(A.config.backend == .socket);
}

test "configure carries delete_scope through to A.config (default exact)" {
    // Default is .exact so Ctrl+Shift+D only removes the typed line —
    // atuin's CLI has no exact-match search mode but fuzzy + `^...$`
    // anchors get us there. Test pins the surface so renames or
    // removals are caught here, not in the field.
    const A1 = configure(.{});
    try testing.expectEqual(DeleteScope.exact, A1.config.delete_scope);
    const A2 = configure(.{ .delete_scope = .prefix });
    try testing.expectEqual(DeleteScope.prefix, A2.config.delete_scope);
    const A3 = configure(.{ .delete_scope = .full_text });
    try testing.expectEqual(DeleteScope.full_text, A3.config.delete_scope);
    const A4 = configure(.{ .delete_scope = .fuzzy });
    try testing.expectEqual(DeleteScope.fuzzy, A4.config.delete_scope);
}

test "buildRecordArgv: user line, tagging off → no --author, no --cwd" {
    const A = configure(.{});
    var buf: [10][]const u8 = undefined;
    const argv = A.buildRecordArgv(&buf, "ls -la", "", .user, null);
    try testing.expectEqual(@as(usize, 4), argv.len);
    try testing.expectEqualStrings("atuin", argv[0]);
    try testing.expectEqualStrings("history", argv[1]);
    try testing.expectEqualStrings("start", argv[2]);
    try testing.expectEqualStrings("ls -la", argv[3]);
}

test "buildRecordArgv: llm line with tagging off → still no --author" {
    // Defaults: tag_llm_author=false. The LLM author flows through
    // but the tag is suppressed — preserves the existing on-disk
    // format for users who haven't opted in.
    const A = configure(.{});
    var buf: [10][]const u8 = undefined;
    const argv = A.buildRecordArgv(&buf, "rm -rf /", "", .llm, null);
    try testing.expectEqual(@as(usize, 4), argv.len);
    try testing.expectEqualStrings("rm -rf /", argv[3]);
}

test "buildRecordArgv: llm line with tagging on → --author atty:llm appended before line" {
    const A = configure(.{ .tag_llm_author = true });
    var buf: [10][]const u8 = undefined;
    const argv = A.buildRecordArgv(&buf, "echo hi", "", .llm, null);
    try testing.expectEqual(@as(usize, 6), argv.len);
    try testing.expectEqualStrings("--author", argv[3]);
    try testing.expectEqualStrings("atty:llm", argv[4]);
    try testing.expectEqualStrings("echo hi", argv[5]);
}

test "buildRecordArgv: tagging on + .user → no --author (user-typed never tagged)" {
    const A = configure(.{ .tag_llm_author = true });
    var buf: [10][]const u8 = undefined;
    const argv = A.buildRecordArgv(&buf, "echo hi", "", .user, null);
    try testing.expectEqual(@as(usize, 4), argv.len);
}

test "buildRecordArgv: cwd inserts --cwd <value> between start and the line" {
    const A = configure(.{});
    var buf: [10][]const u8 = undefined;
    const argv = A.buildRecordArgv(&buf, "ls", "ssh://user@host/srv", .user, null);
    try testing.expectEqual(@as(usize, 6), argv.len);
    try testing.expectEqualStrings("--cwd", argv[3]);
    try testing.expectEqualStrings("ssh://user@host/srv", argv[4]);
    try testing.expectEqualStrings("ls", argv[5]);
}

test "buildRecordArgv: tagging on + cwd + .llm → full 8-slot argv" {
    const A = configure(.{ .tag_llm_author = true });
    var buf: [10][]const u8 = undefined;
    const argv = A.buildRecordArgv(&buf, "ls", "ssh://user@host/srv", .llm, null);
    try testing.expectEqual(@as(usize, 8), argv.len);
    try testing.expectEqualStrings("--cwd", argv[3]);
    try testing.expectEqualStrings("--author", argv[5]);
    try testing.expectEqualStrings("atty:llm", argv[6]);
    try testing.expectEqualStrings("ls", argv[7]);
}

test "buildRecordArgv: custom author_tag_prefix flows through to the tag" {
    const A = configure(.{ .tag_llm_author = true, .author_tag_prefix = "ws01" });
    var buf: [10][]const u8 = undefined;
    const argv = A.buildRecordArgv(&buf, "ls", "", .llm, null);
    try testing.expectEqualStrings("ws01:llm", argv[4]);
}

test "buildRecordArgv: intent on with .llm + intent text → --intent before line" {
    const A = configure(.{ .tag_llm_author = true, .tag_llm_intent = true });
    var buf: [10][]const u8 = undefined;
    const argv = A.buildRecordArgv(&buf, "ls -la", "", .llm, "list files in detail");
    // Slot layout: atuin, history, start, --author, atty:llm,
    // --intent, "list files in detail", "ls -la"
    try testing.expectEqual(@as(usize, 8), argv.len);
    try testing.expectEqualStrings("--intent", argv[5]);
    try testing.expectEqualStrings("list files in detail", argv[6]);
    try testing.expectEqualStrings("ls -la", argv[7]);
}

test "buildRecordArgv: intent flag off + intent text → no --intent" {
    const A = configure(.{ .tag_llm_author = true, .tag_llm_intent = false });
    var buf: [10][]const u8 = undefined;
    const argv = A.buildRecordArgv(&buf, "ls", "", .llm, "some intent");
    // No --intent emitted; line is at slot 5 (after the 5-element
    // prefix: atuin, history, start, --author, atty:llm).
    try testing.expectEqual(@as(usize, 6), argv.len);
    try testing.expectEqualStrings("ls", argv[5]);
}

test "buildRecordArgv: intent on but .user (user-typed) → no --intent" {
    const A = configure(.{ .tag_llm_intent = true });
    var buf: [10][]const u8 = undefined;
    const argv = A.buildRecordArgv(&buf, "ls", "", .user, "some intent");
    try testing.expectEqual(@as(usize, 4), argv.len);
    try testing.expectEqualStrings("ls", argv[3]);
}

test "buildRecordArgv: intent on but null intent slice → no --intent" {
    const A = configure(.{ .tag_llm_author = true, .tag_llm_intent = true });
    var buf: [10][]const u8 = undefined;
    const argv = A.buildRecordArgv(&buf, "ls", "", .llm, null);
    // Same as no-intent path — 6 slots, ends in the bare line.
    try testing.expectEqual(@as(usize, 6), argv.len);
    try testing.expectEqualStrings("ls", argv[5]);
}

test "Config: tag_llm_author defaults off; author_tag_prefix defaults atty" {
    // Default off — atuin builds before v18.3 reject `--author` and
    // would silently drop the record. Users opt in once they
    // confirm their atuin supports the flag.
    const A1 = configure(.{});
    try testing.expectEqual(false, A1.config.tag_llm_author);
    try testing.expectEqualStrings("atty", A1.config.author_tag_prefix);

    const A2 = configure(.{ .tag_llm_author = true, .author_tag_prefix = "ws01" });
    try testing.expectEqual(true, A2.config.tag_llm_author);
    try testing.expectEqualStrings("ws01", A2.config.author_tag_prefix);
}

test "configure exposes provideGhostList hook (multi-row pick list)" {
    // The hook is required for the multi-suggestion feature to read
    // atuin entries. Without it the dispatcher's gatherGhostList
    // skips atuin and falls through to history — which means users
    // running `modules = .{ atuin, history }` (or atuin-only) would
    // see no pick list. Pin the surface so a future refactor that
    // removes the hook breaks `zig build test` instead of silently
    // breaking the feature.
    const A = configure(.{});
    try testing.expect(@hasDecl(A, "provideGhostList"));
}

test "configure exposes deleteHistoryMatch hook (regression: atuin-side delete must be wired)" {
    // Regression: the user had `modules = .{ guardrail, atuin, history }`
    // in their config and pressed Ctrl+Shift+D. The proxy walked the
    // dispatcher and only history's deleteHistoryMatch fired (atuin
    // didn't implement the hook at all), so the entry stayed in
    // atuin's daemon and re-suggested on the next prefix.
    //
    // After the fix, atuin advertises the hook → dispatcher fans the
    // call out to it. If this @hasDecl ever flips back to false the
    // delete is silently broken for everyone running atuin — fail
    // loudly here instead.
    const A = configure(.{});
    try testing.expect(@hasDecl(A, "deleteHistoryMatch"));
}
