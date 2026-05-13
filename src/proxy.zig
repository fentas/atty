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
const Osc7 = @import("osc7.zig").Osc7;
const subprocess_mod = @import("subprocess.zig");

/// The single dispatcher specialisation used by the binary. Comptime
/// expansion of `config.modules` happens here.
const D = dispatch.Dispatcher(config.modules);

const buf_size = 4096;

pub const Args = struct {
    /// argv for the child process. Sentinel-terminated.
    argv: [*:null]const ?[*:0]const u8,
    /// True if stdout AND stdin are real TTYs.
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
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: Args) !ExitInfo {
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
            var shell_size = s;
            if (statusbar) |sb| shell_size.rows = sb.effectiveRows();
            _ = pty.setSize(shell_size) catch {};
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
    // Remember the previous OSC 133 phase so we can detect the
    // edge transitions (`in_input → in_command` = `;C`,
    // `in_command → idle` = `;D`) — Osc133 doesn't track edges
    // itself.
    var prev_osc_phase: Osc133.Phase = osc133_tracker.phase;

    var ctx = module.Context{
        .allocator = allocator,
        .io = io,
        .line = &line_state,
        .scratch = &scratch,
        .is_tty = args.is_tty,
        .incognito = false,
        .subprocess = &subprocess_tracker,
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
                const matched_binding = matched_action != null;
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
                            const current = line_state.current();
                            if (!line_state.uncertain and current.len > 0) {
                                // Fire the deletion across modules that
                                // implement the hook.
                                D.dispatchDeleteHistoryMatch(&runtimes, &ctx, current) catch {};
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
                                        .{current},
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
                //   2. If it doesn't (Ctrl+9, Ctrl+Shift+Right, …),
                //      drop to avoid mojibake.
                var legacy_buf: [8]u8 = undefined;
                if (!matched_binding and config.terminal.enable_kitty_keyboard and keymap.isCsiU(input)) {
                    if (keymap.csiUToLegacy(input, &legacy_buf)) |legacy| {
                        input = legacy;
                    } else {
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
                _ = line_state.applyInput(input);

                // If the user pressed Enter AND the OSC 133 tracker
                // is active (shell emits prompt-zone markers), the
                // marker stream's captured input is the ground truth
                // for what's about to be committed — including any
                // text the shell put there via history recall /
                // completion / paste that line_state's keystroke
                // tracking can't observe. Override.
                if (osc133_tracker.active and containsEnter(input) and osc133_tracker.currentInput().len > 0) {
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
                const shell_saw_enter = switch (action) {
                    .forward => containsEnter(input),
                    .swallow => false,
                    .replace => |bytes| containsEnter(bytes),
                    .replace_commit => containsEnter(input),
                };
                if (line_state.lastCommitted()) |committed| {
                    const leading_space = committed.len > 0 and committed[0] == ' ';
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
                osc133_tracker.feed(output);
                alt_screen.feed(output);
                osc7_tracker.feed(output);

                // Promote any pending OSC 7 cwd capture into the top
                // subprocess frame. Order matters: this runs AFTER
                // we've fed OSC 133, so if a `;C` transition arrives
                // in the SAME chunk we push first and the OSC 7
                // capture (if any) lands on the freshly-pushed frame.
                const remote_cwd = osc7_tracker.takeCwd();
                if (remote_cwd.len > 0) subprocess_tracker.onRemoteCwd(remote_cwd);

                // Edge-detect OSC 133 phase transitions to drive the
                // subprocess stack. ;C (in_input → in_command) means
                // a command just started running — peek at the line
                // the user committed and decide whether to push a
                // recognised launcher frame. ;D (in_command → idle)
                // means the command finished and we pop.
                //
                // We watch `phase` rather than relying on a custom
                // edge flag from Osc133 because the existing
                // line_state.lastCommitted is only valid for one
                // dispatch cycle; doing the parse synchronously
                // here, immediately after feed, lets us grab it
                // before clearLastCommitted runs (further below in
                // the stdin path) or before the next read overwrites
                // anything.
                const curr_osc_phase = osc133_tracker.phase;
                if (curr_osc_phase != prev_osc_phase) {
                    if (prev_osc_phase != .in_command and curr_osc_phase == .in_command) {
                        // ;C — push a frame parsed from the just-
                        // committed line. `lastCommitted` was set by
                        // the stdin path when the user pressed Enter
                        // (or via the OSC 133 input override there).
                        const launched = line_state.lastCommitted() orelse "";
                        subprocess_tracker.onCommandStart(launched, allocator, io);
                    } else if (prev_osc_phase == .in_command and curr_osc_phase != .in_command) {
                        // ;D — pop. We do NOT care which kind we
                        // popped; the Tracker handles the stack
                        // invariant and resets the popped frame so
                        // a stale name can't leak.
                        subprocess_tracker.onCommandEnd();
                    }
                    prev_osc_phase = curr_osc_phase;
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
                if (osc133_tracker.inInputPhase()) {
                    line_state.syncFromCapture(osc133_tracker.currentInput());
                }

                D.dispatchOutput(&runtimes, &ctx, output) catch {};
                try writeAll(posix.STDOUT_FILENO, output);

                // Deferred alt-screen side effects — see the captured
                // `alt_transitioned` / `alt_now_active` above. Run AFTER
                // forwarding `output` so the terminal has already
                // honoured the enter/exit byte before we layer our own
                // bytes (statusbar repaint) or signal the slave (resize
                // + SIGWINCH).
                if (alt_transitioned) {
                    if (statusbar) |*sb| {
                        if (Pty.querySize(posix.STDOUT_FILENO)) |s| {
                            var shell_size = s;
                            if (!alt_now_active) {
                                shell_size.rows = sb.effectiveRows();
                                // Use the lighter `reactivate` here,
                                // not `activate`. activate's ED 2
                                // clears the whole screen + homes the
                                // cursor — if the shell drew a prompt
                                // immediately after `?1049l` in the
                                // same `output` chunk, that prompt is
                                // already on the primary screen and
                                // ED 2 would wipe it. reactivate
                                // restores DECSTBM + clears the
                                // reserved rows around a save/restore-
                                // cursor, leaving anything the shell
                                // already drew untouched.
                                var w2: std.Io.Writer = .fixed(&out_buf);
                                sb.reactivate(&w2) catch {};
                                if (w2.end > 0) writeAll(posix.STDOUT_FILENO, out_buf[0..w2.end]) catch {};
                            }
                            _ = pty.setSize(shell_size) catch {};
                        } else |_| {}
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
                        var shell_size = s;
                        if (statusbar) |*sb| {
                            sb.onResize(s.rows, s.cols);
                            // While an alt-screen TUI is running the
                            // statusbar is suspended and the app owns
                            // every row — don't re-paint the reserved
                            // zone or slim the slave size. On exit
                            // (?1049l) the master-output path runs
                            // sb.activate again with the current size.
                            if (!alt_screen.active) {
                                var w: std.Io.Writer = .fixed(&out_buf);
                                sb.activate(&w) catch {};
                                try writeAll(posix.STDOUT_FILENO, out_buf[0..w.end]);
                                shell_size.rows = sb.effectiveRows();
                            }
                        }
                        _ = pty.setSize(shell_size) catch {};
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

fn containsEnter(bytes: []const u8) bool {
    for (bytes) |b| if (b == 0x0D or b == 0x0A) return true;
    return false;
}

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

/// Shared write loop used by every fd-target write in the proxy.
/// `INTR` is retried (signal arrived mid-syscall); every other
/// errno propagates as `error.WriteFailed`. Notably `EAGAIN` is
/// **not** retried — every fd we write to is blocking by design
/// (pty.master, stdout for ghost overlays), so `EAGAIN` indicates
/// the caller flipped the fd to non-blocking and we should surface
/// it explicitly rather than tight-loop until a future POLLOUT.
/// `EBADF` / `EIO` from PTY teardown is the other path this gate
/// guards against — those used to spin at 100% CPU.
fn writeFully(fd: posix.fd_t, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = std.c.write(fd, bytes[i..].ptr, bytes.len - i);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return error.WriteFailed;
        }
        if (rc == 0) return error.EndOfFile;
        i += @intCast(rc);
    }
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    return writeFully(fd, bytes);
}

/// Thin Writer adapter so `keymap.translateCsiUStream` (which
/// speaks the generic Writer interface) can target the PTY master
/// directly, without an intermediate buffer. Delegates to
/// `writeFully` so the errno-gated retry policy is the only
/// implementation of the write loop in this file.
const PtmWriter = struct {
    fd: posix.fd_t,
    pub fn writeAll(self: PtmWriter, bytes: []const u8) !void {
        return writeFully(self.fd, bytes);
    }
};

/// Render the current best suggestion (or clear the overlay if no
/// module wants one). Idempotent.
///
/// `out_buf` is a caller-owned scratch buffer; we wrap it in a fixed
/// `std.Io.Writer`, let the Ghost state machine emit ANSI bytes into
/// it, then flush in a single `std.c.write` syscall.
fn renderGhost(rts: *D.Runtimes, ctx: *module.Context, ghost: *Ghost, out_buf: []u8) !void {
    if (!ctx.is_tty) return;

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

    // First gather the module contributions into a scratch buffer.
    var mod_buf: [192]u8 = undefined;
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
            if (tr.current()) |frame| if (frame.kind != .none) {
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
            };
        }
    }

    // Then ask the pure assembler to join incognito + subprocess +
    // base + modules with " │ " separators, skipping empty segments.
    // Pure logic + own tests live in src/status_text.zig.
    var text_buf: [512]u8 = undefined;
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
