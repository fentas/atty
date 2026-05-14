//! Shared types for the comptime module framework.
//!
//! A "module" in atty is a Zig type — typically produced by a
//! `configure(comptime cfg: Config) type` factory — that exposes some
//! subset of:
//!
//!     pub const Runtime  : type
//!     pub fn   attach    (allocator: std.mem.Allocator, io: std.Io) !Runtime
//!     pub fn   detach    (rt: *Runtime, io: std.Io) void
//!     pub fn   onInput   (rt: *Runtime, ctx: *Context, input: []const u8) !Action
//!     pub fn   onOutput  (rt: *Runtime, ctx: *Context, output: []const u8) !void
//!     pub fn   onTick    (rt: *Runtime, ctx: *Context, elapsed_ms: u64) !void
//!     pub fn   onLineCommit(rt: *Runtime, ctx: *Context, line: []const u8) !void
//!     pub fn   deleteHistoryMatch(rt: *Runtime, ctx: *Context, line: []const u8) !void
//!     pub fn   provideGhostText(rt: *Runtime, ctx: *Context) !?[]const u8
//!     pub fn   provideGhostList(rt: *Runtime, ctx: *Context) !?[]const []const u8
//!     pub fn   pollShellInput(rt: *Runtime, ctx: *Context) !?[]const u8
//!     pub fn   provideHintText(rt: *Runtime, ctx: *Context) !?[]const u8
//!     pub fn   provideErrorText(rt: *Runtime, ctx: *Context) !?[]const u8
//!     pub fn   provideTermBytes(rt: *Runtime, ctx: *Context) !?[]const u8
//!     pub fn   statusText(rt: *Runtime, ctx: *Context) !?[]const u8
//!     pub const name: []const u8                          // optional, for logs
//!
//! The framework introspects each module via `@hasDecl` at comptime —
//! missing hooks are statically eliminated from the dispatch loop, not
//! merely skipped at runtime.
//!
//! This file owns only the *shared* types (Action, Context, Error) that
//! every hook signature mentions. Modules themselves live in
//! `src/modules/`.

const std = @import("std");
const LineState = @import("line_state.zig").LineState;
const subprocess_mod = @import("subprocess.zig");

pub const Error = error{
    ModuleFailed,
    OutOfMemory,
};

/// What a module decides about a keystroke.
pub const Action = union(enum) {
    /// Pass the bytes through to the next module / the PTY.
    forward,
    /// Drop the bytes entirely. Short-circuits the chain.
    swallow,
    /// Replace the bytes; later modules see the substitute. The slice
    /// must live until the proxy has written it to the PTY (typically:
    /// owned by the module itself, or by `ctx.scratch`).
    replace: []const u8,
    /// Like `replace`, but ALSO commits the original (pre-replace)
    /// line to history. Used by modules that intercept Enter to do
    /// something custom but still want atuin / history etc. to
    /// record what the user typed — e.g. the LLM module replaces
    /// `#: list files\n` with Ctrl+U (kills the readline buffer)
    /// while telling the proxy to fire `dispatchLineCommit` on the
    /// pre-Ctrl+U typed line so the prompt lands in history and
    /// becomes a ghost suggestion next time.
    replace_commit: []const u8,
};

