//! Tests for `subprocess.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("subprocess.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const parse = @import("subprocess/parse.zig");

// Re-binds of pub decls so test bodies stay short.
const formatCwd = mod.formatCwd;
const Frame = mod.Frame;
const Kind = mod.Kind;
const max_cwd_bytes = mod.max_cwd_bytes;
const max_depth = mod.max_depth;
const Tracker = mod.Tracker;

// ===========================================================================
// Tests
// ===========================================================================

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
