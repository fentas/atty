//! Comptime dispatch — the Suckless secret sauce.
//!
//! `Dispatcher(modules)` is a factory that, given a comptime tuple of
//! module *types*, produces a namespace with:
//!
//!   • `Runtimes` — a comptime-generated heterogeneous tuple struct,
//!     one field per module holding that module's `Runtime`.
//!   • `attachAll` / `detachAll` — lifecycle.
//!   • `dispatchInput` / `dispatchOutput` / `gatherGhostText` / `dispatchTick`
//!     — fan-out the corresponding hook into every module that
//!     declares it.
//!
//! Every hook lookup goes through `@hasDecl` at comptime, so modules
//! that don't implement a hook contribute *zero* bytes of code to the
//! relevant dispatch loop. If you delete a module from the config
//! tuple, every line of its onInput/onOutput/onTick handler vanishes
//! from the binary.
//!
//! There is no vtable, no `*anyopaque` pointer, no runtime branch on
//! the module list — `inline for` unrolls everything at compile time.

const std = @import("std");
const module = @import("module.zig");
const keymap = @import("keymap.zig");
const mouse_mod = @import("mouse.zig");

pub const Action = module.Action;
pub const Context = module.Context;
pub const Error = module.Error;

/// Module-side reply to `onMouseClick`. `consume` stops the
/// dispatch chain + tells the proxy NOT to forward the
/// underlying CSI sequence; `passthrough` lets later modules
/// + the shell see the click.
pub const MouseAction = enum { passthrough, consume };

