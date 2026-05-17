//! Lightweight system-context gatherer for the LLM module.
//!
//! Goal: give the model enough info to stop suggesting `apt` on
//! Arch, or `cd ~` when the user is already in a subdirectory of
//! their project. The shell's PS1 typically advertises this stuff
//! (cwd, git branch, dirty marker); the LLM doesn't see PS1, so
//! atty has to surface the same signals through the system prompt.
//!
//! Two layers:
//!
//!   • **Static** (`gatherStatic`) — OS name + distro pretty-name +
//!     kernel + arch. Resolved ONCE at attach and cached on Runtime.
//!     Cost: one open + small read of `/etc/os-release`, one uname()
//!     syscall.
//!
//!   • **Dynamic** (`gatherDynamic`) — cwd + git state (branch,
//!     dirty-or-clean flag when reachable cheaply). Rebuilt on every
//!     LLM request. Cost: a few stat()s + a tiny read of
//!     `<cwd>/.git/HEAD`. No `git status` subprocess by default —
//!     the slow per-prompt invocation that lights up I/O on huge
//!     monorepos.
//!
//! The composed blob is appended to the system prompt under a
//! `System:` heading by `dialog.buildRequestBody` /
//! `worker.buildRequestBody` (both already take a `context_blob`
//! string and concatenate it onto the system message).

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*]u8;
extern "c" fn system(command: [*:0]const u8) c_int;

const O_RDONLY: c_int = 0;
const F_OK: c_int = 0;

/// One-shot resolution of static OS info. Returns owned bytes.
/// Format examples:
///   - "Arch Linux (Linux 7.0.3-arch1-2 x86_64)"
///   - "Ubuntu 24.04.1 LTS (Linux 6.8.0-45-generic x86_64)"
///   - "Linux 6.1.0 x86_64"  (when /etc/os-release isn't readable)
///   - ""  (everything failed; caller treats as "no OS info")
pub fn gatherStatic(allocator: std.mem.Allocator) ![]u8 {
    const pretty = readOsReleasePretty(allocator) catch null;
    defer if (pretty) |p| allocator.free(p);

    const uts = std.posix.uname();
    const sysname = std.mem.sliceTo(&uts.sysname, 0);
    const release = std.mem.sliceTo(&uts.release, 0);
    const machine = std.mem.sliceTo(&uts.machine, 0);

    if (pretty) |p| {
        return std.fmt.allocPrint(allocator, "{s} ({s} {s} {s})", .{ p, sysname, release, machine });
    }
    return std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ sysname, release, machine });
}

/// Per-request dynamic context. Reads:
///   - cwd: from `cwd_hint` when non-empty (typically the subprocess
///     tracker's current cwd, which IS the shell's view); otherwise
///     falls back to the proxy process's own `getcwd()` (best-effort
///     — atty's cwd often diverges from bash's after the user `cd`s).
///   - git_branch + git_clean: `<cwd>/.git/HEAD` read when
///     `include_git` is true. Walks one level up only — atty doesn't
///     traverse the whole ancestor chain (cheap heuristic; misses
///     the user being deep inside a subdir of a repo, but covers the
///     common case of "you're at the repo root").
///
/// Returns an empty slice when nothing useful was gathered (e.g.
/// non-TTY, getcwd failed, no git, no os-release).
pub fn gatherDynamic(
    allocator: std.mem.Allocator,
    cwd_hint: []const u8,
    include_git: bool,
) ![]u8 {
    var parts: std.Io.Writer.Allocating = .init(allocator);
    errdefer parts.deinit();
    const w = &parts.writer;

    var cwd_buf: [4096]u8 = undefined;
    const cwd: []const u8 = if (cwd_hint.len > 0)
        cwd_hint
    else if (getcwd(&cwd_buf, cwd_buf.len)) |p|
        std.mem.span(@as([*:0]u8, @ptrCast(p)))
    else
        "";

    if (cwd.len > 0) {
        try w.print("PWD={s}", .{cwd});
    }

    if (include_git and cwd.len > 0) {
        if (readGitHead(allocator, cwd)) |head| {
            defer allocator.free(head.branch);
            if (parts.written().len > 0) try w.writeAll("; ");
            try w.print("Git=branch:{s}", .{head.branch});
        } else |_| {} // not in a git repo / unreadable — silently skip
    }

    return parts.toOwnedSlice();
}

/// Compose the final context blob shipped to the model. Joins the
/// pre-computed static + freshly-gathered dynamic + the
/// user-configured env-var blob with `; ` separators. Skips empty
/// pieces so a missing component doesn't leave a `;;` artifact.
pub fn compose(
    allocator: std.mem.Allocator,
    static: []const u8,
    dynamic: []const u8,
    env_blob: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    var first = true;
    inline for (.{ static, dynamic, env_blob }) |piece| {
        if (piece.len > 0) {
            if (!first) try w.writeAll("; ");
            try w.writeAll(piece);
            first = false;
        }
    }
    return out.toOwnedSlice();
}

// ─── internals ────────────────────────────────────────────────────────────

