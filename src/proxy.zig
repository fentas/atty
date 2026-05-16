//! The proxy event loop.
//!
//! Multiplexes:
//!   - stdin    (bytes from the user's keyboard)
//!   - master   (bytes from the child shell)
//!   - sig_pipe (self-pipe trick for SIGWINCH / SIGCHLD)
//!
//! On poll() timeout we fire `dispatchTick` so modules can do periodic
//! work (e.g. expire stale ghost-text). The tick interval is set in
//! config.zig and stays single-digit-millisecond cheap because the
//! comptime dispatcher unrolls the iteration.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const config = @import("config");
const dispatch = @import("dispatch.zig");
const module = @import("module.zig");
const io_helpers = @import("proxy/io.zig");
const containsEnter = io_helpers.containsEnter;
const writeAll = io_helpers.writeAll;
const PtmWriter = io_helpers.PtmWriter;

extern "c" fn clock_gettime(clk_id: c_int, tp: *posix.timespec) c_int;
const CLOCK_MONOTONIC: c_int = 1;

fn nowMs() i64 {
    var ts: posix.timespec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}

const Pty = @import("pty.zig").Pty;
const terminal = @import("terminal.zig");
const RawMode = terminal.RawMode;
const slaveIsHiddenInput = terminal.slaveIsHiddenInput;
const LineState = @import("line_state.zig").LineState;
const Ghost = @import("ghost.zig").Ghost;
const GhostList = @import("ghost_list.zig").GhostList;
const StatusBar = @import("statusbar.zig").StatusBar;
const ansi = @import("ansi.zig");
const style_mod = @import("style.zig");
const status_text = @import("status_text.zig");
const keymap = @import("keymap.zig");
const Osc133 = @import("osc133.zig").Osc133;
const AltScreen = @import("altscreen.zig").AltScreen;
const CursorTracker = @import("cursor_tracker.zig").CursorTracker;
const Osc7 = @import("osc7.zig").Osc7;
const subprocess_mod = @import("subprocess.zig");
const overlay_ring = @import("overlay_ring.zig");

/// The single dispatcher specialisation used by the binary. Comptime
/// expansion of `config.modules` happens here.
const D = dispatch.Dispatcher(config.modules);

const buf_size = 4096;

pub const Args = struct {
    /// argv for the child process. Sentinel-terminated.
    argv: [*:null]const ?[*:0]const u8,
    /// True iff stdin AND stdout are real TTYs at the entry point.
    ///
    /// Invariant: main.zig refuses to invoke `proxy.run` when this
    /// would be `false` (see src/main.zig). The numerous
    /// `if (args.is_tty)` gates below therefore look defensive but
    /// stay because module fixtures and the e2e harness construct
    /// `Context` values directly with `is_tty = false` and could
    /// in theory call into the proxy helpers; keeping the gates
    /// makes those code paths safe rather than tautological.
    is_tty: bool,
};

pub const ExitInfo = struct {
    exit_code: u8,
};

// ---------------------------------------------------------------------------
// Self-pipe for async signal delivery into the poll loop.
// ---------------------------------------------------------------------------

const SignalPipe = struct {
    read: posix.fd_t,
    write: posix.fd_t,

    fn init() !SignalPipe {
        var fds: [2]posix.fd_t = undefined;
        const rc = std.c.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true });
        if (rc != 0) return error.PipeFailed;
        return .{ .read = fds[0], .write = fds[1] };
    }

    fn deinit(self: *SignalPipe) void {
        _ = std.c.close(self.read);
        _ = std.c.close(self.write);
    }
};

var g_sig_pipe_write: posix.fd_t = -1;

fn sigHandler(sig: posix.SIG) callconv(.c) void {
    if (g_sig_pipe_write < 0) return;
    const tag: [1]u8 = .{@intCast(@intFromEnum(sig) & 0xFF)};
    _ = std.c.write(g_sig_pipe_write, &tag, 1);
}

