//! ttysnap configuration — committed template (dwm `config.def.h` style).
//!
//! `build.zig` copies this to `config.zig` (gitignored) on first build; edit
//! THAT for your overrides — `git pull` then won't fight your edits. This is
//! the Suckless-extensible surface: to change the composed ttysnap, edit the
//! `modules` tuple and recompile. No runtime plugin loader, no flags — the
//! binary IS the configured ttysnap.
//!
//! A module is any type with the hook shape documented in `module.zig`
//! (`Runtime` + `attach`, plus optional `beforeRead` / `onOutput` / `onInput`
//! / `onFrame` / `onSnapshot` / `onExit` / `detach`). Parameterised modules are
//! comptime factories — call them here with their config. Write your own in
//! `modules/` (or anywhere) and drop it into the tuple.

const cast_recorder = @import("modules/cast_recorder.zig").cast_recorder;
const snapshotter = @import("modules/snapshotter.zig").snapshotter;
const fragment_injector = @import("modules/fragment_injector.zig").fragment_injector;

/// The composed ttysnap — observers + fault injectors, comptime-walked by
/// `Harness(modules)`. Tuple ORDER is the fan order for the output / snapshot
/// hooks (and `beforeRead` takes the smallest cap across all entries).
pub const modules = .{
    // Record the session to an asciinema cast you can replay.
    cast_recorder(.{ .path = "ttysnap-run.cast" }),

    // Assert the screen against goldens at `snapshot(name)` checkpoints.
    // snapshotter(.{ .dir = "tests/golden" }),

    // Fault injection: split the child's output across small reads so
    // fragmentation races reproduce deterministically (no CI load needed).
    // fragment_injector(.{ .bytes = 16 }),
};
