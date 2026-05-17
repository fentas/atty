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

pub const Author = @import("line_state.zig").Author;

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
    /// True when the user's shell is currently in alt-screen mode
    /// (running a TUI: nvim, k9s, less, htop, …). Driven by the
    /// proxy's `altscreen.zig` tracker watching the master→stdout
    /// stream. Modules read this to refuse opening their own
    /// overlay on top of the running TUI's alt-screen — nested
    /// alt-screen confuses the terminal and dropping the outer one
    /// on close vanishes the TUI's screen.
    ///
    /// **Freshness:** updated after each master-read, so a TUI
    /// launch / exit propagates within the next byte chunk from
    /// the shell. Modules whose only entry point is `onTick`
    /// (no master-read between TUI launch and the tick) may see
    /// the field stale by up to `cfg.proxy.tick_interval_ms`.
    /// Acceptable in practice — TUI launch always produces
    /// output before user keyboard input.
    shell_alt_screen_active: bool = false,
    /// **Forward-declared — currently always false.** Reserved for
    /// the future overlay framework: will become true when any
    /// module has an atty-controlled alt-screen overlay open on
    /// the user's outer terminal. Modules SHOULD NOT gate real
    /// behaviour on this field yet — it isn't wired through the
    /// proxy / module dispatch. The field exists now so the
    /// `Context` shape is stable; phase 2c will set/clear it on
    /// overlay open/close.
    ///
    /// Distinct from `shell_alt_screen_active`: that one tracks
    /// the SHELL's alt-screen state via the slave output stream;
    /// this one (once live) tracks atty's own overlay state on
    /// the user's terminal.
    module_overlay_active: bool = false,
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
    /// the prompt is near the bottom and vice versa.
    ///
    /// **Accuracy caveats — treat as approximate:**
    /// - Column isn't tracked at all (statusbar reservation is a
    ///   horizontal-band concept; the row alone suffices).
    /// - **Soft-wrap drift**: a long printable line that exceeds
    ///   `cols` auto-wraps in the terminal, advancing the cursor
    ///   by one row without emitting any CSI or LF. The tracker
    ///   doesn't see this and the row under-counts by however
    ///   many wraps happened. Same applies to hard tabs that
    ///   cross the right margin.
    /// - Save / restore cursor (`\x1B[s` / `\x1B[u`, `\x1B 7` /
    ///   `\x1B 8`) is not modelled. When the shell saves and
    ///   restores, the tracker keeps its current value.
    /// - DECSTBM scrolling. atty emits `\x1B[1;<effectiveRows>r`
    ///   whenever the statusbar is active, so LF at the DECSTBM
    ///   bottom scrolls within the region and the terminal's
    ///   cursor stays at that row. The proxy compensates by
    ///   capping the tracker's `max_rows` to `sb.effectiveRows()`
    ///   in that case — so the LF-advance saturates at the
    ///   right row. Shell-emitted DECSTBM (rare) is still NOT
    ///   compensated; the tracker keeps incrementing past the
    ///   bottom of that sub-region if a shell starts using one.
    ///
    /// Net: good enough for "is the prompt currently near the top
    /// of the screen?" decisions. Don't use it for pixel-precise
    /// cursor placement.
    cursor_row: ?u16 = null,

    /// Statusbar's init-time reservation (`config.statusbar.reserve_rows`),
    /// or null when there is no statusbar (non-TTY, disabled). Inline
    /// panels read this to anchor their bottom edge one row above the
    /// statusbar hint row instead of guessing the user's config.
    statusbar_base_reserve: ?u16 = null,
    /// Statusbar's CURRENT reservation, post any expansion an inline
    /// panel requested AND any proxy clamp (when the terminal would
    /// be left with <1 shell row). Null when no statusbar. Panel
    /// paints derive their top row from
    /// `terminal_rows - statusbar_reserve + 1`.
    statusbar_reserve: ?u16 = null,
    /// Terminal row count, or null when no TTY. Cached on every
    /// dispatch so modules don't have to ioctl for their own paints.
    terminal_rows: ?u16 = null,
    /// Terminal column count. Same null-on-non-TTY semantics.
    terminal_cols: ?u16 = null,

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
