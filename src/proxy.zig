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
const RawMode = @import("terminal.zig").RawMode;
const LineState = @import("line_state.zig").LineState;
const Ghost = @import("ghost.zig").Ghost;
const GhostList = @import("ghost_list.zig").GhostList;
const StatusBar = @import("statusbar.zig").StatusBar;
const ansi = @import("ansi.zig");
const style_mod = @import("style.zig");
const status_text = @import("status_text.zig");
const keymap = @import("keymap.zig");
const Osc133 = @import("osc133.zig").Osc133;

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

    var ctx = module.Context{
        .allocator = allocator,
        .io = io,
        .line = &line_state,
        .scratch = &scratch,
        .is_tty = args.is_tty,
        .incognito = false,
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
            renderGhost(&runtimes, &ctx, &ghost, &out_buf) catch {};
            renderGhostList(&runtimes, &ctx, &ghost_list, &out_buf) catch {};
            if (statusbar) |*sb| renderStatus(&runtimes, &ctx, sb, &out_buf, incognito_on) catch {};
            continue;
        }

        // ---- stdin → dispatch → master -----------------------------------
        if (pfds[0].revents & POLLIN != 0) {
            const read_n = posix.read(posix.STDIN_FILENO, &read_buf) catch 0;
            if (read_n > 0) {
                var input: []const u8 = read_buf[0..read_n];

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
                    if (statusbar) |*sb| renderStatus(&runtimes, &ctx, sb, &out_buf, incognito_on) catch {};
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
                    if (!line_state.committed_was_uncertain and
                        !incognito_on and
                        !leading_space and
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
                if (statusbar) |*sb| renderStatus(&runtimes, &ctx, sb, &out_buf, incognito_on) catch {};
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

                renderGhost(&runtimes, &ctx, &ghost, &out_buf) catch {};
                renderGhostList(&runtimes, &ctx, &ghost_list, &out_buf) catch {};
                if (statusbar) |*sb| {
                    // Shell output may have scrolled or overwritten our
                    // reserved row — force a repaint.
                    sb.last_valid = false;
                    renderStatus(&runtimes, &ctx, sb, &out_buf, incognito_on) catch {};
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
                            var w: std.Io.Writer = .fixed(&out_buf);
                            sb.activate(&w) catch {};
                            try writeAll(posix.STDOUT_FILENO, out_buf[0..w.end]);
                            shell_size.rows = sb.effectiveRows();
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

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = std.c.write(fd, bytes[i..].ptr, bytes.len - i);
        if (rc < 0) {
            // EINTR / EAGAIN are vanishingly rare on PTY master; retry.
            continue;
        }
        if (rc == 0) return error.EndOfFile;
        i += @intCast(rc);
    }
}

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

    // Then ask the pure assembler to join incognito + base + modules
    // with " │ " separators, skipping empty segments. Pure logic +
    // own tests live in src/status_text.zig.
    var text_buf: [256]u8 = undefined;
    var tw: std.Io.Writer = .fixed(&text_buf);
    status_text.assemble(.{
        .w = &tw,
        .incognito = incognito,
        .incognito_style = config.statusbar.incognito_style,
        .bar_style = config.statusbar.style,
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
