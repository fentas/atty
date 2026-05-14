//! Subprocess-context tracker — what's running between OSC 133 `;C` and `;D`.
//!
//! Local atty sees every keystroke in the local PTY, including those
//! sent to subprocesses (ssh, sudo, kubectl exec, docker exec, …) and
//! interactive apps (vim, less, psql, …). PR #15 added a blanket-drop
//! for `dispatchLineCommit` while in a subprocess so the user's local
//! atuin index doesn't get polluted with every Enter inside vim.
//!
//! But blanket-drop also discards commands typed at *remote shell
//! prompts*, which is a real loss — the cleanest way to search "what
//! did I run on prod-bastion last week" is to type `<query>` in atuin
//! Ctrl+R if those commands were recorded with the remote target
//! attached. This tracker takes the next step:
//!
//!   1. Sniff each line committed at the LOCAL prompt before `;C`.
//!   2. If the first token is a known shell-launcher (`ssh`, `mosh`,
//!      `kubectl exec`, `docker exec`, `sudo bash`, `su`, …), resolve
//!      the target (host / pod / container / …) and push a
//!      `Context` onto the stack.
//!   3. Subsequent committed lines (typed by the user at the remote
//!      prompt, captured by atty's local keystroke tracking) are
//!      tagged with the top-of-stack `Context` so atuin / history
//!      can attribute them properly. Encoding goes through the
//!      modules' `--cwd` parameter as `ssh://user@host/<remote-cwd>`
//!      or `k8s://<context>/<ns>/<pod>` etc. — atuin's `--cwd` is a
//!      free-form string, so [DIRECTORY] mode on Ctrl+R naturally
//!      scopes per target.
//!   4. On `;D` we pop. Nested ssh chains (local → server1 → server2)
//!      naturally produce a stack of depth 2.
//!
//! The unknown-app blanket drop from PR #15 still applies — anything
//! that ISN'T a recognized shell launcher continues to suppress its
//! typed lines (vim, less, psql, mysql, nano, …).
//!
//! `Tracker` is fixed-size — no allocations in the hot path. Stack
//! depth caps at 8 (deeper ssh chains than that are operator error;
//! we just refuse to grow rather than allocating).
//!
//! File layout: public types + Tracker + formatCwd here. The ~900-
//! line collection of command-line parsers (ssh / sudo / kubectl /
//! docker / lxc / `ssh -G` resolver) lives in `subprocess/parse.zig`.

const std = @import("std");
const parse = @import("subprocess/parse.zig");

/// What kind of subprocess we detected at the last `;C` transition.
/// `none` means the line was a regular command (vim, less, ls, …) —
/// we won't record commits typed inside it.
pub const Kind = enum {
    none,
    /// `ssh` or `mosh` to a remote host.
    ssh,
    /// `kubectl exec -it pod -- bash` and friends.
    kubectl_exec,
    /// `docker exec -it container bash`, `podman exec`, `nerdctl exec`.
    docker_exec,
    /// `lxc exec`, `incus exec`.
    container_exec,
    /// `sudo bash`, `sudo -s`, `sudo -i`, `doas <shell>`. Stays on the
    /// LOCAL host but the privilege boundary is recorded so the user
    /// can filter "what did I do as root last week".
    elevation,
    /// `su -`, `su username`. Same as `elevation` from a recording POV.
    su,
};