/// Build a dispatcher specialised on a comptime tuple of module types.
///
/// Usage:
///     const D = Dispatcher(.{ Guardrail, Atuin });
///     var rts = try D.attachAll(allocator);
///     defer D.detachAll(allocator, &rts);
///     ...
pub fn Dispatcher(comptime modules: anytype) type {
    const N = modules.len;

    return struct {
        /// Heterogeneous tuple of *pointers* to each module's runtime.
        ///
        /// We store pointers (not values) for two reasons:
        ///   1. Each runtime lives at a stable heap address — modules
        ///      can hold long-lived self-references (e.g. the Atuin
        ///      worker thread captures `*Shared`).
        ///   2. Zig's strict "no comptime-var pointer at runtime" check
        ///      fires when dispatch code computes `&tuple[i]` for a
        ///      value tuple. Storing pointers means we just read them.
        pub const Runtimes = blk: {
            var types: [N]type = undefined;
            for (modules, 0..) |M, i| types[i] = *M.Runtime;
            break :blk std.meta.Tuple(&types);
        };

        // ---------------------------------------------------------------------
        // Lifecycle
        // ---------------------------------------------------------------------

        pub fn attachAll(allocator: std.mem.Allocator, io: std.Io) !Runtimes {
            var rts: Runtimes = undefined;
            var attached: usize = 0;
            errdefer detachUpTo(allocator, io, &rts, attached);

            inline for (modules, 0..) |M, i| {
                const slot = try allocator.create(M.Runtime);
                slot.* = M.attach(allocator, io) catch |err| {
                    allocator.destroy(slot);
                    return err;
                };
                rts[i] = slot;
                attached = i + 1;
            }
            return rts;
        }

        pub fn detachAll(allocator: std.mem.Allocator, io: std.Io, rts: *Runtimes) void {
            detachUpTo(allocator, io, rts, N);
        }

        fn detachUpTo(allocator: std.mem.Allocator, io: std.Io, rts: *Runtimes, count: usize) void {
            inline for (modules, 0..) |M, i| {
                if (i < count) {
                    if (comptime @hasDecl(M, "detach")) M.detach(rts[i], io);
                    allocator.destroy(rts[i]);
                }
            }
        }

        // ---------------------------------------------------------------------
        // Hooks
        // ---------------------------------------------------------------------

        /// Walk modules front-to-back. First .swallow short-circuits;
        /// .replace updates the byte slice for downstream modules.
        pub fn dispatchInput(
            rts: *Runtimes,
            ctx: *Context,
            input: []const u8,
        ) Error!Action {
            var current = input;
            var final_action: Action = .forward;
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "onInput")) {
                    switch (try M.onInput(rts[i], ctx, current)) {
                        .forward => {},
                        .swallow => return .swallow,
                        .replace => |b| {
                            current = b;
                            // Don't downgrade an earlier
                            // .replace_commit — once a module
                            // asks for the commit to fire, that
                            // decision sticks. Only the bytes get
                            // overwritten by later .replace.
                            final_action = switch (final_action) {
                                .replace_commit => .{ .replace_commit = b },
                                else => .{ .replace = b },
                            };
                        },
                        .replace_commit => |b| {
                            current = b;
                            final_action = .{ .replace_commit = b };
                        },
                    }
                }
            }
            return final_action;
        }

        /// Observe-only fan-out. Modules cannot mutate shell output
        /// (that would corrupt the terminal's ANSI state machine).
        pub fn dispatchOutput(
            rts: *Runtimes,
            ctx: *Context,
            output: []const u8,
        ) Error!void {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "onOutput")) {
                    try M.onOutput(rts[i], ctx, output);
                }
            }
        }

        /// First non-null suggestion wins. Order modules in the config
        /// to express priority.
        pub fn gatherGhostText(
            rts: *Runtimes,
            ctx: *Context,
        ) Error!?[]const u8 {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "provideGhostText")) {
                    if (try M.provideGhostText(rts[i], ctx)) |text| return text;
                }
            }
            return null;
        }

        /// First non-null hint wins. One-shot semantics — modules
        /// implementing `provideHintText` are expected to return the
        /// text once and `null` thereafter (no re-painting). The
        /// proxy hands the result to the statusbar's hint row,
        /// which manages TTL/clearance from there.
        pub fn gatherHintText(
            rts: *Runtimes,
            ctx: *Context,
        ) Error!?[]const u8 {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "provideHintText")) {
                    if (try M.provideHintText(rts[i], ctx)) |text| return text;
                }
            }
            return null;
        }

        /// Bytes a module wants written to the user's outer
        /// terminal (NOT the pty.master, which would go to the
        /// child shell). Used for OSC sequences that should affect
        /// the user's terminal — cursor colour transitions, palette
        /// hints, title updates. One-shot per transition: modules
        /// should return non-null only on edge changes, not on
        /// every tick. First non-null wins, same as the other
        /// `gather*` walkers.
        pub fn gatherTermBytes(
            rts: *Runtimes,
            ctx: *Context,
        ) Error!?[]const u8 {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "provideTermBytes")) {
                    if (try M.provideTermBytes(rts[i], ctx)) |bytes| return bytes;
                }
            }
            return null;
        }

        /// Returns true when any module's `isOverlayActive` hook
        /// reports an open atty-controlled alt-screen overlay on
        /// the user's outer terminal. The proxy uses this to:
        ///   - mirror the bool onto `ctx.module_overlay_active`
        ///   - capture PTY-master bytes into a ring buffer instead
        ///     of writing them to stdout (so shell output during
        ///     the overlay doesn't clobber the painted alt-screen)
        ///   - suspend statusbar repaints (same reason)
        ///
        /// First module reporting true wins; short-circuits the
        /// iteration.
        pub fn anyOverlayActive(rts: *Runtimes) bool {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "isOverlayActive")) {
                    if (M.isOverlayActive(rts[i])) return true;
                }
            }
            return false;
        }

        /// Mirror of `anyOverlayActive` for inline panels — modules
        /// that grow the statusbar reservation report via
        /// `isInlineChatActive`. The proxy uses this to suppress
        /// surfaces that would otherwise paint inside the panel
        /// (ghost text, ghost list).
        pub fn anyInlineChatActive(rts: *Runtimes) bool {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "isInlineChatActive")) {
                    if (M.isInlineChatActive(rts[i])) return true;
                }
            }
            return false;
        }

        /// Comptime-concatenate every module's `default_bindings`
        /// decl into a single slice. Modules opt in by declaring a
        /// `pub const default_bindings: []const keymap.Binding = &.{ ... }`
        /// at the top level — the dispatcher pulls them all into the
        /// global keymap so each module owns the documentation +
        /// defaults for the keys it cares about.
        ///
        /// The proxy uses the result alongside `config.keymap.bindings`:
        ///   - User config bindings (`config.keymap.bindings`) win
        ///     because they're scanned first by `keymap.match`.
        ///   - Module bindings are the fallback for any key the user
        ///     hasn't claimed.
        /// So a user can rebind any module action without editing the
        /// module, AND new modules can add bindings without forcing
        /// the user to edit their config to enable them.
        pub const all_default_bindings: []const keymap.Binding = blk: {
            var list: []const keymap.Binding = &.{};
            for (modules) |M| {
                if (@hasDecl(M, "default_bindings")) list = list ++ M.default_bindings;
            }
            break :blk list;
        };

        /// Backwards-compatible accessor wrapping `all_default_bindings`.
        /// Prefer the const directly when called from comptime.
        pub fn allDefaultBindings() []const keymap.Binding {
            return all_default_bindings;
        }

        /// Saturating sum of every module's `extraReserveRows` hook.
        /// The proxy clamps the result to `rows-1` before applying.
        pub fn extraReserveRows(rts: *Runtimes) u16 {
            var total: u16 = 0;
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "extraReserveRows")) {
                    total = std.math.add(u16, total, M.extraReserveRows(rts[i])) catch std.math.maxInt(u16);
                }
            }
            return total;
        }

        /// Notify size-aware modules that the terminal just resized
        /// (after SIGWINCH + statusbar re-activate). Modules with an
        /// `onResize` hook re-arm their paint latch so the next
        /// term-bytes tick repaints at the new geometry.
        ///
        /// **Signature contract**: modules must declare
        /// `pub fn onResize(rt: *Runtime) void` — single-argument.
        /// Don't confuse with `StatusBar.onResize(rows, cols)` in
        /// `src/statusbar.zig` which is statusbar-internal and takes
        /// the new dimensions; the dispatcher pulls fresh dimensions
        /// off `Context` instead, so module hooks need none. A
        /// future module-side declaration with extra args would
        /// silently bind only `rt` here.
        pub fn notifyResize(rts: *Runtimes) void {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "onResize")) {
                    M.onResize(rts[i]);
                }
            }
        }

        /// Fan out a mouse click event to modules that implement
        /// `onMouseClick`. First module to return `.consume` wins —
        /// the proxy then drops the underlying CSI sequence
        /// (doesn't forward to the shell). Modules returning
        /// `.passthrough` let later modules + the shell see it.
        ///
        /// Iteration is module-declaration order — same precedence
        /// rule as `dispatchInput`. A module that opens a clickable
        /// overlay should consume to stop the shell from also
        /// reacting to the click.
        ///
        /// **Signature contract**: modules declare
        /// `pub fn onMouseClick(rt: *Runtime, ctx: *Context, evt: mouse.Event) Error!MouseAction`.
        pub fn dispatchMouseClick(
            rts: *Runtimes,
            ctx: *Context,
            evt: mouse_mod.Event,
        ) Error!MouseAction {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "onMouseClick")) {
                    switch (try M.onMouseClick(rts[i], ctx, evt)) {
                        .passthrough => {},
                        .consume => return .consume,
                    }
                }
            }
            return .passthrough;
        }

        /// Sibling of `gatherHintText` for error notifications.
        /// Same one-shot, first-non-null semantics, but the proxy
        /// pushes the result into the statusbar's *error* slot which
        /// renders in `error_style` (muted red + ⚠ glyph) and takes
        /// precedence over regular hints. Lets modules surface
        /// transient failures (LLM endpoint unreachable, HTTP non-2xx,
        /// guardrail block, …) without polluting the explanation
        /// channel.
        pub fn gatherErrorText(
            rts: *Runtimes,
            ctx: *Context,
        ) Error!?[]const u8 {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "provideErrorText")) {
                    if (try M.provideErrorText(rts[i], ctx)) |text| return text;
                }
            }
            return null;
        }

        /// First non-null list wins, same precedence model as
        /// gatherGhostText. Used by the multi-suggestion overlay
        /// rendered below the prompt (see `Config.ghost.list_count`).
        /// The returned slice is borrowed from the module's storage
        /// (typically `ctx.scratch` or runtime-owned memory) and must
        /// stay valid until the next dispatch call.
        pub fn gatherGhostList(
            rts: *Runtimes,
            ctx: *Context,
        ) Error!?[]const []const u8 {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "provideGhostList")) {
                    if (try M.provideGhostList(rts[i], ctx)) |entries| return entries;
                }
            }
            return null;
        }

        /// Fired exactly once per Enter-press, after applyInput has
        /// cleared the line. `line` is the pre-Enter content — modules
        /// use it for history recording, audit logs, etc. We do not
        /// fire on uncertain commits (arrow-key history nav, multi-line
        /// continuations, …) — recording a wrong line is worse than
        /// missing one.
        pub fn dispatchLineCommit(
            rts: *Runtimes,
            ctx: *Context,
            line: []const u8,
        ) Error!void {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "onLineCommit")) {
                    try M.onLineCommit(rts[i], ctx, line);
                }
            }
        }

        /// Fire `deleteHistoryMatch` on every module that implements
        /// it. Used by the proxy when the user triggers the
        /// `delete_history_match` keymap action. Modules without the
        /// hook are silently skipped (no-op at comptime).
        pub fn dispatchDeleteHistoryMatch(
            rts: *Runtimes,
            ctx: *Context,
            line: []const u8,
        ) Error!void {
            // Each module owns its own backing store (atuin's DB,
            // ~/.bash_history, …). A failure in one (missing CLI,
            // locked file, network error, schema mismatch) MUST NOT
            // block the others from also deleting — otherwise the
            // ghost the user is trying to erase keeps reappearing
            // from the module further down the chain. We swallow
            // per-iteration errors instead of `try`-ing them and
            // short-circuiting the fan-out.
            //
            // The function still returns `Error!void` for symmetry
            // with the other dispatch walkers, but at runtime no
            // module's error escapes — best-effort delete across
            // every store the user has enabled.
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "deleteHistoryMatch")) {
                    M.deleteHistoryMatch(rts[i], ctx, line) catch {};
                }
            }
        }

        /// Collect each module's `statusText` (if implemented) into
        /// the writer, separating segments with ` │ `. Used by the
        /// proxy's bottom status bar to paint a shared canvas — every
        /// participating module contributes one segment, in module-
        /// declaration order. Modules returning null are skipped.
        pub fn gatherStatus(
            rts: *Runtimes,
            ctx: *Context,
            w: *std.Io.Writer,
        ) Error!void {
            var any = false;
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "statusText")) {
                    if (try M.statusText(rts[i], ctx)) |text| {
                        if (text.len > 0) {
                            // Truncate silently if the buffer is full —
                            // status bar always has finite width anyway.
                            if (any) w.writeAll(" │ ") catch return;
                            w.writeAll(text) catch return;
                            any = true;
                        }
                    }
                }
            }
        }

        /// Fired on poll() timeout. Modules use this for periodic
        /// work: ghost-text TTL expiry, status indicators, etc.
        pub fn dispatchTick(
            rts: *Runtimes,
            ctx: *Context,
            elapsed_ms: u64,
        ) Error!void {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "onTick")) {
                    try M.onTick(rts[i], ctx, elapsed_ms);
                }
            }
        }

        /// Fired on poll() timeout. Lets a module surface bytes
        /// to inject into the shell's stdin (pty.master) when its
        /// own state machine has produced something asynchronously
        /// — e.g. the LLM module's response coming back from a
        /// worker thread several seconds after the user's Enter
        /// was swallowed. The returned slice (if any) is written
        /// to pty.master verbatim; the module owns the storage and
        /// keeps it alive until the next call.
        ///
        /// First non-null wins, same precedence model as
        /// gatherGhostText. Most modules don't implement this and
        /// the loop is comptime-eliminated for them.
        pub fn pollShellInput(
            rts: *Runtimes,
            ctx: *Context,
        ) Error!?[]const u8 {
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "pollShellInput")) {
                    if (try M.pollShellInput(rts[i], ctx)) |bytes| return bytes;
                }
            }
            return null;
        }

        /// Dispatch a keymap-matched `Action` to every module that
        /// implements `onAction`. Used by the proxy when a binding
        /// fires for actions whose semantics live in a module (e.g.
        /// `llm_exec_*`). Module decides whether to handle it (e.g.
        /// the llm module ignores ghost_accept, the history module
        /// ignores llm_exec_dialog).
        ///
        /// Returns true if ANY module reported it consumed the
        /// action. The proxy uses that to decide whether to swallow
        /// the binding bytes — when no module consumed (e.g. Alt+A
        /// pressed outside AI mode, or the llm module isn't
        /// configured), the bytes flow through to readline / the
        /// inner program so meta-key shortcuts still work where the
        /// user expects them.
        ///
        /// Per-module errors are SILENTLY swallowed and treated as
        /// "not consumed". We deliberately don't log to stderr
        /// here: in a PTY proxy, stderr is the user's actual
        /// terminal screen, and writing raw `[atty] …` diagnostic
        /// text would corrupt the rendered grid (overlap with the
        /// status bar / ghost overlays, scroll mid-frame). Same
        /// reasoning the rest of the codebase already follows —
        /// no production code path uses `std.debug.print`.
        /// Future: route errors through a debug-trace facility
        /// behind an env var when one exists.
        pub fn dispatchAction(
            rts: *Runtimes,
            ctx: *Context,
            action: anytype,
        ) bool {
            var consumed = false;
            inline for (modules, 0..) |M, i| {
                if (comptime @hasDecl(M, "onAction")) {
                    const result = M.onAction(rts[i], ctx, action) catch false;
                    if (result) consumed = true;
                }
            }
            return consumed;
        }
    };
}

// ===========================================================================
// Tests — extracted to `dispatch_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("dispatch_tests.zig");
}
