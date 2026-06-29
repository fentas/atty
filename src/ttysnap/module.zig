//! The ttysnap module contract — the "what can plug into a TTY test" surface.
//!
//! This is the test-lifecycle sibling of atty's proxy `module.zig` and attop's
//! `panel.zig`. Same Suckless idea: a module is a TYPE with a `Runtime` plus a
//! set of OPTIONAL hooks discovered by `@hasDecl` at comptime, composed into a
//! single binary through a tuple in `config.zig`. No vtables, no `*anyopaque`,
//! no runtime branch on the module list — a module contributes zero code for
//! the hooks it doesn't declare, and removing it from the tuple removes it from
//! the binary entirely.
//!
//! Where it DIFFERS from the proxy: the proxy's modules are stream middleware
//! sitting in a live PTY (`onInput`/`onOutput` transform bytes in flight). A
//! ttysnap module is an OBSERVER + a fault INJECTOR around a child the ttysnap
//! drives — it watches the output, the rendered screen, and named checkpoints,
//! and it may perturb the read schedule. So the hook SET is different even
//! though the composition machinery is the same.
//!
//! ## Lifecycle (the order hooks fire)
//!
//!   attach            once, right after the child is spawned
//!   ── then, repeatedly, as the ttysnap pumps output ──
//!   beforeRead        before each master read — may shrink the read (fault
//!                     injection); the ttysnap uses the SMALLEST cap any
//!                     module asks for
//!   onOutput          after a chunk is read + fed to the screen grid (raw
//!                     bytes — for recorders / loggers)
//!   onFrame           after that same chunk — the new screen state (for
//!                     frame / GIF recorders, diff observers)
//!   onInput           whenever the driver sends bytes to the child
//!   onSnapshot        at a named checkpoint the driver requests (assert /
//!                     capture a golden); may return an error to fail the run
//!   ── at teardown ──
//!   onExit            when the child exits (with its wait status)
//!   detach            once, as the ttysnap tears down (free `attach`'s state)
//!
//! ## Hook shape (each guarded by `@hasDecl`)
//!
//!   pub const Runtime = struct { … }                     // per-module state
//!   pub fn attach(allocator, info: SessionInfo) !Runtime // REQUIRED
//!   pub fn detach(rt: *Runtime) void                     // optional
//!   pub fn beforeRead(rt: *Runtime, want: usize) usize   // optional — cap ≤ want
//!   pub fn onOutput(rt: *Runtime, bytes: []const u8) void// optional
//!   pub fn onFrame(rt: *Runtime, grid: *const Grid) void // optional
//!   pub fn onInput(rt: *Runtime, bytes: []const u8) void // optional
//!   pub fn onSnapshot(rt: *Runtime, name: []const u8, grid: *const Grid) !void // optional
//!   pub fn onExit(rt: *Runtime, status: u32) void        // optional
//!
//! ## Configuring a module
//!
//! A module that needs parameters is a comptime FACTORY returning a type —
//! `fragment_injector(.{ .bytes = 16 })`, `cast_recorder(.{ .path = "x.cast" })`
//! — exactly like atty's `Module(cfg)` modules. A parameter-free module is a
//! plain `pub const`. Either way the result is a type placed in the
//! `config.zig` `modules` tuple; the ttysnap instantiates one `Runtime` per
//! entry.
//!
//! ## Writing one (minimal)
//!
//!   pub const my_logger = struct {
//!       pub const Runtime = struct { n: usize = 0 };
//!       pub fn attach(_: std.mem.Allocator, _: ttysnap.SessionInfo) !Runtime {
//!           return .{};
//!       }
//!       pub fn onOutput(rt: *Runtime, bytes: []const u8) void {
//!           rt.n += bytes.len;
//!       }
//!   };
//!
//! Drop it into the `modules` tuple in `config.zig`, recompile — done.

const std = @import("std");
const vt = @import("vt");

/// The screen-grid emulator the ttysnap renders output into. Re-exported so a
/// module's `onFrame` / `onSnapshot` only ever imports the contract, never the
/// emulator directly.
pub const Grid = vt.Grid;

/// Read-only facts about the child, handed to every module at `attach` so it
/// can size buffers / headers (a cast recorder needs `cols`×`rows`, etc.).
/// Lives for the whole session; `argv` points at the caller's spawn options.
pub const SessionInfo = struct {
    /// The spawned command + its arguments (argv[0] is the program).
    argv: []const []const u8,
    cols: u16,
    rows: u16,
};

/// Monotonic milliseconds — the ttysnap's deadline + the recorder's event
/// clock. `.MONOTONIC` resolves the OS-correct clockid_t (matches the proxy /
/// statusbar idiom); immune to wall-clock adjustments mid-run.
pub fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}