/// One frame on the subprocess stack. Fixed-size buffers — the
/// `name_buf` / `cwd_buf` storage is owned by the frame and copied
/// from `ssh -G` output or OSC 7 capture.
pub const Frame = struct {
    kind: Kind = .none,
    /// Total bytes used in `name_buf`. The semantic of `name_buf`
    /// depends on `kind`:
    ///   .ssh           → "user@host" (or just "host" when no user)
    ///   .kubectl_exec  → "<context>/<ns>/<pod>"
    ///   .docker_exec   → "<container>"
    ///   .container_exec → "<container>"
    ///   .elevation     → "sudo" or "doas"
    ///   .su            → "su:<user>" or "su"
    ///   .none          → empty
    name_len: usize = 0,
    name_buf: [256]u8 = undefined,

    /// Remote cwd if known (captured via OSC 7 from the remote
    /// shell's integration). Empty until / unless OSC 7 fires.
    cwd_len: usize = 0,
    cwd_buf: [512]u8 = undefined,

    pub fn name(self: *const Frame) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn cwd(self: *const Frame) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }

    /// Set the human-readable name (`user@host`, `<context>/<ns>/<pod>`,
    /// `sudo`, `su:<user>`, …). Truncates to `name_buf`'s 256-byte
    /// capacity; callers don't have to length-check.
    pub fn setName(self: *Frame, s: []const u8) void {
        const n = @min(s.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], s[0..n]);
        self.name_len = n;
    }
    /// Set the remote cwd captured from OSC 7. Truncates to
    /// `cwd_buf`'s 512-byte capacity.
    pub fn setCwd(self: *Frame, s: []const u8) void {
        const n = @min(s.len, self.cwd_buf.len);
        @memcpy(self.cwd_buf[0..n], s[0..n]);
        self.cwd_len = n;
    }
};

/// Encoding for the `--cwd` we hand to atuin / pass to history.
/// Free-form strings — atuin treats `--cwd` as a label, so we can
/// shove whatever URI-ish scheme we want here.
///
///   ssh://user@host/<remote-cwd>
///   k8s://<context>/<ns>/<pod>/<remote-cwd>
///   docker://<container>/<remote-cwd>
///   container://<name>/<remote-cwd>
///   sudo:<local-cwd>
///   su:<user>:<local-cwd>
///
/// The `local-cwd` for elevation/su variants comes from the *real*
/// shell cwd (we'd grab it via /proc/<child_pid>/cwd elsewhere; for
/// MVP we leave it as `?` and let users see "sudo:?" in Ctrl+R).
pub fn formatCwd(
    frame: *const Frame,
    out: []u8,
    fallback_local_cwd: []const u8,
) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    // Strip the leading `/` from the remote path before composing the
    // URI — OSC 7 reports absolute paths, and naively concatenating
    // `ssh://host/` + `/home/foo` produces the double-slashed
    // `ssh://host//home/foo`. With this normalisation we get the
    // documented `ssh://host/home/foo` shape, which is also what
    // atuin's `[ DIRECTORY ]` filter groups by.
    const rcwd_raw: []const u8 = if (frame.cwd_len > 0) frame.cwd() else "?";
    // Strip any leading `/`. The previous `len > 1` form left a bare
    // `/` cwd untouched, producing `ssh://host//` for sessions
    // currently at root — common enough on minimal containers /
    // service images. With `len >= 1` the `/` becomes empty and the
    // URI lands as `ssh://host/`, which is what atuin's
    // `[ DIRECTORY ]` group key wants.
    const rcwd: []const u8 = if (rcwd_raw.len >= 1 and rcwd_raw[0] == '/')
        rcwd_raw[1..]
    else
        rcwd_raw;
    // Elevation/su frames format `<name>:<local-cwd>` — when the
    // caller didn't pass a local cwd we substitute `?` so the
    // recorded entry doesn't end with a dangling colon (`sudo:`,
    // `su:postgres:`). The placeholder makes it visible in atuin's
    // Ctrl+R that we elevated but didn't capture a path.
    const elev_cwd: []const u8 = if (fallback_local_cwd.len > 0) fallback_local_cwd else "?";
    switch (frame.kind) {
        .none => {
            w.writeAll(fallback_local_cwd) catch {};
        },
        .ssh => {
            w.print("ssh://{s}/{s}", .{ frame.name(), rcwd }) catch {};
        },
        .kubectl_exec => {
            w.print("k8s://{s}/{s}", .{ frame.name(), rcwd }) catch {};
        },
        .docker_exec => {
            w.print("docker://{s}/{s}", .{ frame.name(), rcwd }) catch {};
        },
        .container_exec => {
            w.print("container://{s}/{s}", .{ frame.name(), rcwd }) catch {};
        },
        .elevation => {
            w.print("{s}:{s}", .{ frame.name(), elev_cwd }) catch {};
        },
        .su => {
            w.print("{s}:{s}", .{ frame.name(), elev_cwd }) catch {};
        },
    }
    return out[0..w.end];
}