fn installSignalHandlers() void {
    const sa = posix.Sigaction{
        .handler = .{ .handler = sigHandler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);
    posix.sigaction(posix.SIG.CHLD, &sa, null);

    // SIGPIPE → ignore. Writes to half-closed fds (e.g. user
    // detaches the terminal mid-overlay-paint) must surface as
    // `error.WriteFailed` from writeFully's errno gate so the
    // proxy can shut down cleanly, never as silent SIGPIPE
    // termination.
    const ign = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ign, null);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: Args) !ExitInfo {
    // Defensive guard. main.zig is the sole caller and refuses to
    // invoke us when stdio isn't a TTY (src/main.zig). A `@panic`
    // (rather than `std.debug.assert`) so the invariant survives
    // ReleaseFast/Small where assertions compile to `unreachable`.
    if (!args.is_tty) @panic("proxy.run requires args.is_tty (set by main.zig after isatty check)");

    // --- PTY + child --------------------------------------------------------
    var pty = try Pty.open(allocator);
    defer pty.deinit();

    // --- Bottom status bar (DECSTBM reserved region) ----------------------
    //
    // When enabled, slim the slave PTY's reported size by N rows so the
    // shell wraps inside the visible region, and emit DECSTBM so its
    // scrolling stays out of our reserved rows.
    //
    // The pick list NO LONGER inflates this reservation — it makes
    // its own room dynamically (LF + CUU dance, atuin Ctrl+R style)
    // on activation and frees it on deactivation. That avoids the
    // "permanent dead space at the bottom" UX complaint.
    var statusbar: ?StatusBar = null;
    if (args.is_tty and config.statusbar.enabled) {
        if (Pty.querySize(posix.STDOUT_FILENO)) |s| {
            statusbar = StatusBar.initFull(
                s.rows,
                s.cols,
                config.statusbar.reserve_rows,
                config.statusbar.style,
                config.statusbar.error_style,
                config.statusbar.hint_style,
            );
        } else |_| {}
    }

    if (args.is_tty) {
        if (Pty.querySize(posix.STDOUT_FILENO)) |s| {
            // Always hand the slave the FULL row count, not the
            // statusbar's slimmed effectiveRows(). DECSTBM (set via
            // `sb.activate`) constrains shell scrolling to the
            // non-reserved rows, but the TIOCGWINSZ reply is what
            // every inner program reads when sizing itself —
            // including TUIs that the shell forks (nvim, lazygit,
            // k9s, …). With a slim reply, the TUI queried size on
            // startup, got `real - reserve_rows`, drew its UI
            // centered for that smaller box, and stayed there even
            // after our deferred resize-to-full + SIGWINCH (the
            // dashboard plugin doesn't always redraw). Reporting
            // the full size keeps the inner TUI correctly sized
            // from the first byte it draws; bash sees the full
            // size too, which is harmless (DECSTBM still guards
            // the reserved zone from scroll, and `renderStatus`
            // repaints over any prompt-edge bleed on every tick).
            _ = pty.setSize(s) catch {};
        } else |_| {}
    }

    var sig_pipe = try SignalPipe.init();
    defer sig_pipe.deinit();
    g_sig_pipe_write = sig_pipe.write;
    defer g_sig_pipe_write = -1;

    installSignalHandlers();

    const empty_envp: [*:null]const ?[*:0]const u8 = @ptrCast(&[_:null]?[*:0]const u8{});
    const child_pid = try pty.spawn(args.argv, empty_envp);

    // --- Raw mode on our own stdin -----------------------------------------
    var raw_guard: ?RawMode = null;
    if (args.is_tty) {
        raw_guard = RawMode.enter(posix.STDIN_FILENO) catch null;
    }
    defer if (raw_guard) |*g| g.deinit();

    // --- Module runtimes ---------------------------------------------------
    var runtimes = try D.attachAll(allocator, io);
    defer D.detachAll(allocator, io, &runtimes);

    // --- Loop state --------------------------------------------------------
    var line_state = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(allocator);
    try scratch.ensureTotalCapacity(allocator, buf_size);

    var ghost = Ghost.init(allocator, config.ghost.style);
    defer ghost.deinit();

    // Multi-row pick-list overlay. Disabled until config.ghost.list_count > 0.
    var ghost_list = GhostList.init(allocator, config.ghost.list_style);
    defer ghost_list.deinit();

    // OSC 133 marker tracker — closes the history-recall gap when
    // the shell emits prompt-zone markers (Ghostty's
    // `shell-integration-features = osc-133`, ble.sh, zsh4humans,
    // VS Code shell-integration, etc.). Stays inert otherwise:
    // `active` flips on only after a well-formed 133 marker
    // arrives, and the proxy gates the line-state override on
    // that flag. Shells without integration fall through to the
    // existing keystroke tracking with no behavior change.
    var osc133_tracker = Osc133.init(allocator);
    defer osc133_tracker.deinit();

    // Cursor-Y tracker — observe-only state machine that watches
    // master→stdout for cursor-moving CSI sequences (CUP / CUU / CUD
    // / VPA / CNL / CPL) plus `\n` and updates a single u16 row.
    // Modules read `ctx.cursor_row`; future dynamic-statusbar work
    // uses it to decide top-vs-bottom placement. See
    // `docs/research/huh-vs-atty.md` for the comparison that drove
    // adding this — bubbletea / ultraviolet's full cell grid is
    // overkill for atty's needs; just the row suffices.
    //
    // `max_rows` is the SHELL-VISIBLE bottom row, not the screen's
    // physical row count. When the statusbar is active, atty emits
    // DECSTBM with `bottom = sb.effectiveRows()` — so LF at row N
    // (the DECSTBM bottom) scrolls within the region and the cursor
    // stays at N. Setting `max_rows` to `effectiveRows()` lets the
    // tracker's LF-advance clamp at the same row the terminal does,
    // keeping row consistent with what the shell sees.
    var cursor_tracker = CursorTracker.init(blk: {
        if (args.is_tty) {
            if (Pty.querySize(posix.STDOUT_FILENO)) |s| {
                if (statusbar) |sb| break :blk sb.effectiveRows();
                break :blk s.rows;
            } else |_| {}
        }
        break :blk 24;
    });

    // Alternate-screen-buffer tracker — full-screen TUIs (k9s, vim,
    // less, htop, helix, lazygit, …) swap to the alt buffer with
    // `\x1b[?1049h` and back with `?1049l`. While they're active the
    // app expects the whole terminal: no DECSTBM clipping, no
    // statusbar painted over the bottom row. The tracker watches
    // master→stdout, surfaces a transition edge each time the app
    // enters or exits, and the proxy uses that edge to flip the
    // slave PTY size + suspend / resume statusbar painting.
    var alt_screen = AltScreen.init();

    // OSC 7 cwd reports — emitted by Ghostty's shell-integration,
    // VS Code's snippet, ble.sh, zsh4humans, kitty's integration,
    // many ad-hoc PROMPT_COMMAND snippets. When the user is in
    // `ssh remote` and the remote shell sources any of them, the
    // OSC 7 bytes flow back through atty's master stream — we
    // capture the path and feed it into the subprocess tracker so
    // recorded commits get the *real* remote cwd, not just a `?`.
    var osc7_tracker = Osc7.init();

    // Subprocess-context tracker — at every OSC 133 `;C` we peek
    // at the line the user just committed and decide whether they
    // launched a recognised shell-context wrapper (ssh / mosh /
    // sudo bash / kubectl exec / docker exec / lxc exec / su).
    // The resulting stack feeds `dispatchLineCommit` so atuin /
    // history can encode the remote target into the recorded
    // entry's `--cwd` (e.g. `ssh://user@host/path`). Sub-prompts
    // inside the launched subprocess are still recorded (we drop
    // the blanket-suppress that PR #15 introduced specifically for
    // recognized launchers); typed text inside an unrecognised
    // subprocess (vim, less, psql, …) continues to be dropped.
    var subprocess_tracker = subprocess_mod.Tracker{
        .ssh_binary = config.subprocess.ssh_binary,
        .use_ssh_g = config.subprocess.use_ssh_g,
    };

    // FIFO of committed lines waiting for a matching `;C` to
    // attribute them.
    //
    // Why a FIFO and not a single slot: the stdin path runs
    // `dispatchLineCommit` + `clearLastCommitted` the moment the
    // user presses Enter, while the shell's `;C` marker doesn't
    // arrive until later in the master-output stream (after the
    // shell echoes, runs PROMPT_COMMAND, etc.). A single-slot
    // stash was enough for the typical case (one Enter, one ;C).
    // But a multi-line paste (or rapid back-to-back commits)
    // pushes several Enter bytes in one stdin read; the SHELL
    // then emits ;C per command — possibly multiple in one
    // master-output read. Without a FIFO each ;C would consume
    // the LATEST commit (overwriting), so the first commands
    // would be tagged with the LAST committed line's parse —
    // wrong attribution.
    //
    // Capacity 8 covers the realistic paste case; commits that
    // overflow get dropped from the head (oldest first) so the
    // tail stays current. Per-entry buffer 1 KiB is generous —
    // `ssh foo@bar -i ~/.ssh/key …` stays well under, and
    // truncation only loses tokens past the head (the parser
    // only needs the first token to classify).
    const max_pending_launches = 8;
    const max_launch_line = 1024;
    const PendingLaunches = struct {
        buf: [max_pending_launches][max_launch_line]u8 = undefined,
        lens: [max_pending_launches]usize = .{0} ** max_pending_launches,
        head: usize = 0,
        count: usize = 0,

        fn push(self: *@This(), line: []const u8) void {
            // Drop the oldest if we're at capacity. Drops are
            // unlikely (8 simultaneous pending commits) but a
            // pathological paste could trigger it.
            if (self.count == max_pending_launches) {
                self.head = (self.head + 1) % max_pending_launches;
                self.count -= 1;
            }
            const slot = (self.head + self.count) % max_pending_launches;
            const n = @min(line.len, max_launch_line);
            @memcpy(self.buf[slot][0..n], line[0..n]);
            self.lens[slot] = n;
            self.count += 1;
        }

        fn pop(self: *@This()) []const u8 {
            if (self.count == 0) return "";
            const n = self.lens[self.head];
            const out = self.buf[self.head][0..n];
            self.head = (self.head + 1) % max_pending_launches;
            self.count -= 1;
            return out;
        }
    };
    var pending_launches: PendingLaunches = .{};

    // PTY-master ring buffer for the overlay-active interval.
    // While any module reports `isOverlayActive == true`, atty's
    // outer terminal is in alt-screen mode and writing shell
    // output to stdout would clobber the overlay. Bytes captured
    // here are flushed back to stdout on the overlay-closed
    // transition. Drop-oldest on overflow with a count marker so
    // the user knows when output was truncated.
    var overlay_ring_state: overlay_ring.RingBuf(overlay_ring.default_size) = .{};
    var prev_overlay_active: bool = false;

    var ctx = module.Context{
        .allocator = allocator,
        .io = io,
        .line = &line_state,
        .scratch = &scratch,
        .is_tty = args.is_tty,
        .incognito = false,
        .subprocess = &subprocess_tracker,
        // Null on non-TTY runs (CI capture, piped/redirected
        // stdout). The slave's reported size is bogus there, so the
        // tracker's row would be meaningless to consumers — matches
        // the contract documented on `Context.cursor_row`.
        .cursor_row = if (args.is_tty) cursor_tracker.currentRow() else null,
    };

    var pfds = [_]posix.pollfd{
        .{ .fd = posix.STDIN_FILENO, .events = POLLIN, .revents = 0 },
        .{ .fd = pty.master, .events = POLLIN, .revents = 0 },
        .{ .fd = sig_pipe.read, .events = POLLIN, .revents = 0 },
    };

    var read_buf: [buf_size]u8 = undefined;

    // Stdout assembly buffer + fixed Writer.
    //   • ANSI sequences (ghost overlay show/clear) are written into
    //     `out_buf` via the Writer, then flushed in one std.c.write.
    //   • Shell output bypasses the writer and goes straight to STDOUT.
    var out_buf: [buf_size]u8 = undefined;

    // --- Kitty keyboard protocol (push flag 1 = disambiguate) ------------
    // Lets terminals that support it send distinct CSI sequences for
    // keys that would otherwise collide with control bytes
    // (Ctrl+Shift+I vs Tab, Ctrl+Shift+M vs Enter, …). Terminals that
    // don't understand the CSI just ignore it.
    if (args.is_tty and config.terminal.enable_kitty_keyboard) {
        _ = std.c.write(posix.STDOUT_FILENO, keymap.kitty_kbd_push.ptr, keymap.kitty_kbd_push.len);
    }
    defer if (args.is_tty and config.terminal.enable_kitty_keyboard) {
        _ = std.c.write(posix.STDOUT_FILENO, keymap.kitty_kbd_pop.ptr, keymap.kitty_kbd_pop.len);
    };

    // --- Incognito state -------------------------------------------------
    var incognito_on: bool = false;

    // Emit the initial DECSTBM + first paint of the status bar (after
    // RawMode + child spawn, before the loop runs).
    if (statusbar) |*sb| {
        var w: std.Io.Writer = .fixed(&out_buf);
        sb.activate(&w) catch {};
        try writeAll(posix.STDOUT_FILENO, out_buf[0..w.end]);
    }
    defer if (statusbar) |*sb| {
        var w: std.Io.Writer = .fixed(&out_buf);
        sb.deactivate(&w) catch {};
        _ = writeAll(posix.STDOUT_FILENO, out_buf[0..w.end]) catch {};
    };

    var exit_code: u8 = 0;
    var child_alive = true;

    var last_tick_ms = nowMs();

    while (child_alive) {
        const n = try posix.poll(&pfds, config.proxy.tick_interval_ms);

        // Overlay-state mirror — refreshed at the top of each
        // iteration so renderStatus / other consumers see a
        // current value. Edge detection (open→closed flush) runs
        // at the END of the iteration so a same-iteration toggle
        // (Alt+C inside the stdin POLLIN branch) AND the resulting
        // master-read pushes are both observed before we decide
        // whether to flush.
        ctx.module_overlay_active = D.anyOverlayActive(&runtimes);

        // ---- timeout → tick ----------------------------------------------
        if (n == 0) {
            const now = nowMs();
            const elapsed: u64 = @intCast(@max(0, now - last_tick_ms));
            last_tick_ms = now;
            D.dispatchTick(&runtimes, &ctx, elapsed) catch {};
            // Modules that produce shell input asynchronously
            // (LLM responses, future tools) surface their bytes
            // here. We write them to pty.master as if the user
            // had typed them — the shell echoes them back through
            // the master path, the user sees the result, can edit
            // / submit / cancel.
            if (D.pollShellInput(&runtimes, &ctx) catch null) |bytes| {
                if (bytes.len > 0) {
                    // Treat injected bytes as if the user had typed
                    // them: update line_state too, so the next Enter
                    // routes through onInput / onLineCommit with the
                    // injected line as `ctx.line.current()`. Without
                    // this, modules (guardrail, history) wouldn't
                    // see the LLM-generated command and the user's
                    // Enter would commit an empty line from their
                    // perspective.
                    _ = line_state.applyInput(bytes);
                    writeAll(pty.master, bytes) catch {};
                }
            }
            // One-shot hint / error surfaces — a module just
            // produced text it wants the user to see (LLM module
            // after injecting a command, or after a failure). Both
            // paint into the same row above the status text but
            // use distinct styles: errors render in `error_style`
            // (muted-red + ⚠) and take precedence; hints render in
            // `hint_style` (dim italic by default) and resurface
            // once any active error expires. TTLs are independent
            // — setting either to 0 disables that surface.
            if (statusbar) |*sb| {
                if (config.statusbar.hint_ttl_ms > 0) {
                    if (D.gatherHintText(&runtimes, &ctx) catch null) |hint_text| {
                        sb.setHint(hint_text, config.statusbar.hint_ttl_ms);
                    }
                }
                if (config.statusbar.error_ttl_ms > 0) {
                    if (D.gatherErrorText(&runtimes, &ctx) catch null) |err_text| {
                        sb.setError(err_text, config.statusbar.error_ttl_ms);
                    }
                }
            }
            // Outer-terminal byte stream — modules can push raw
            // OSC sequences (cursor colour transitions, title
            // updates, …) to the user's stdout. NOT routed through
            // pty.master because these are user-terminal concerns
            // the child shell shouldn't see. Gated on `is_tty` so
            // a non-TTY invocation (CI, piped/redirected stdout,
            // capture-the-binary integration tests) doesn't bleed
            // escape sequences into the captured stream.
            if (args.is_tty) {
                if (D.gatherTermBytes(&runtimes, &ctx) catch null) |term_bytes| {
                    if (term_bytes.len > 0) writeAll(posix.STDOUT_FILENO, term_bytes) catch {};
                }
            }
            if (!inSubprocess(&alt_screen, &osc133_tracker)) {
                renderGhost(&runtimes, &ctx, &ghost, &out_buf) catch {};
                renderGhostList(&runtimes, &ctx, &ghost_list, &out_buf) catch {};
            }
            if (statusbar) |*sb| {
                if (!alt_screen.active) renderStatus(&runtimes, &ctx, sb, &out_buf, incognito_on) catch {};
            }
            continue;
        }

        // ---- stdin → dispatch → master -----------------------------------
        if (pfds[0].revents & POLLIN != 0) {
            const read_n = posix.read(posix.STDIN_FILENO, &read_buf) catch 0;
            if (read_n > 0) {
                var input: []const u8 = read_buf[0..read_n];

                // PASSWORD-INPUT FAST PATH: when the slave PTY is in
                // canonical hidden-input mode (ICANON=on AND ECHO=off
                // — the termios signature of sudo / ssh / passwd /
                // gpg-agent / shell `read -s` / getpass(3) /
                // readpassphrase(3)), short-circuit the entire keymap
                // + dispatchInput pipeline and forward the raw bytes
                // straight to pty.master. Three reasons:
                //
                //   1. Keymap bindings (incognito_toggle on
                //      Ctrl+Shift+I, ghost_accept on Right, …) can
                //      swallow or substitute bytes. With echo off
                //      the user gets no visual feedback that this
                //      happened, so a stray binding silently
                //      corrupts password entry.
                //   2. dispatchInput modules can `.replace` or
                //      `.swallow`. Atuin / history / guardrail
                //      have no business seeing the password
                //      regardless of what line_state does.
                //   3. line_state.applyInput would still accumulate
                //      the password bytes; the fast path makes it
                //      impossible to reach line_state at all, so
                //      ctx.line.current() stays empty and
                //      ghost-text / LLM prefix signals can't query
                //      with the password as a prefix. lastCommitted
                //      can't get set, so dispatchLineCommit can't
                //      fire either.
                //
                // Critically, the gate is `ICANON && !ECHO`, NOT bare
                // `!ECHO`. Interactive shells with readline / zle
                // also drop ECHO (they handle echoing themselves) —
                // but they ALSO drop ICANON. Gating on `!ECHO` alone
                // mistook every interactive keystroke for a
                // password and silently routed all input down this
                // fast path, bypassing CSI-u translation. The user
                // saw Ctrl+C / Ctrl+D producing `9;5u` / `0;5u`
                // mojibake. See `terminal.slaveIsHiddenInput` for
                // the truth table.
                //
                // The reset + clearLastCommitted calls drop any
                // leftover state from the visible-input iteration
                // that straddled the boundary (the read before
                // sudo's tcsetattr lands) — defence in depth.
                //
                // **TOCTOU note**: `slaveIsHiddenInput` is sampled
                // once per stdin read. The child can drop into
                // password mode between the user striking a key and
                // the proxy entering this branch; any bytes already
                // in `read_buf` from before the flip were typed
                // under visible-input conditions and will be
                // processed as such. This is an inherent race (the
                // kernel doesn't signal termios changes), bounded
                // by the read's size (≤ 4 KiB) and effectively
                // limited to a handful of keystrokes in practice.
                // Acceptable cost for the redaction guarantee on
                // subsequent reads. `slaveIsHiddenInput` fails-
                // closed on tcgetattr errors → an fd error is
                // treated as "assume the worst, redact."
                if (slaveIsHiddenInput(pty.master)) {
                    // CSI-u translation still applies here even though
                    // the rest of the pipeline is skipped. With kitty
                    // kbd pushed (default), Ctrl+C / Ctrl+U / Ctrl+H
                    // arrive as `\x1b[99;5u` / `\x1b[117;5u` /
                    // `\x1b[104;5u` — the password reader (sudo /
                    // ssh / passwd / getpass / `read -s`) doesn't
                    // speak the protocol and would see mojibake
                    // instead of the cancel / line-kill byte.
                    //
                    // We use the byte-stream variant so a single
                    // `read()` that batched a password char + an
                    // embedded CSI-u (paste, burst typing across the
                    // read boundary) still has each CSI-u translated
                    // in place. Sequences with no legacy form
                    // (Ctrl+9, F-keys, …) are dropped rather than
                    // leaking raw protocol bytes into getpass.
                    const ptm_writer = PtmWriter{ .fd = pty.master };
                    try keymap.translateCsiUStream(input, config.terminal.enable_kitty_keyboard, ptm_writer);
                    line_state.reset();
                    line_state.clearLastCommitted();
                    if (statusbar) |*sb| {
                        if (!alt_screen.active) renderStatus(&runtimes, &ctx, sb, &out_buf, incognito_on) catch {};
                    }
                    continue;
                }

                // Accept-ghost keystroke: if the user's accept key
                // arrives while a ghost is visible and the line is
                // still certain, swap the keystroke for the suggestion
                // bytes — the rest of the loop then treats them as if
                // they were typed. Must happen BEFORE applyInput,
                // because a CSI like `ESC [ C` would otherwise mark
                // the line uncertain and we'd lose the chance to act.
                var accept_buf: [4096]u8 = undefined;
                var swallow_after_binding = false;
                const matched_action = keymap.match(config.keymap.bindings, input);
                // `var` so the llm-action arm can clear it when a
                // match didn't consume — that lets the CSI-u
                // cleanup at the bottom still translate / drop the
                // raw kitty-kbd bytes instead of forwarding them to
                // the shell as mojibake.
                var matched_binding = matched_action != null;
                if (matched_action) |act| {
                    switch (act) {
                        .ghost_accept => {
                            // Don't gate on `ghost.visible` — the
                            // flicker fix moved overlay painting to
                            // the master-output path, so fast typers
                            // can press the accept key before the
                            // ghost has been visibly rendered. We
                            // ask the module chain for a fresh
                            // suggestion instead; if it's there, we
                            // accept it regardless of whether it's
                            // been painted yet.
                            //
                            // gatherGhostText returns the *trailing*
                            // portion (what would be painted after
                            // the cursor) — i.e. the bytes we want
                            // to inject. Use it directly.
                            if (!line_state.uncertain) {
                                if (D.gatherGhostText(&runtimes, &ctx) catch null) |trailing| {
                                    if (trailing.len > 0 and trailing.len <= accept_buf.len) {
                                        @memcpy(accept_buf[0..trailing.len], trailing);
                                        input = accept_buf[0..trailing.len];
                                    }
                                }
                            }
                        },
                        .ghost_accept_word => {
                            // Partial accept (fish's section-by-
                            // section walk). Take the FIRST word
                            // of the trailing ghost suggestion +
                            // the trailing whitespace after it.
                            // Successive presses peel off the next
                            // word from the (now shorter) ghost.
                            //
                            // Word boundary: skip leading spaces,
                            // skip non-space chars (the word
                            // itself), then include trailing space
                            // run so the next press starts cleanly.
                            // No-op when no ghost / uncertain line.
                            if (!line_state.uncertain) {
                                if (D.gatherGhostText(&runtimes, &ctx) catch null) |trailing| {
                                    if (trailing.len > 0) {
                                        var end: usize = 0;
                                        // Skip leading whitespace (rare —
                                        // usually the ghost starts with
                                        // a word char).
                                        while (end < trailing.len and trailing[end] == ' ') end += 1;
                                        // Consume the word.
                                        while (end < trailing.len and trailing[end] != ' ') end += 1;
                                        // Consume the trailing whitespace
                                        // run so the boundary lands at
                                        // the next word's first char.
                                        while (end < trailing.len and trailing[end] == ' ') end += 1;
                                        if (end > 0 and end <= accept_buf.len) {
                                            @memcpy(accept_buf[0..end], trailing[0..end]);
                                            input = accept_buf[0..end];
                                        }
                                    }
                                }
                            }
                        },
                        .incognito_toggle => {
                            incognito_on = !incognito_on;
                            ctx.incognito = incognito_on;
                            // Don't forward the binding bytes to the shell.
                            swallow_after_binding = true;
                            // Force the status bar to repaint so the
                            // 🔒 prefix appears/disappears immediately.
                            if (statusbar) |*sb| sb.last_valid = false;
                        },
                        .delete_history_match => {
                            // Pick the deletion target. Prefer the
                            // keystroke-tracked `line_state.current()`
                            // (works for any shell, no integration
                            // needed). When the buffer is `uncertain`
                            // — typically because the user just hit
                            // Up arrow to recall an entry — fall
                            // back to the OSC 133 capture stream
                            // when it's active and non-empty.
                            //
                            // Race note: atty's poll loop processes
                            // stdin BEFORE master, so a STRICT race
                            // (user presses Ctrl+Shift+D before any
                            // master-output cycle has fed the recall
                            // bytes to `osc133_tracker`) leaves
                            // `currentInput()` empty too, and the
                            // handler no-ops. In practice the user
                            // waits to SEE the recalled line before
                            // pressing the binding, by which point
                            // multiple poll iterations have drained
                            // the master fd and `syncFromCapture` /
                            // `osc133_tracker.feed` have run — so
                            // the typical case is handled. A future
                            // pre-binding master-drain helper would
                            // close the strict race for power users
                            // who type faster than the kernel
                            // schedules; deferred until anyone
                            // actually trips it.
                            const target: []const u8 = blk: {
                                if (!line_state.uncertain) {
                                    break :blk line_state.current();
                                }
                                if (osc133_tracker.captureActive()) {
                                    break :blk osc133_tracker.currentInput();
                                }
                                break :blk "";
                            };
                            if (target.len > 0) {
                                // Fire the deletion across modules that
                                // implement the hook.
                                D.dispatchDeleteHistoryMatch(&runtimes, &ctx, target) catch {};
                                // Clear the shell prompt: send Ctrl+U
                                // (NAK / kill-line). Bash, zsh, dash
                                // and friends all bind it to
                                // unix-line-discard. We also reset
                                // our own line model.
                                _ = std.c.write(pty.master, "\x15", 1);
                                line_state.reset();
                                if (ghost.visible) clearGhost(&ghost, &out_buf) catch {};
                                if (ghost_list.active) deactivateGhostList(&ghost_list, &out_buf) catch {};
                                // Flash a status-bar message that
                                // auto-fades after 3 s.
                                if (statusbar) |*sb| {
                                    var buf: [128]u8 = undefined;
                                    const msg = std.fmt.bufPrint(
                                        &buf,
                                        "🗑 deleted: {s}",
                                        .{target},
                                    ) catch buf[0..0];
                                    sb.setTransient(msg, 3_000);
                                }
                            }
                            swallow_after_binding = true;
                        },
                        .ghost_pick => |pick_n| {
                            // Substitute the keystroke with the
                            // trailing portion of list entry N (1-based).
                            // No-op + swallow when:
                            //   - the line is uncertain (history-nav
                            //     etc. — suggestions would be stale)
                            //   - N exceeds the rendered list length
                            //   - the entry doesn't extend the current
                            //     line prefix
                            var did_pick = false;
                            if (!line_state.uncertain) {
                                if (ghost_list.entry(pick_n)) |full| {
                                    const query = line_state.current();
                                    if (std.mem.startsWith(u8, full, query) and full.len > query.len) {
                                        const trailing = full[query.len..];
                                        if (trailing.len > 0 and trailing.len <= accept_buf.len) {
                                            @memcpy(accept_buf[0..trailing.len], trailing);
                                            input = accept_buf[0..trailing.len];
                                            did_pick = true;
                                        }
                                    }
                                }
                            }
                            // Out-of-range / no-match → drop the
                            // binding bytes (Ctrl+<digit> CSI-u or
                            // Esc+<digit>) so the shell never sees
                            // them as mojibake or digit-argument.
                            if (!did_pick) swallow_after_binding = true;
                        },
                        .llm_exec_single,
                        .llm_exec_dialog,
                        .llm_exec_auto,
                        .llm_exec_cycle_model,
                        .llm_exec_toggle_help,
                        .llm_exec_cancel,
                        .llm_chat_overlay_toggle,
                        => {
                            // Hand the action to the llm module via
                            // the generic onAction dispatch. Module
                            // returns true iff it consumed the
                            // action (e.g. AI mode active for the
                            // exec_* actions). Only swallow when
                            // consumed — otherwise the meta-key
                            // bytes flow through to readline /
                            // inner programs that may bind them
                            // (emacs, less, vim, …).
                            //
                            // When NOT consumed, generally let the
                            // meta-key bytes flow through to readline
                            // / inner programs that may bind them
                            // (emacs, less, vim, …) — matched_binding
                            // stays true so the CSI-u cleanup below
                            // is suppressed.
                            //
                            // The Esc CSI-u binding is the one
                            // exception: a kitty-encoded `\x1b[27u`
                            // that the module rejected (no AI mode)
                            // must still be translated to legacy
                            // `\x1b` so bash sees a bare Esc rather
                            // than raw CSI-u mojibake. Limiting the
                            // override to this exact byte sequence
                            // preserves the Ctrl+Shift+X /
                            // Alt+letter fallthrough behavior that
                            // TUIs depend on.
                            if (D.dispatchAction(&runtimes, &ctx, act)) {
                                swallow_after_binding = true;
                            } else if (std.mem.eql(u8, input, "\x1b[27u")) {
                                matched_binding = false;
                            }
                        },
                    }
                }
                // Kitty keyboard protocol cleanup. With the
                // disambiguate flag pushed, terminals like Ghostty
                // emit CSI-u for keys that previously had a legacy
                // encoding — including Ctrl+letter (Ctrl+C, Ctrl+R,
                // …), Esc, Tab, Enter, Backspace. The shell doesn't
                // speak the protocol; left alone those keys would
                // either echo as mojibake or vanish. So:
                //
                //   1. If the sequence has a legacy form, translate
                //      and forward the legacy bytes (e.g. Ctrl+C
                //      becomes \x03 — bash's line-abort).
                //   2. If it doesn't (Ctrl+9, Ctrl+Shift+Right, …)
                //      AND we're NOT in alt-screen, drop to avoid
                //      mojibake.
                //   3. If it doesn't AND we ARE in alt-screen, pass
                //      the raw CSI-u through. Alt-screen apps that
                //      push their own kitty kbd flags (atuin via
                //      crossterm's REPORT_ALL_KEYS, nvim, lazygit,
                //      …) need every keystroke — including plain
                //      letters — to arrive as `\x1b[<kc>u`. Dropping
                //      "unmapped" CSI-u in that mode swallowed
                //      regular typing inside atuin's Ctrl+R picker
                //      and any TUI that opts into the report-all
                //      flag. Bash itself never enters alt-screen,
                //      so the at-the-prompt mojibake guard still
                //      applies wherever it's needed.
                var legacy_buf: [8]u8 = undefined;
                if (!matched_binding and config.terminal.enable_kitty_keyboard and keymap.isCsiU(input)) {
                    if (keymap.csiUToLegacy(input, &legacy_buf)) |legacy| {
                        input = legacy;
                    } else if (!alt_screen.active) {
                        swallow_after_binding = true;
                    }
                }

                if (swallow_after_binding) {
                    if (statusbar) |*sb| {
                        if (!alt_screen.active) renderStatus(&runtimes, &ctx, sb, &out_buf, incognito_on) catch {};
                    }
                    continue;
                }

                if (ghost.visible) try clearGhost(&ghost, &out_buf);
                // The pick list (if active) owns rows below the
                // prompt — the typed character lands on the prompt
                // row, no overlap. renderGhostList in the master
                // path handles repaint/deactivate when content
                // changes.
                //
                // Skip `line_state.applyInput` while an alt-screen
                // TUI is active. The keystrokes are going to that
                // TUI, not to the shell prompt, so feeding them
                // into line_state's prefix model is meaningless —
                // and the CSI-u-passthrough path for REPORT_ALL_
                // KEYS TUIs (atuin, lazygit, …) pushes raw CSI
                // sequences for every plain letter, which
                // applyInput would mark as `uncertain` and leave
                // ghost text suppressed at the next shell prompt.
                // The alt-screen-exit path resets line_state for
                // the same reason: anything we accumulated during
                // the TUI run is stale.
                if (!alt_screen.active) {
                    _ = line_state.applyInput(input);
                }

                // If the user pressed Enter AND the OSC 133 tracker
                // is in INPUT phase (between `;B` and `;C` — i.e.
                // we know we're at a real shell prompt), the marker
                // stream's captured input is the ground truth for
                // what's about to be committed — including any text
                // the shell put there via history recall /
                // completion / paste that line_state's keystroke
                // tracking can't observe. Override.
                //
                // Gating on `inInputPhase()` (not just `active`) is
                // critical: `currentInput()` reflects whatever was
                // captured between the LAST `;B` and now, so in
                // command phase (post-`;C`, e.g. inside ssh without
                // remote integration) it's the *previous* prompt's
                // content. Without the gate, every Enter during
                // command phase would set lastCommitted to the
                // stale prompt text → recording the same line over
                // and over.
                if (osc133_tracker.inInputPhase() and containsEnter(input) and osc133_tracker.currentInput().len > 0) {
                    line_state.setCommitted(osc133_tracker.currentInput());
                }

                const action = D.dispatchInput(&runtimes, &ctx, input) catch .forward;
                switch (action) {
                    .forward => try writeAll(pty.master, input),
                    .swallow => {},
                    .replace => |bytes| try writeAll(pty.master, bytes),
                    .replace_commit => |bytes| try writeAll(pty.master, bytes),
                }

                // Fire onLineCommit if Enter was pressed during this read
                // and the pre-Enter line was non-empty and certain. Skip
                // when incognito is on, when the line starts with a
                // space (bash HISTCONTROL=ignorespace convention), or
                // when the shell never actually saw the Enter — a
                // `.swallow` drops the input entirely, and a `.replace`
                // can substitute it for bytes that DON'T contain `\r`
                // (guardrail's `.block` swaps the Enter for `\x15`).
                // Recording a commit the shell didn't run would be a
                // lie + would feed history the dangerous line.
                //
                // `.replace_commit` opts back in to the commit even
                // when the replacement doesn't contain Enter — used
                // by the LLM module so `#: <prompt>` lines land in
                // atuin / history despite Ctrl+U eating the line.
                // Still keyed on the ORIGINAL input containing Enter,
                // not unconditionally true: a misbehaving module
                // returning `.replace_commit` on a non-Enter
                // keystroke must not be able to force a spurious
                // commit. The behaviour difference vs. plain
                // `.replace` is only that we look at the original
                // bytes (not the replacement) for the Enter test.
                // Two related signals from the action:
                //
                //   - `recording_should_fire`: should `dispatchLineCommit`
                //     run? True for `.forward` / `.replace` whose
                //     forwarded bytes contain Enter, AND true for
                //     `.replace_commit` (the LLM module opt-in:
                //     fire commit even though we're swapping the
                //     line for Ctrl+U).
                //   - `shell_will_execute`: will the SHELL emit a
                //     `;C` for this line? True ONLY when the bytes
                //     actually forwarded to the PTY contain Enter.
                //     False for `.replace_commit` (it forwards
                //     `\x15`, no Enter → no `;C`).
                //
                // The split matters for `pending_launches`: pushing
                // when `recording_should_fire` but `!shell_will_execute`
                // would enqueue a commit that no `;C` will ever
                // pop, so the NEXT real `;C` (from an unrelated
                // command) would pop the stale entry and
                // mis-classify the subprocess kind.
                const recording_should_fire = switch (action) {
                    .forward => containsEnter(input),
                    .swallow => false,
                    .replace => |bytes| containsEnter(bytes),
                    .replace_commit => containsEnter(input),
                };
                const shell_will_execute = switch (action) {
                    .forward => containsEnter(input),
                    .swallow => false,
                    .replace => |bytes| containsEnter(bytes),
                    .replace_commit => |bytes| containsEnter(bytes),
                };
                // Legacy alias — older code paths in this file use
                // the original name for the recording-side gate.
                const shell_saw_enter = recording_should_fire;
                if (line_state.lastCommitted()) |committed| {
                    const leading_space = committed.len > 0 and committed[0] == ' ';
                    // Stash the line for the upcoming `;C` edge in
                    // the master-output handler. shell_saw_enter
                    // gates this — if the shell never saw Enter
                    // (`.swallow`, guardrail block) it can't fire
                    // a `;C` either, so we don't push. Each
                    // recording-eligible line is APPENDED to the
                    // FIFO; the next `;C` edge pops the oldest
                    // entry, so multi-commit chunks (a paste of
                    // several lines) attribute each `;C` to the
                    // matching commit in stdin order. Overflow at
                    // capacity (8) drops the head, not this tail —
                    // the tail entry is always current.
                    //
                    // Additional gate: only push when OSC 133 says
                    // we're actually at a SHELL prompt
                    // (`inInputPhase()`). Without this, Enters typed
                    // into non-shell interactive prompts (ssh's
                    // hostkey "yes/no", sudo's password prompt,
                    // `read` builtins from a shell script, …) would
                    // pile up in the FIFO waiting for a `;C` that
                    // never comes; the next real `;C` would then
                    // pop the stale entry and misattribute the
                    // subprocess kind. Also covers the
                    // no-local-integration case (phase stays
                    // `.idle` forever): we don't push, the FIFO
                    // stays empty, and `;C` (which won't fire
                    // anyway) gets `""` from `.pop()` — same as
                    // before.
                    // Push to the FIFO requires BOTH:
                    //   - `shell_will_execute` — the bytes the shell
                    //     actually receives contain Enter, so a `;C`
                    //     will follow. Without this, `.replace_commit`
                    //     would enqueue commits that no `;C` ever
                    //     consumes, and the next real `;C` would pop
                    //     the wrong line (mis-classifying its frame).
                    //   - `inInputPhase()` — we're at a real prompt
                    //     (non-shell interactive prompts like ssh
                    //     hostkey "yes/no" don't fire `;C` either).
                    if (shell_will_execute and osc133_tracker.inInputPhase()) {
                        pending_launches.push(committed);
                    }
                    // Decide whether to record this commit. Three
                    // gating signals:
                    //
                    //  1. alt-screen TUI active (vim, k9s, less, …)
                    //     — never record; we can't tell what's a
                    //     command and the gate works without shell
                    //     integration.
                    //  2. OSC 133 says we're in command phase AND
                    //     the top of the subprocess stack is `.none`
                    //     — we're inside an unrecognised subprocess
                    //     (psql, nano, mysql -p, …); same drop.
                    //  3. OSC 133 says we're in command phase AND
                    //     the top of the stack is a recognised
                    //     launcher (ssh, sudo bash, kubectl exec, …)
                    //     — RECORD. The atuin / history modules
                    //     consult `ctx.subprocessCwd(…)` so the
                    //     entry is tagged with the remote target
                    //     (`ssh://user@host/…`, `k8s://…`, etc.)
                    //     rather than masquerading as a local one.
                    const drop_for_alt = alt_screen.active;
                    const drop_for_unknown_subproc =
                        osc133_tracker.active and
                        !osc133_tracker.inInputPhase() and
                        subprocess_tracker.currentKind() == .none;
                    // Per-target incognito: when the current
                    // subprocess frame's name matches a configured
                    // target, treat it like the user pressed
                    // Ctrl+Shift+I. Same drop, no statusbar surprise
                    // (the segment still shows the target so the
                    // user knows where they are; the 🔒 indicator
                    // doesn't appear because this is config-driven,
                    // not user-toggled).
                    const drop_for_target_incognito = blk: {
                        if (subprocess_tracker.current()) |f| {
                            if (f.kind != .none) {
                                for (config.subprocess.incognito_targets) |needle| {
                                    if (std.mem.eql(u8, f.name(), needle)) break :blk true;
                                }
                            }
                        }
                        break :blk false;
                    };
                    const drop_recording = drop_for_alt or drop_for_unknown_subproc or drop_for_target_incognito;
                    if (!line_state.committed_was_uncertain and
                        !incognito_on and
                        !leading_space and
                        !drop_recording and
                        shell_saw_enter)
                    {
                        D.dispatchLineCommit(&runtimes, &ctx, committed) catch {};
                    }
                    line_state.clearLastCommitted();
                }

                // Deliberately NO renderGhost here. The shell hasn't
                // echoed yet, so the terminal cursor is still at its
                // pre-keystroke position. Painting the ghost now lands
                // it one column off; when the echo arrives in the
                // master-output path below we render the ghost there
                // with the cursor at the correct (post-echo) position.
                // Sub-millisecond delay on a local shell; eliminates
                // the "flickers one char left/right" jitter on every
                // keystroke.
                if (statusbar) |*sb| {
                    if (!alt_screen.active) renderStatus(&runtimes, &ctx, sb, &out_buf, incognito_on) catch {};
                }
            }
        }

        // ---- master → dispatch → stdout ----------------------------------
        if (pfds[1].revents & POLLIN != 0) {
            const read_n = posix.read(pty.master, &read_buf) catch 0;
            if (read_n > 0) {
                const output = read_buf[0..read_n];

                if (ghost.visible) try clearGhost(&ghost, &out_buf);
                // List sits below the prompt — shell echo lands on
                // the prompt row, no overlap. renderGhostList below
                // handles repaint/deactivate when content changes.
                // Feed OSC 133 tracker — captures the input region
                // when the shell emits prompt-zone markers. Stays
                // dormant otherwise.
                // Fast path: when the chunk has no escape bytes AND
                // every OSC/CSI tracker reports `canFastPath()`,
                // the per-byte state machines provably stay in
                // `.ground` — feeding each byte is pure overhead.
                // A 4 KB plain-text chunk otherwise burns ~50 µs
                // per tracker on switch dispatch.
                //
                // Each tracker's `canFastPath()` encodes the
                // tracker-specific safety predicate (osc133 also
                // checks `phase != .in_input` because plain ASCII
                // bytes mutate the captured-input buffer in that
                // phase). Each `skipBytes(n)` does the minimum
                // per-feed bookkeeping `feed()` would have done
                // for a no-transition byte stream: bump the
                // diagnostic counter (osc133), clear the per-feed
                // capture ring (osc7), nothing (altscreen).
                //
                // cursor_tracker has no fast-path — it tracks
                // CR/LF/printable-advance for every byte.
                const has_esc = std.mem.indexOfScalar(u8, output, 0x1B) != null;
                const can_fast = !has_esc and
                    osc133_tracker.canFastPath() and
                    alt_screen.canFastPath() and
                    osc7_tracker.canFastPath();
                if (can_fast) {
                    osc133_tracker.skipBytes(output.len);
                    alt_screen.skipBytes(output.len);
                    osc7_tracker.skipBytes(output.len);
                } else {
                    osc133_tracker.feed(output);
                    alt_screen.feed(output);
                    osc7_tracker.feed(output);
                }
                cursor_tracker.feed(output);
                // Only surface the row to modules on real TTY runs
                // — matches the null-on-non-TTY contract on
                // `Context.cursor_row` and the startup gate above.
                if (args.is_tty) ctx.cursor_row = cursor_tracker.currentRow();
                // Mirror the shell-side alt-screen state onto the
                // Context so modules can refuse to open their own
                // overlay on top of a running TUI (nvim, k9s, less).
                // Updated after every master-read so a TUI launch
                // / exit propagates within one tick.
                ctx.shell_alt_screen_active = alt_screen.active;
                // Query module-overlay state for the ring-buffer
                // gate below. Mirror onto ctx so other modules
                // (and the renderStatus path) see the same value.
                const overlay_active_now = D.anyOverlayActive(&runtimes);
                ctx.module_overlay_active = overlay_active_now;

                // Walk the OSC 133 edge ring + OSC 7 capture ring
                // INTERLEAVED by byte offset within the current
                // `output` chunk. 2-pointer merge: whichever event
                // has the smaller offset fires next. Order matters
                // because applying OSC 7 after a push in the same
                // chunk lands it on the wrong (child) frame; before
                // a push lands it on the parent.
                //
                // Per-byte offset stamping on both trackers lets us
                // replay events in source order without merging
                // per-byte during the feed itself.
                const edges = osc133_tracker.drainEdges();
                var ei: usize = 0;
                var ci: usize = 0;
                while (ei < edges.len or ci < osc7_tracker.count) {
                    const edge_off: u32 = if (ei < edges.len) osc133_tracker.edgeOffset(ei) else std.math.maxInt(u32);
                    const cwd_off: u32 = if (ci < osc7_tracker.count) osc7_tracker.offsetAt(ci) else std.math.maxInt(u32);
                    if (cwd_off <= edge_off) {
                        subprocess_tracker.onRemoteCwd(osc7_tracker.path(ci));
                        ci += 1;
                    } else {
                        switch (edges[ei]) {
                            .cmd_start => {
                                // ;C — pop the next pending launch line
                                // (FIFO order matches the Enter order
                                // on stdin) and feed it to the
                                // subprocess tracker. We CAN'T use
                                // `line_state.lastCommitted()` — by the
                                // time the shell emits `;C`, the stdin
                                // path has already run
                                // `clearLastCommitted()` — and if
                                // multiple ;C edges fire in one chunk
                                // we need the corresponding commits,
                                // not the most recent one.
                                subprocess_tracker.onCommandStart(pending_launches.pop(), allocator, io);
                            },
                            .cmd_end => subprocess_tracker.onCommandEnd(),
                            .prompt_start_implicit_end => {
                                // Partial-emitter implicit close
                                // (Ghostty-style: `;A` instead of
                                // `;D` between commands). Pop
                                // trailing `.none` frames only —
                                // those represent ordinary commands
                                // that finished. A recognised
                                // launcher frame underneath (ssh,
                                // sudo, kubectl_exec, …) is the
                                // long-running subprocess we're
                                // STILL inside; popping it would
                                // mis-attribute every subsequent
                                // remote/elevated commit.
                                //
                                // Known limitation: when the user
                                // actually exits a recognised
                                // subprocess (e.g. ssh client
                                // process terminates), the partial
                                // emitter's next `;A` still won't
                                // distinguish that from a remote
                                // shell's `;A`, so the recognised
                                // frame leaks. The user notices
                                // because subsequent local
                                // commands get attributed to the
                                // dead ssh target. Documented as a
                                // follow-up — needs an external
                                // signal (process tree / FG pgid /
                                // local-shell-specific marker) to
                                // resolve.
                                while (subprocess_tracker.currentKind() == .none and subprocess_tracker.depth > 0) {
                                    subprocess_tracker.onCommandEnd();
                                }
                            },
                        }
                        ei += 1;
                    }
                }

                // Alt-screen transition: an interactive full-screen
                // TUI just entered (?1049h, ?47h, ?1047h) or exited
                // (?1049l, …). On enter we hand the app the WHOLE
                // terminal — re-set the slave PTY's reported rows
                // to the full size so the app's own SIGWINCH-driven
                // redraw uses every row (TIOCSWINSZ via
                // `pty.setSize` delivers SIGWINCH to the slave's
                // foreground process group). On exit we restore the
                // slim size and re-activate the statusbar so the
                // bottom rows aren't left in whatever state the app
                // returned them in.
                //
                // Capture the edge now, but DEFER the side effects
                // (sb.activate writes + slave resize) until AFTER
                // `output` has been forwarded to STDOUT. The
                // `?1049l` exit byte is IN `output`; emitting
                // sb.activate bytes before forwarding `output`
                // would land them on the alt screen one last time,
                // clobbering the TUI's final frame and reintroducing
                // bleed. Same for the resize on enter — sending
                // SIGWINCH to the app before it even sees its own
                // `?1049h` would be a redraw against a state the
                // app hasn't entered yet.
                const alt_transitioned = alt_screen.takeTransition();
                const alt_now_active = alt_screen.active;

                // Continuous line_state sync while the tracker is in
                // its input phase. Keystroke tracking models what the
                // user TYPED; the OSC 133 capture models what the
                // shell actually DREW on the prompt. These diverge
                // any time the shell-side rewrites the line without
                // the user typing — Arrow Up history recall, Tab
                // completion expansion, paste, prompt redraw. The
                // sync makes `ctx.line.current()` reflect on-screen
                // truth, so ghost-text / LLM prefix signals /
                // delete_history_match all "just work" against the
                // recalled or completed line without the user having
                // to retype it.
                //
                // Gated on `inInputPhase()` because `currentInput()`
                // is stale or empty between commands (during
                // `in_command` — after Enter on the typed command,
                // including the entire run-time of `sudo`/`ssh`/etc.
                // and their password prompts — or before any prompt
                // marker has fired). That gate also makes this safe
                // against password redaction: every password-reading
                // tool (`sudo`, `ssh`, `passwd`, `gpg-agent` pinentry,
                // `git credential`) runs post-`;C`, so the tracker
                // is `.in_command` for the duration and the sync
                // doesn't fire.
                // Gate on `captureActive()` (strict `.in_input`), NOT
                // the broader `inInputPhase()` (which also covers
                // `.at_prompt`). In `.at_prompt`, byte capture
                // hasn't started — `currentInput()` is empty —
                // and `syncFromCapture("")` would clobber the
                // user's keystroke-tracked buffer every poll
                // iteration. Partial emitters that never send `;B`
                // stay in `.at_prompt` permanently, so the strict
                // gate is the only way ghost text can survive
                // there.
                if (osc133_tracker.captureActive()) {
                    const osc_input = osc133_tracker.currentInput();
                    const line_current = line_state.current();
                    // Sync only when EITHER:
                    //
                    //   (a) line_state is `uncertain` — keystroke
                    //       tracker hit something it couldn't model
                    //       (Arrow-Up recall, Tab completion, lone
                    //       ESC, paste, …). The OSC capture is the
                    //       authoritative recovery path; trust it
                    //       even when it's shorter than the
                    //       keystroke buffer (history recall to a
                    //       shorter line, completion-replace).
                    //
                    //   (b) `osc_input.len >= line_current.len` —
                    //       OSC capture is at least as complete as
                    //       the keystroke tracker. Covers normal
                    //       typing (echo matches), paste (full
                    //       buffer arrives at once), Ctrl+L full-
                    //       screen redraw (typed buffer re-emitted).
                    //
                    // Skip the sync otherwise (osc shorter than the
                    // keystroke buffer AND line_state is certain).
                    // This guards against bash readline re-emitting
                    // `\[\033]133;A\007\]…\[\033]133;B\007\]` mid-
                    // typing (line-wrap recovery, prompt-manager
                    // async updates) — each `;B` re-fire clears
                    // `osc.input`, then bash echoes only the most
                    // recently typed char, so `osc_input.len < N`
                    // while the keystroke buffer correctly has
                    // all N chars. Without this gate, the
                    // re-emission-only-of-last-char path
                    // `syncFromCapture`d the keystrokes away, seen
                    // downstream as "ghost text matches last N-1
                    // chars when typing N chars fast."
                    if (line_state.uncertain or osc_input.len >= line_current.len) {
                        line_state.syncFromCapture(osc_input);
                    }
                }

                D.dispatchOutput(&runtimes, &ctx, output) catch {};
                // While any module's overlay is active, divert
                // master output to the ring buffer rather than
                // writing it to stdout — stdout is in alt-screen
                // mode painted by the overlay; direct writes
                // would garble its content. On the overlay-closed
                // transition (handled below after this dispatch
                // block) the ring flushes back to stdout in order
                // with a dropped-byte marker if it overflowed.
                if (overlay_active_now) {
                    overlay_ring_state.push(output);
                } else {
                    try writeAll(posix.STDOUT_FILENO, output);
                }

                // Deferred alt-screen side effects — see the captured
                // `alt_transitioned` / `alt_now_active` above. Run AFTER
                // forwarding `output` so the terminal has already
                // honoured the enter/exit byte before we layer our own
                // bytes (statusbar repaint) or signal the slave (resize
                // + SIGWINCH).
                if (alt_transitioned) {
                    // Slave size is always FULL (see startup
                    // comment) — no per-transition resize needed.
                    if (alt_now_active) {
                        // ENTER: explicitly reset DECSTBM so the
                        // inner TUI's drawing isn't clipped by the
                        // statusbar's reserved scroll region. Most
                        // terminals (xterm, kitty, alacritty) give
                        // the alt-screen buffer its own DECSTBM
                        // defaulting to (1, rows), so this is a
                        // no-op. Ghostty's behaviour is less
                        // documented and we've seen LazyVim's
                        // dashboard render as if it lived in a
                        // box of `effectiveRows()` instead of
                        // `rows` — the only mechanism atty has in
                        // play that would explain that is a
                        // global DECSTBM. Force the reset so we
                        // remove all doubt.
                        //
                        // Wrap in DECSC/DECRC (`\x1B[s` / `\x1B[u`)
                        // because `CSI r` with no parameters resets
                        // the scroll region AND homes the cursor on
                        // every VT/xterm-compatible terminal. The
                        // TUI may have already positioned its
                        // cursor inside the same chunk that
                        // contained `?1049h`; without save/restore
                        // we'd snap it back to (1,1) and corrupt
                        // its first frame. `StatusBar.reactivate`
                        // uses the same wrap on the exit path for
                        // the symmetric reason.
                        if (statusbar != null and !ctx.module_overlay_active) {
                            _ = writeAll(posix.STDOUT_FILENO, "\x1B[s\x1B[r\x1B[u") catch {};
                        }
                    } else {
                        // EXIT (`?1049l`): restore DECSTBM + clear
                        // the reserved rows, because the alt-screen
                        // TUI may have emitted `\x1B[r` on its own
                        // buffer and on terminals where DECSTBM is
                        // global that propagates to the primary
                        // screen.
                        if (statusbar) |*sb| {
                            if (!ctx.module_overlay_active) {
                                var w2: std.Io.Writer = .fixed(&out_buf);
                                sb.reactivate(&w2) catch {};
                                if (w2.end > 0) writeAll(posix.STDOUT_FILENO, out_buf[0..w2.end]) catch {};
                            }
                        }
                        // Clear line_state too. Any keystrokes
                        // recorded before the TUI entered alt-
                        // screen are stale (the user typed `nvim<CR>`
                        // — that's gone), and the input path
                        // skipped `applyInput` during the TUI run
                        // so there's nothing valid in the buffer.
                        // Without this, the previous prompt's
                        // suffix can resurrect at the new prompt
                        // and ghost text + line-commit detection
                        // see a wrong prefix.
                        line_state.reset();
                        line_state.clearLastCommitted();
                    }
                }

                if (!inSubprocess(&alt_screen, &osc133_tracker)) {
                    renderGhost(&runtimes, &ctx, &ghost, &out_buf) catch {};
                    renderGhostList(&runtimes, &ctx, &ghost_list, &out_buf) catch {};
                }
                if (statusbar) |*sb| {
                    if (!alt_screen.active) {
                        // Shell output may have scrolled or overwritten our
                        // reserved row — force a repaint.
                        sb.last_valid = false;
                        renderStatus(&runtimes, &ctx, sb, &out_buf, incognito_on) catch {};
                    }
                }
            } else if (read_n == 0) {
                child_alive = false;
            }
        }
        if (pfds[1].revents & (POLLHUP | POLLERR) != 0) {
            child_alive = false;
        }

        // ---- signal pipe --------------------------------------------------
        if (pfds[2].revents & POLLIN != 0) {
            var sig_buf: [16]u8 = undefined;
            const sn = posix.read(sig_pipe.read, &sig_buf) catch 0;
            var i: usize = 0;
            while (i < sn) : (i += 1) {
                const sig: posix.SIG = @enumFromInt(sig_buf[i]);
                if (sig == posix.SIG.WINCH) {
                    if (Pty.querySize(posix.STDOUT_FILENO)) |s| {
                        // setMaxRows AFTER sb.onResize so we can
                        // read the new effectiveRows() — see the
                        // startup-init comment for why the tracker
                        // tracks DECSTBM's bottom row, not the
                        // screen's physical bottom.
                        if (statusbar) |*sb| {
                            sb.onResize(s.rows, s.cols);
                            cursor_tracker.setMaxRows(sb.effectiveRows());
                            // While an alt-screen TUI is running the
                            // statusbar is suspended and the app owns
                            // every row — don't re-paint the reserved
                            // zone. On exit (?1049l) the master-
                            // output path runs sb.activate again
                            // with the current size.
                            if (!alt_screen.active and !ctx.module_overlay_active) {
                                var w: std.Io.Writer = .fixed(&out_buf);
                                sb.activate(&w) catch {};
                                try writeAll(posix.STDOUT_FILENO, out_buf[0..w.end]);
                            }
                        } else {
                            cursor_tracker.setMaxRows(s.rows);
                        }
                        if (args.is_tty) ctx.cursor_row = cursor_tracker.currentRow();
                        // Always pass the FULL size — slimming would
                        // bake the statusbar reservation into the
                        // slave's TIOCGWINSZ, breaking any inner TUI
                        // that queries its size before our alt-screen
                        // resize fires.
                        _ = pty.setSize(s) catch {};
                    } else |_| {}
                } else if (sig == posix.SIG.CHLD) {
                    var status: u32 = 0;
                    const wp = std.os.linux.waitpid(child_pid, &status, std.os.linux.W.NOHANG);
                    if (wp == child_pid) {
                        child_alive = false;
                        exit_code = @intCast((status >> 8) & 0xFF);
                    }
                }
            }
        }

        // End-of-iteration overlay edge-detect. Re-query AFTER
        // all events have been handled (stdin onAction may have
        // toggled the overlay; master-read may have pushed bytes
        // into the ring while the overlay was active). If the
        // overlay just closed, flush the captured bytes back to
        // stdout. The mirror onto ctx.module_overlay_active is
        // already current — only need to update prev_overlay_active
        // for the next iteration's edge detection.
        const overlay_active_end = D.anyOverlayActive(&runtimes);
        if (prev_overlay_active and !overlay_active_end) {
            overlay_ring_state.flush(posix.STDOUT_FILENO) catch {};
        }
        prev_overlay_active = overlay_active_end;
    }

    // Child died (or POLLHUP/SIGCHLD ended the loop) with the
    // overlay still open — the close-edge inside the loop never
    // fired. Drain the ring now so the user's terminal isn't
    // left missing output that the subprocess produced just
    // before exiting.
    if (prev_overlay_active) {
        overlay_ring_state.flush(posix.STDOUT_FILENO) catch {};
    }

    _ = posix.kill(child_pid, posix.SIG.HUP) catch {};
    var status: u32 = 0;
    _ = std.os.linux.waitpid(child_pid, &status, 0);

    return .{ .exit_code = exit_code };
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

const POLLIN: i16 = 0x001;
const POLLHUP: i16 = 0x010;
const POLLERR: i16 = 0x008;

/// True when the shell is running a foreground subprocess (not at
/// the local prompt). Gates `renderGhost` / `renderGhostList` /
/// `dispatchLineCommit` so atty doesn't paint suggestions over
/// vim's UI or record every Enter inside vim / ssh / sudo /
/// kubectl exec / psql / etc. as a "shell command".
///
/// Two signals OR'd together — either one is sufficient:
///
///   1. **alt-screen active** — TUI swapped to the alt buffer
///      (`\x1b[?1049h` family). Catches vim, k9s, less, htop,
///      helix, lazygit, top, btm. Works WITHOUT shell integration.
///   2. **OSC 133 markers active AND not in input phase** — the
///      LOCAL shell told us we're between `;C` and `;D` (a command
///      is running). Catches every subprocess including ones that
///      stay on the primary screen: ssh, sudo, su, psql, mysql,
///      `bash -c`, `kubectl exec`, etc. Requires shell integration
///      (Ghostty's `shell-integration-features = osc-133`, ble.sh,
///      zsh4humans, VS Code's snippet).
///
/// Both signals are conservative — never false-positive at the
/// real local prompt (alt-screen is impossible there, and OSC 133
/// in input phase IS the prompt). For users without integration
/// the alt-screen branch alone catches the common case (TUIs
/// drawing on top of which ghost overlay would land); ssh / sudo
/// remain unsuppressed without integration but those don't paint
/// anything on top of the prompt anyway, so the consequence is
/// "ghost-suggest while inside ssh" — annoying but harmless.
fn inSubprocess(alt: *const AltScreen, osc: *const Osc133) bool {
    if (alt.active) return true;
    if (osc.active and !osc.inInputPhase()) return true;
    return false;
}

/// Render the current best suggestion (or clear the overlay if no
/// module wants one). Idempotent.
///
/// `out_buf` is a caller-owned scratch buffer; we wrap it in a fixed
/// `std.Io.Writer`, let the Ghost state machine emit ANSI bytes into
/// it, then flush in a single `std.c.write` syscall.
fn renderGhost(rts: *D.Runtimes, ctx: *module.Context, ghost: *Ghost, out_buf: []u8) !void {
    if (!ctx.is_tty) return;
    // Suspend ghost overlay paints while a module's alt-screen
    // overlay is up — the prompt row the ghost targets is hidden
    // behind the overlay, and writing to it would leave stray
    // bytes that surface on overlay close.
    if (ctx.module_overlay_active) return;

    if (ctx.line.uncertain) {
        if (ghost.visible) try clearGhost(ghost, out_buf);
        return;
    }

    const sug_opt = D.gatherGhostText(rts, ctx) catch null;
    if (sug_opt) |sug| {
        if (sug.len > 0) {
            var w: std.Io.Writer = .fixed(out_buf);
            ghost.show(&w, sug) catch return;
            try writeAll(posix.STDOUT_FILENO, out_buf[0..w.end]);
            return;
        }
    }
    if (ghost.visible) try clearGhost(ghost, out_buf);
}

/// Collect modules' status-text segments + the configured base text,
/// paint into the reserved bottom row. Idempotent — no bytes emitted
/// if the assembled text matches the last paint. When `incognito` is
/// true, prepends a 🔒 segment.
fn renderStatus(
    rts: *D.Runtimes,
    ctx: *module.Context,
    sb: *StatusBar,
    out_buf: []u8,
    incognito: bool,
) !void {
    if (!ctx.is_tty) return;
    // Suspend statusbar painting while any module's overlay is up
    // — atty's terminal is in alt-screen, and writing the bar's
    // bytes there clobbers the overlay's painted content.
    if (ctx.module_overlay_active) return;

    // First gather the module contributions into a scratch buffer.
    //
    // 768 bytes to fit module hints that embed inline SGR styling
    // (LLM's colored AI hint adds ~100 bytes of escape overhead
    // beyond the visible text; the assembler buffer is 1 KB but
    // also holds the incognito + subprocess + base segments).
    var mod_buf: [768]u8 = undefined;
    var mw: std.Io.Writer = .fixed(&mod_buf);
    D.gatherStatus(rts, ctx, &mw) catch {};

    // Subprocess segment — only rendered when configured on AND a
    // recognised launcher is on the top of the tracker stack. The
    // segment text is short — kind prefix + frame name — so a small
    // local buffer is sufficient.
    var subp_buf: [192]u8 = undefined;
    var subp_text: []const u8 = "";
    if (config.subprocess.show_in_statusbar) {
        if (ctx.subprocess) |tr| {
            // Walk past any `.none` frames sitting on top — those are
            // pushed for every unrecognised command running INSIDE a
            // recognised subprocess (e.g. running `ls` inside an ssh
            // session pushes `.none(ls)` on top of `ssh:remote`). If
            // we used `tr.current()` the segment would flicker every
            // time a command runs in the remote shell.
            if (tr.currentRecognized()) |frame| {
                const prefix: []const u8 = switch (frame.kind) {
                    .ssh => "ssh:",
                    .kubectl_exec => "k8s:",
                    .docker_exec => "docker:",
                    .container_exec => "container:",
                    .elevation => "",
                    .su => "",
                    .none => unreachable,
                };
                var sw: std.Io.Writer = .fixed(&subp_buf);
                sw.print("{s}{s}", .{ prefix, frame.name() }) catch {};
                subp_text = subp_buf[0..sw.end];
            }
        }
    }

    // Then ask the pure assembler to join incognito + subprocess +
    // base + modules with " │ " separators, skipping empty segments.
    // Pure logic + own tests live in src/status_text.zig.
    //
    // 1 KB to match the statusbar's text_buf — module contributions
    // can include inline SGR styling (LLM colored AI hint adds
    // ~100 bytes of escape overhead beyond the visible text).
    var text_buf: [1024]u8 = undefined;
    var tw: std.Io.Writer = .fixed(&text_buf);
    status_text.assemble(.{
        .w = &tw,
        .incognito = incognito,
        .incognito_style = config.statusbar.incognito_style,
        .bar_style = config.statusbar.style,
        .subprocess_text = subp_text,
        .subprocess_style = config.subprocess.segment_style,
        .base_text = config.statusbar.base_text,
        .module_text = mod_buf[0..mw.end],
    }) catch {};

    sb.setText(text_buf[0..tw.end]);

    var w: std.Io.Writer = .fixed(out_buf);
    sb.render(&w) catch return;
    if (w.end > 0) try writeAll(posix.STDOUT_FILENO, out_buf[0..w.end]);
}

fn clearGhost(ghost: *Ghost, out_buf: []u8) !void {
    var w: std.Io.Writer = .fixed(out_buf);
    ghost.clear(&w) catch return;
    try writeAll(posix.STDOUT_FILENO, out_buf[0..w.end]);
}

/// Multi-row pick-list overlay. Drives the three transitions of the
/// dynamic dance:
///
///   * should-show & !active  → activate (LF×N + CUU + paint)
///   * should-show & active   → repaint iff the cache changed
///   * !should-show & active  → deactivate (clear, cursor stays)
///
/// "Should show" = TTY, list_count > 0, line non-empty and certain,
/// and at least one module produced matches. The activate path
/// scrolls the prompt up when the prompt is near the bottom row,
/// matching atuin's Ctrl+R UX; mid-screen activation just moves the
/// cursor down + back. Deactivate never scrolls the prompt back —
/// it stays at whatever screen position activate floated it to.
fn renderGhostList(rts: *D.Runtimes, ctx: *module.Context, list: *GhostList, out_buf: []u8) !void {
    if (!ctx.is_tty) return;
    // Same alt-screen-active gate as renderGhost — the pick-list
    // rows below the prompt are hidden by the overlay's
    // alt-screen.
    if (ctx.module_overlay_active) return;
    if (config.ghost.list_count == 0) {
        if (list.active) try deactivateGhostList(list, out_buf);
        return;
    }

    const want = !ctx.line.uncertain and ctx.line.current().len > 0;
    if (!want) {
        if (list.active) try deactivateGhostList(list, out_buf);
        return;
    }

    const entries_opt = D.gatherGhostList(rts, ctx) catch null;
    if (entries_opt) |entries| {
        const changed = list.set(entries, config.ghost.list_count) catch return;
        var w: std.Io.Writer = .fixed(out_buf);
        if (!list.active) {
            list.activate(&w, config.ghost.list_count) catch return;
        } else if (changed) {
            list.repaint(&w) catch return;
        } else {
            return; // active + content unchanged: emit nothing
        }
        if (w.end > 0) try writeAll(posix.STDOUT_FILENO, out_buf[0..w.end]);
        return;
    }
    if (list.active) try deactivateGhostList(list, out_buf);
}

fn deactivateGhostList(list: *GhostList, out_buf: []u8) !void {
    var w: std.Io.Writer = .fixed(out_buf);
    list.deactivate(&w) catch return;
    if (w.end > 0) try writeAll(posix.STDOUT_FILENO, out_buf[0..w.end]);
}