/// Parse `PRETTY_NAME="..."` out of `/etc/os-release`. Returns
/// owned memory or `error.NotFound`/IO error.
fn readOsReleasePretty(allocator: std.mem.Allocator) ![]u8 {
    const fd = open("/etc/os-release", O_RDONLY);
    if (fd < 0) return error.FileNotFound;
    defer _ = close(fd);

    var buf: [4096]u8 = undefined;
    const n = read(fd, &buf, buf.len);
    if (n <= 0) return error.ReadFailed;
    const content = buf[0..@as(usize, @intCast(n))];

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "PRETTY_NAME=")) {
            var value = trimmed["PRETTY_NAME=".len..];
            // Strip matching surrounding quotes. Per os-release(5)
            // both double and single quotes are spec-legal — no
            // mainstream distro uses single quotes, but cheap to
            // handle.
            if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\'')))
            {
                value = value[1 .. value.len - 1];
            }
            if (value.len == 0) return error.NotFound;
            return allocator.dupe(u8, value);
        }
    }
    return error.NotFound;
}

const GitHead = struct {
    branch: []u8, // owned by caller
};

/// Read the current branch from `<cwd>/.git/HEAD`. Handles three
/// repository shapes:
///   1. **Plain repo** — `<cwd>/.git` is a directory; HEAD sits at
///      `<cwd>/.git/HEAD`.
///   2. **Worktree** — `<cwd>/.git` is a regular file whose contents
///      are `gitdir: <abs-or-rel-path>` pointing at the worktree's
///      private git dir under `<main>/.git/worktrees/<name>`. Follow
///      the indirection once.
///   3. **Submodule** — same file-with-`gitdir:` indirection as
///      worktrees, pointing at `<parent>/.git/modules/<name>`.
///
/// Returns the symbolic ref's short name (e.g. "master") or the
/// abbreviated commit hash for detached HEAD ("detached@abc1234").
fn readGitHead(allocator: std.mem.Allocator, cwd: []const u8) !GitHead {
    var path_buf: [4096]u8 = undefined;
    const dotgit_path = try std.fmt.bufPrintZ(&path_buf, "{s}/.git", .{cwd});

    // Probe `.git`: a directory opens with O_RDONLY (most kernels;
    // we ALSO read it because if it's actually a file, the read
    // returns the `gitdir: …` indirection. If it IS a directory the
    // read returns -1/EISDIR — fall back to the direct HEAD path).
    const probe_fd = open(dotgit_path.ptr, O_RDONLY);
    if (probe_fd < 0) return error.FileNotFound;
    var probe_buf: [4096]u8 = undefined;
    const probe_n = read(probe_fd, &probe_buf, probe_buf.len);
    _ = close(probe_fd);

    // `.git` is a directory (read failed or returned 0) → HEAD lives
    // at `<cwd>/.git/HEAD`.
    if (probe_n <= 0) {
        return readHeadAt(allocator, cwd, ".git");
    }

    // `.git` is a file → parse `gitdir: <path>` and read HEAD from
    // there. The path can be absolute (`/main/.git/worktrees/foo`)
    // or relative to `<cwd>` (`../.git/worktrees/foo`).
    const probe_content = std.mem.trim(u8, probe_buf[0..@as(usize, @intCast(probe_n))], " \t\r\n");
    if (!std.mem.startsWith(u8, probe_content, "gitdir:")) {
        return error.MalformedGitFile;
    }
    const gitdir_raw = std.mem.trim(u8, probe_content["gitdir:".len..], " \t");
    if (gitdir_raw.len == 0) return error.MalformedGitFile;

    // Anchor relative `gitdir:` paths to `<cwd>`. `readHeadAt`
    // composes `<base>/<sub>/HEAD`; we pass cwd + the raw gitdir
    // for relative paths, "" + the absolute path for absolute ones.
    if (gitdir_raw[0] == '/') {
        return readHeadAt(allocator, "", gitdir_raw);
    }
    return readHeadAt(allocator, cwd, gitdir_raw);
}

/// Helper: read HEAD at `<base>/<sub>/HEAD` (or `<sub>/HEAD` when
/// `base` is empty — for absolute gitdir paths from a worktree).
fn readHeadAt(allocator: std.mem.Allocator, base: []const u8, sub: []const u8) !GitHead {
    var path_buf: [4096]u8 = undefined;
    const path = if (base.len == 0)
        try std.fmt.bufPrintZ(&path_buf, "{s}/HEAD", .{sub})
    else
        try std.fmt.bufPrintZ(&path_buf, "{s}/{s}/HEAD", .{ base, sub });

    const fd = open(path.ptr, O_RDONLY);
    if (fd < 0) return error.FileNotFound;
    defer _ = close(fd);

    var content_buf: [256]u8 = undefined;
    const n = read(fd, &content_buf, content_buf.len);
    if (n <= 0) return error.ReadFailed;
    const content = std.mem.trim(u8, content_buf[0..@as(usize, @intCast(n))], " \t\r\n");

    if (std.mem.startsWith(u8, content, "ref: refs/heads/")) {
        const branch = content["ref: refs/heads/".len..];
        if (branch.len == 0) return error.MalformedHead;
        return .{ .branch = try allocator.dupe(u8, branch) };
    }
    // Detached HEAD — content is the commit hash. Abbreviate to 7 chars.
    if (content.len >= 7) {
        var out_buf: [16]u8 = undefined;
        const abbrev = try std.fmt.bufPrint(&out_buf, "detached@{s}", .{content[0..7]});
        return .{ .branch = try allocator.dupe(u8, abbrev) };
    }
    return error.MalformedHead;
}

// ─── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

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