/// Maximum stack depth. Deeper nesting than this is operator error
/// (and atty refuses to grow rather than allocating); the top frame
/// just stays pinned as long as additional `;C` markers arrive.
pub const max_depth = 8;

/// Worst-case byte length of a `formatCwd` output. Derived from
/// `Frame.name_buf` (256) + `Frame.cwd_buf` (512) + the longest
/// fixed scheme (`container://`, 12) + a few separators. Callers
/// allocate scratch of at least this size; anything smaller risks
/// silent truncation by the `formatCwd` `std.Io.Writer.fixed`
/// path (errors there are swallowed). Used in `module.Context.
/// subprocessCwd` and in the atuin module's record mailbox.
pub const max_cwd_bytes = 1024;

/// Tracker — owns the stack. Methods are called from the proxy at
/// `;C` / `;D` transitions, and `current()` is consulted when
/// `dispatchLineCommit` fires.
///
/// Zero allocations after `init`; all state is inline.
pub const Tracker = struct {
    frames: [max_depth]Frame = [_]Frame{.{}} ** max_depth,
    depth: usize = 0,
    /// Pushes beyond `max_depth` increment this counter instead of
    /// touching the frame array. `;D` pops consume the overflow
    /// before unwinding real frames, preserving the
    /// `depth(;C) == depth(;D) + 1` invariant after saturation
    /// (otherwise we'd unwind the pinned-deep stack too early once
    /// the user dropped back below the saturation point).
    overflow: usize = 0,

    /// Path to `ssh` binary used for `-G` resolution. Configurable
    /// because some setups (NixOS, Guix, custom containers) put ssh
    /// outside `$PATH` or want a particular wrapper.
    ssh_binary: []const u8 = "ssh",

    /// When false, the parser still detects launchers but `ssh -G`
    /// is skipped — host is taken straight from the typed command
    /// (`ssh foo@bar.example.com` → `foo@bar.example.com`). Loses
    /// ssh_config alias resolution but doesn't fork+exec on every
    /// `ssh` invocation; useful when ssh is slow or absent.
    use_ssh_g: bool = true,

    pub fn init() Tracker {
        return .{};
    }

    /// Top frame's kind. `.none` when stack is empty.
    pub fn currentKind(self: *const Tracker) Kind {
        if (self.depth == 0) return .none;
        return self.frames[self.depth - 1].kind;
    }

    /// Borrow of the top frame. Null when stack is empty.
    /// Reflects the IMMEDIATE state of the stack including any
    /// `.none` frames pushed for unrecognised commands running
    /// inside a recognised subprocess. Use this when correctness
    /// depends on "what command is currently running"; use
    /// `currentRecognized()` when correctness depends on the
    /// ambient context (e.g. statusbar segment display).
    pub fn current(self: *const Tracker) ?*const Frame {
        if (self.depth == 0) return null;
        return &self.frames[self.depth - 1];
    }

    /// Borrow of the topmost frame whose `kind` is **not** `.none`,
    /// skipping `.none` frames pushed for unrecognised commands
    /// running INSIDE a recognised subprocess.
    ///
    /// Why it matters: when the user is inside `ssh remote` and runs
    /// `ls`, the stack briefly becomes `[ssh:remote, .none(ls)]`
    /// between `ls`'s `;C` and `;D`. `current()` returns the `.none`
    /// frame; for statusbar display, that would make the
    /// `→ ssh:remote` segment vanish for the duration of `ls`,
    /// reappearing only when the next prompt fires — visible flicker.
    /// `currentRecognized()` walks down past `.none` frames and
    /// returns the ssh frame, so the segment stays stable across
    /// the whole ssh session.
    pub fn currentRecognized(self: *const Tracker) ?*const Frame {
        var i: usize = self.depth;
        while (i > 0) {
            i -= 1;
            if (self.frames[i].kind != .none) return &self.frames[i];
        }
        return null;
    }

    /// Pop on `;D`. Idempotent on an empty stack. When we previously
    /// saturated (overflow > 0) the pop consumes overflow first so
    /// the real stack stays pinned at max_depth until the user has
    /// returned below the saturation point.
    pub fn onCommandEnd(self: *Tracker) void {
        if (self.overflow > 0) {
            self.overflow -= 1;
            return;
        }
        if (self.depth == 0) return;
        self.depth -= 1;
        // Reset the popped frame so a stale name doesn't leak via
        // currentKind/current after over-pop.
        self.frames[self.depth] = .{};
    }

    /// Push on `;C`. Parses `committed_line` to decide what kind of
    /// frame to push. Lines that aren't recognized launchers get a
    /// `.none` frame so `;D` arrives + pops correctly — keeping the
    /// stack invariant `depth(;C) == depth(;D) + 1`.
    ///
    /// `gpa` + `io` are only used when `kind == .ssh` and
    /// `use_ssh_g` is true — to spawn `ssh -G <args>`. Pass
    /// `null` for `io` to force the regex fallback even when
    /// `use_ssh_g` is configured on.
    pub fn onCommandStart(
        self: *Tracker,
        committed_line: []const u8,
        gpa: std.mem.Allocator,
        io: ?std.Io,
    ) void {
        // Saturation: increment overflow so the matching ;D pops it
        // instead of unwinding a real frame. Top context stays pinned.
        if (self.depth >= max_depth) {
            self.overflow += 1;
            return;
        }
        const frame = &self.frames[self.depth];
        frame.* = .{};
        self.depth += 1;

        parse.parseInto(frame, committed_line, self.ssh_binary, self.use_ssh_g, gpa, io);
    }

    /// Capture an OSC 7 cwd report into the current top frame.
    /// Accepts either form:
    ///   - A `file://<host>/<path>` URI (raw OSC 7 payload)
    ///   - A bare absolute path (what `Osc7.takeCwd()` returns after
    ///     it pre-strips the `file://<host>` prefix for us)
    /// No-op when stack is empty or the input has no extractable path.
    pub fn onRemoteCwd(self: *Tracker, cwd_or_uri: []const u8) void {
        if (self.depth == 0) return;
        const path: []const u8 = if (std.mem.startsWith(u8, cwd_or_uri, "file://")) blk: {
            const after_scheme = cwd_or_uri["file://".len..];
            const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return;
            break :blk after_scheme[slash..];
        } else cwd_or_uri;
        if (path.len == 0) return;
        self.frames[self.depth - 1].setCwd(path);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "Tracker: push/pop balance" {
    var t = Tracker.init();
    try testing.expectEqual(@as(usize, 0), t.depth);

    // Use the regex fallback only — pass `null` for io to skip ssh -G.
    t.onCommandStart("ssh foo@bar", testing.allocator, null);
    try testing.expectEqual(@as(usize, 1), t.depth);
    try testing.expectEqual(Kind.ssh, t.currentKind());
    try testing.expectEqualStrings("foo@bar", t.current().?.name());

    t.onCommandEnd();
    try testing.expectEqual(@as(usize, 0), t.depth);
    try testing.expectEqual(Kind.none, t.currentKind());
}

test "Tracker: unrecognized command pushes a .none frame" {
    var t = Tracker.init();
    t.onCommandStart("ls -la", testing.allocator, null);
    try testing.expectEqual(@as(usize, 1), t.depth);
    try testing.expectEqual(Kind.none, t.currentKind());
    t.onCommandEnd();
    try testing.expectEqual(@as(usize, 0), t.depth);
}

test "Tracker.currentRecognized: skips `.none` frames sitting on top" {
    // The statusbar consults `currentRecognized` so the
    // `→ ssh:remote` segment doesn't flicker every time the user
    // runs a regular command inside the remote shell. Stack here
    // mirrors that scenario exactly.
    var t = Tracker.init();
    t.onCommandStart("ssh foo@bar", testing.allocator, null);
    t.onCommandStart("ls -la", testing.allocator, null);
    try testing.expectEqual(Kind.none, t.current().?.kind);
    try testing.expectEqual(Kind.ssh, t.currentRecognized().?.kind);
    try testing.expectEqualStrings("foo@bar", t.currentRecognized().?.name());
}

test "Tracker.currentRecognized: returns null when only `.none` frames are on the stack" {
    var t = Tracker.init();
    t.onCommandStart("ls -la", testing.allocator, null);
    t.onCommandStart("date", testing.allocator, null);
    try testing.expectEqual(@as(?*const Frame, null), t.currentRecognized());
}

test "Tracker.currentRecognized: returns null on an empty stack" {
    var t = Tracker.init();
    try testing.expectEqual(@as(?*const Frame, null), t.currentRecognized());
}

test "Tracker: nested ssh chain" {
    var t = Tracker.init();
    t.onCommandStart("ssh server1", testing.allocator, null);
    try testing.expectEqualStrings("server1", t.current().?.name());

    t.onCommandStart("ssh server2", testing.allocator, null);
    try testing.expectEqualStrings("server2", t.current().?.name());
    try testing.expectEqual(@as(usize, 2), t.depth);

    t.onCommandEnd();
    try testing.expectEqualStrings("server1", t.current().?.name());

    t.onCommandEnd();
    try testing.expectEqual(@as(usize, 0), t.depth);
}

test "Tracker: over-pop is a no-op (doesn't crash)" {
    var t = Tracker.init();
    t.onCommandEnd();
    t.onCommandEnd();
    try testing.expectEqual(@as(usize, 0), t.depth);
}

test "Tracker: stack saturates at max_depth" {
    var t = Tracker.init();
    var i: usize = 0;
    while (i < max_depth + 3) : (i += 1) {
        t.onCommandStart("ssh server", testing.allocator, null);
    }
    try testing.expectEqual(max_depth, t.depth);
    try testing.expectEqual(@as(usize, 3), t.overflow);
}

test "Tracker: balanced pops after saturation drain overflow first" {
    var t = Tracker.init();
    var i: usize = 0;
    while (i < max_depth + 3) : (i += 1) {
        t.onCommandStart("ssh foo@bar", testing.allocator, null);
    }
    try testing.expectEqual(max_depth, t.depth);
    try testing.expectEqual(@as(usize, 3), t.overflow);

    t.onCommandEnd();
    try testing.expectEqual(max_depth, t.depth);
    try testing.expectEqual(@as(usize, 2), t.overflow);
    t.onCommandEnd();
    t.onCommandEnd();
    try testing.expectEqual(max_depth, t.depth);
    try testing.expectEqual(@as(usize, 0), t.overflow);

    i = 0;
    while (i < max_depth) : (i += 1) t.onCommandEnd();
    try testing.expectEqual(@as(usize, 0), t.depth);
    try testing.expectEqual(@as(usize, 0), t.overflow);
}

test "Tracker: OSC 7 cwd update lands on top frame" {
    var t = Tracker.init();
    t.onCommandStart("ssh foo@bar", testing.allocator, null);
    t.onRemoteCwd("file://bar.example.com/home/foo/work");
    try testing.expectEqualStrings("/home/foo/work", t.current().?.cwd());
}

test "Tracker: onRemoteCwd accepts bare path (what Osc7.takeCwd returns)" {
    var t = Tracker.init();
    t.onCommandStart("ssh foo@bar", testing.allocator, null);
    t.onRemoteCwd("/var/log");
    try testing.expectEqualStrings("/var/log", t.current().?.cwd());
}

test "Tracker: OSC 7 ignored when no frame is active" {
    var t = Tracker.init();
    t.onRemoteCwd("file://host/path");
    try testing.expectEqual(@as(usize, 0), t.depth);
}

test "Tracker: onRemoteCwd ignores empty input and malformed file:// URIs" {
    var t = Tracker.init();
    t.onCommandStart("ssh foo@bar", testing.allocator, null);
    t.onRemoteCwd("");
    try testing.expectEqual(@as(usize, 0), t.current().?.cwd_len);
    t.onRemoteCwd("file://hostonly");
    try testing.expectEqual(@as(usize, 0), t.current().?.cwd_len);
    t.onRemoteCwd("file://host/srv");
    try testing.expectEqualStrings("/srv", t.current().?.cwd());
}

test "Tracker: one-shot ssh host cmd doesn't classify as ssh" {
    var t = Tracker.init();
    t.onCommandStart("ssh foo@bar uptime", testing.allocator, null);
    try testing.expectEqual(@as(usize, 1), t.depth);
    try testing.expectEqual(Kind.none, t.currentKind());
}

test "Tracker: sudo bash classified as elevation" {
    var t = Tracker.init();
    t.onCommandStart("sudo bash", testing.allocator, null);
    try testing.expectEqual(Kind.elevation, t.currentKind());
    try testing.expectEqualStrings("sudo", t.current().?.name());
}

test "Tracker: sudo apt update is NOT elevation (typing inside apt isn't shell input)" {
    var t = Tracker.init();
    t.onCommandStart("sudo apt update", testing.allocator, null);
    try testing.expectEqual(Kind.none, t.currentKind());
}

test "Tracker: su classification" {
    var t = Tracker.init();
    t.onCommandStart("su - postgres", testing.allocator, null);
    try testing.expectEqual(Kind.su, t.currentKind());
    try testing.expectEqualStrings("su:postgres", t.current().?.name());
}

test "Tracker: bare su produces `su` (no trailing colon)" {
    var t = Tracker.init();
    t.onCommandStart("su", testing.allocator, null);
    try testing.expectEqual(Kind.su, t.currentKind());
    try testing.expectEqualStrings("su", t.current().?.name());

    var t2 = Tracker.init();
    t2.onCommandStart("su -", testing.allocator, null);
    try testing.expectEqualStrings("su", t2.current().?.name());
}

test "formatCwd: bare su encoding doesn't produce double-colon" {
    var f = Frame{ .kind = .su };
    f.setName("su");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("su:/home/me", formatCwd(&f, &buf, "/home/me"));
    try testing.expectEqualStrings("su:?", formatCwd(&f, &buf, ""));
}

test "Tracker: kubectl exec classification + namespace/context" {
    var t = Tracker.init();
    t.onCommandStart("kubectl exec --context=prod --namespace=apps -it mypod -- bash", testing.allocator, null);
    try testing.expectEqual(Kind.kubectl_exec, t.currentKind());
    try testing.expectEqualStrings("prod/apps/mypod", t.current().?.name());
}

test "Tracker: docker exec classification" {
    var t = Tracker.init();
    t.onCommandStart("docker exec -it nginx bash", testing.allocator, null);
    try testing.expectEqual(Kind.docker_exec, t.currentKind());
    try testing.expectEqualStrings("nginx", t.current().?.name());
}

test "formatCwd: ssh frame produces ssh:// URI without double-slash" {
    var f = Frame{ .kind = .ssh };
    f.setName("foo@bar");
    f.setCwd("/home/foo");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("ssh://foo@bar/home/foo", formatCwd(&f, &buf, "/local/cwd"));
}

test "formatCwd: ssh frame without cwd uses `?`" {
    var f = Frame{ .kind = .ssh };
    f.setName("foo@bar");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("ssh://foo@bar/?", formatCwd(&f, &buf, "/local/cwd"));
}

test "formatCwd: kubectl frame" {
    var f = Frame{ .kind = .kubectl_exec };
    f.setName("prod/apps/mypod");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("k8s://prod/apps/mypod/?", formatCwd(&f, &buf, "/local/cwd"));
}

test "formatCwd: elevation frame prepends sudo: to local cwd" {
    var f = Frame{ .kind = .elevation };
    f.setName("sudo");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("sudo:/home/me", formatCwd(&f, &buf, "/home/me"));
}

test "formatCwd: elevation with empty fallback uses ? placeholder (not trailing colon)" {
    var f = Frame{ .kind = .elevation };
    f.setName("sudo");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("sudo:?", formatCwd(&f, &buf, ""));
}

test "formatCwd: su with empty fallback also uses ? placeholder" {
    var f = Frame{ .kind = .su };
    f.setName("su:postgres");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("su:postgres:?", formatCwd(&f, &buf, ""));
}

test "formatCwd: none frame falls back to local cwd verbatim" {
    var f = Frame{ .kind = .none };
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/me", formatCwd(&f, &buf, "/home/me"));
}

// Pull in sibling parse-tests so `unit_tests.zig`'s single
// `_ = @import("subprocess.zig")` line discovers them.
test {
    _ = parse;
}