/// Context passed to every hook. Pointers, not copies — the dispatcher
/// owns the underlying memory for the lifetime of the call.
pub const Context = struct {
    allocator: std.mem.Allocator,
    /// Threadsafe I/O instance — needed for std.Io.Mutex/Condition and
    /// any synchronous std.process.run calls modules want to make.
    io: std.Io,
    /// Current best-effort model of the user's input line.
    line: *LineState,
    /// Per-event scratch buffer. Modules may write into it (e.g. to
    /// stage a `.replace` payload or a ghost-text suggestion) — the
    /// buffer's contents are valid until the next dispatch call.
    scratch: *std.ArrayList(u8),
    /// True when stdin/stdout are real TTYs. Modules can use this to
    /// skip work in non-interactive runs.
    is_tty: bool,
    /// True while the user has toggled incognito mode on. The proxy
    /// already gates `dispatchLineCommit` for the recording step
    /// (atuin / history skip writes). This field exists so a module
    /// can opt in to *stricter* behavior if it wants — e.g. suppress
    /// its own suggestions while typing a secret. Default behavior
    /// (ghost text keeps working) matches what most fish/zsh users
    /// expect; incognito is about not *recording*, not about hiding.
    incognito: bool = false,
    /// The subprocess the user is currently inside, if any. Driven
    /// by the proxy's OSC 133 `;C` / `;D` handling — at `;C` we parse
    /// the just-committed line for recognised launchers (ssh / mosh
    /// / sudo bash / kubectl exec / docker exec / lxc exec / su) and
    /// push a frame; at `;D` we pop. Modules that record committed
    /// lines (atuin, history) read this via `subprocessCwd()` so
    /// they can encode the remote target into the `--cwd` they ship
    /// to their backing store, e.g. `ssh://user@host/remote-cwd`.
    /// Null = nothing pushed yet OR we're at the local prompt.
    subprocess: ?*const subprocess_mod.Tracker = null,

    /// Shell-side cursor row (1-based), or null when the proxy
    /// hasn't wired the tracker (unit tests, non-TTY runs). Driven
    /// by `cursor_tracker.zig`, fed every byte the shell writes to
    /// stdout. Modules can use it to decide overlay placement —
    /// e.g. a future dynamic statusbar that lives at the top when
    /// the prompt is near the bottom and vice versa. Don't rely on
    /// exact column accuracy: column isn't tracked, and the row is
    /// approximate when the shell uses save/restore-cursor or its
    /// own DECSTBM.
    cursor_row: ?u16 = null,

    /// Convenience wrapper around `formatCwd` — modules call this
    /// from `onLineCommit` when they want a `--cwd` string that
    /// reflects the user's current location. When subprocess is
    /// null OR `currentKind() == .none`, returns `fallback` verbatim
    /// (typically the shell's real cwd, or the empty string).
    /// Otherwise returns an encoded URI scoped to the subprocess.
    ///
    /// `out` is caller-owned scratch — should be at least
    /// `subprocess_mod.max_cwd_bytes` (1024) to avoid silent
    /// truncation in the worst case (full-length frame name +
    /// remote cwd + URI scheme). The returned slice points into
    /// `out`.
    pub fn subprocessCwd(
        self: *const Context,
        out: []u8,
        fallback: []const u8,
    ) []const u8 {
        const tr = self.subprocess orelse return fallback;
        const top = tr.current() orelse return fallback;
        if (top.kind == .none) return fallback;
        return subprocess_mod.formatCwd(top, out, fallback);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "subprocessCwd: null tracker → fallback" {
    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    var ctx = Context{
        .allocator = testing.allocator,
        .io = undefined,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/home/me", ctx.subprocessCwd(&buf, "/home/me"));
}

test "subprocessCwd: empty tracker → fallback" {
    var tr = subprocess_mod.Tracker.init();
    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    var ctx = Context{
        .allocator = testing.allocator,
        .io = undefined,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
        .subprocess = &tr,
    };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/home/me", ctx.subprocessCwd(&buf, "/home/me"));
}

test "subprocessCwd: ssh frame → ssh:// URI" {
    var tr = subprocess_mod.Tracker.init();
    tr.onCommandStart("ssh foo@bar", testing.allocator, null);
    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    var ctx = Context{
        .allocator = testing.allocator,
        .io = undefined,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
        .subprocess = &tr,
    };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("ssh://foo@bar/?", ctx.subprocessCwd(&buf, "/home/me"));
}

test "subprocessCwd: ssh frame with OSC 7 cwd → ssh://host/path (no double slash)" {
    var tr = subprocess_mod.Tracker.init();
    tr.onCommandStart("ssh foo@bar", testing.allocator, null);
    tr.onRemoteCwd("file://bar/srv/app");
    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    var ctx = Context{
        .allocator = testing.allocator,
        .io = undefined,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
        .subprocess = &tr,
    };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("ssh://foo@bar/srv/app", ctx.subprocessCwd(&buf, "/home/me"));
}

test "subprocessCwd: kind=.none frame falls back" {
    var tr = subprocess_mod.Tracker.init();
    tr.onCommandStart("ls -la", testing.allocator, null);
    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    var ctx = Context{
        .allocator = testing.allocator,
        .io = undefined,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
        .subprocess = &tr,
    };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/home/me", ctx.subprocessCwd(&buf, "/home/me"));
}
