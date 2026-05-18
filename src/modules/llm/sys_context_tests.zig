//! Tests for `modules/llm/sys_context.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("sys_context.zig");

// Re-binds of pub decls so test bodies stay short.
const access = mod.access;
const close = mod.close;
const compose = mod.compose;
const gatherDynamic = mod.gatherDynamic;
const gatherStatic = mod.gatherStatic;
const getcwd = mod.getcwd;
const getenv = mod.getenv;
const open = mod.open;
const read = mod.read;
const readGitHead = mod.readGitHead;
const system = mod.system;

test "compose: joins non-empty pieces with `; `" {
    const out = try compose(testing.allocator, "OS=Arch", "PWD=/tmp", "USER=fentas");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("OS=Arch; PWD=/tmp; USER=fentas", out);
}

test "compose: skips empty pieces" {
    const a = try compose(testing.allocator, "OS=Arch", "", "USER=fentas");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("OS=Arch; USER=fentas", a);

    const b = try compose(testing.allocator, "", "PWD=/tmp", "");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("PWD=/tmp", b);

    const c = try compose(testing.allocator, "", "", "");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("", c);
}

test "gatherDynamic: cwd hint takes precedence" {
    const out = try gatherDynamic(testing.allocator, "/explicit/path", false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "PWD=/explicit/path"));
}

test "gatherDynamic: empty cwd hint + git off → falls back to process cwd" {
    // We can't assert exact path (test fixture varies) but it should
    // produce SOMETHING starting with "PWD=".
    const out = try gatherDynamic(testing.allocator, "", false);
    defer testing.allocator.free(out);
    if (out.len > 0) {
        try testing.expect(std.mem.startsWith(u8, out, "PWD="));
    }
}

test "gatherStatic: returns non-empty bytes on a Linux test host" {
    const out = try gatherStatic(testing.allocator);
    defer testing.allocator.free(out);
    // At minimum should contain the kernel name from uname().
    try testing.expect(out.len > 0);
    try testing.expect(std.mem.indexOf(u8, out, "Linux") != null);
}

test "readGitHead: returns branch when run from atty's own repo" {
    // Tests run from project root. atty's master branch is committed
    // so .git/HEAD should be readable. This is a soft assertion —
    // skip if the test environment isn't a git checkout.
    const head = readGitHead(testing.allocator, ".") catch return error.SkipZigTest;
    defer testing.allocator.free(head.branch);
    try testing.expect(head.branch.len > 0);
}

test "readGitHead: follows gitdir: indirection (worktree shape)" {
    // Build a fake worktree shape in /tmp:
    //   /tmp/atty-wt-<ts>/main/.git/{HEAD,worktrees/wt/HEAD}
    //   /tmp/atty-wt-<ts>/wt/.git   ← FILE containing "gitdir: <abs>"
    // and verify readGitHead on /wt resolves to the worktree's HEAD.
    var name_buf: [128]u8 = undefined;
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const root = try std.fmt.bufPrint(&name_buf, "/tmp/atty-wt-{x}", .{seed});

    // Cleanup helper — best-effort `rm -rf` via libc.
    defer cleanup: {
        var rm_buf: [256]u8 = undefined;
        const rm_cmd = std.fmt.bufPrintZ(&rm_buf, "rm -rf {s}", .{root}) catch break :cleanup;
        _ = system(rm_cmd.ptr);
    }

    // Build the tree.
    {
        var sh_buf: [512]u8 = undefined;
        const sh = std.fmt.bufPrintZ(&sh_buf,
            \\mkdir -p {s}/main/.git/worktrees/wt {s}/wt &&
            \\printf 'ref: refs/heads/feature\n' > {s}/main/.git/worktrees/wt/HEAD &&
            \\printf 'gitdir: {s}/main/.git/worktrees/wt\n' > {s}/wt/.git
        , .{ root, root, root, root, root }) catch return error.OutOfMemory;
        _ = system(sh.ptr);
    }

    // Run the resolver against the fake worktree cwd.
    var cwd_buf: [256]u8 = undefined;
    const wt_cwd = try std.fmt.bufPrint(&cwd_buf, "{s}/wt", .{root});
    const head = try readGitHead(testing.allocator, wt_cwd);
    defer testing.allocator.free(head.branch);
    try testing.expectEqualStrings("feature", head.branch);
}

test "readGitHead: handles relative gitdir: paths" {
    var name_buf: [128]u8 = undefined;
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec)) +% 1;
    const root = try std.fmt.bufPrint(&name_buf, "/tmp/atty-relwt-{x}", .{seed});
    defer cleanup: {
        var rm_buf: [256]u8 = undefined;
        const rm_cmd = std.fmt.bufPrintZ(&rm_buf, "rm -rf {s}", .{root}) catch break :cleanup;
        _ = system(rm_cmd.ptr);
    }
    {
        var sh_buf: [512]u8 = undefined;
        // Relative gitdir: "../shared-git". cwd will be {root}/wt;
        // gitdir resolves to {root}/wt/../shared-git == {root}/shared-git.
        const sh = std.fmt.bufPrintZ(&sh_buf,
            \\mkdir -p {s}/shared-git {s}/wt &&
            \\printf 'ref: refs/heads/rel-branch\n' > {s}/shared-git/HEAD &&
            \\printf 'gitdir: ../shared-git\n' > {s}/wt/.git
        , .{ root, root, root, root }) catch return error.OutOfMemory;
        _ = system(sh.ptr);
    }
    var cwd_buf: [256]u8 = undefined;
    const wt_cwd = try std.fmt.bufPrint(&cwd_buf, "{s}/wt", .{root});
    const head = try readGitHead(testing.allocator, wt_cwd);
    defer testing.allocator.free(head.branch);
    try testing.expectEqualStrings("rel-branch", head.branch);
}
