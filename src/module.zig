//! Shared types for the comptime module framework.
//!
//! A "module" in atty is a Zig type — typically produced by a
//! `configure(comptime cfg: Config) type` factory — that exposes some
//! subset of:
//!
//!     pub const Runtime  : type
//!     pub fn   attach    (allocator) !Runtime
//!     pub fn   detach    (rt: *Runtime) void
//!     pub fn   onInput   (rt: *Runtime, ctx: *Context, input: []const u8) !Action
//!     pub fn   onOutput  (rt: *Runtime, ctx: *Context, output: []const u8) !void
//!     pub fn   onTick    (rt: *Runtime, ctx: *Context, elapsed_ms: u64) !void
//!     pub fn   provideGhostText(rt: *Runtime, ctx: *Context) !?[]const u8
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
};

/// Context passed to every hook. Pointers, not copies — the dispatcher
/// owns the underlying memory for the lifetime of the call.
pub const Context = struct {
    allocator: std.mem.Allocator,
    /// Current best-effort model of the user's input line.
    line: *LineState,
    /// Per-event scratch buffer. Modules may write into it (e.g. to
    /// stage a `.replace` payload or a ghost-text suggestion) — the
    /// buffer's contents are valid until the next dispatch call.
    scratch: *std.ArrayList(u8),
    /// True when stdin/stdout are real TTYs. Modules can use this to
    /// skip work in non-interactive runs.
    is_tty: bool,
};
