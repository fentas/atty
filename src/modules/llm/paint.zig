//! Paint surface for the LLM module — alt-screen chat overlay,
//! inline chat panel, OSC 12/112 cursor-colour transitions, and the
//! `provideTermBytes` hook that schedules each one. Extracted from
//! `llm.zig` to keep the implementation file small; the production
//! code is verbatim — only the wrapping `Module(cfg, Runtime)`
//! factory is new.
//!
//! Only `provideTermBytes` is public — it's re-exported from
//! `llm.zig` as the module hook the dispatcher invokes. Every
//! other symbol (paint helpers, sanitiser, OSC escape constants)
//! is module-private; nothing in `llm.zig` calls them directly.

const std = @import("std");
const m = @import("../../module.zig");
const dialog = @import("dialog.zig");
const types = @import("types.zig");
const pty_mod = @import("../../pty.zig");
const Pty = pty_mod.Pty;

pub fn Module(comptime cfg: types.Config, comptime Runtime: type) type {
    return struct {
        // `latchErr` is part of the dialog Module helpers — same
        // factory pattern, called from provideTermBytes when paint
        // overflows. Re-binding here keeps the paint code's call
        // sites unchanged from when it lived in llm.zig.
        const dialog_helpers = dialog.Module(cfg, Runtime);
        const latchErr = dialog_helpers.latchErr;

        // Pre-built OSC escape strings; comptime-baked from the
        // configured colour so we don't allocate per tick. Emitted
        // by `provideTermBytes` on edge transitions (one-shot per
        // edge) when the user types a prefix-matched prompt — the
        // terminal doesn't see redundant OSC traffic on every tick.
        const cursor_set_seq = "\x1B]12;" ++ cfg.prefix_signal_cursor_color ++ "\x07";
        const cursor_reset_seq = "\x1B]112\x07";

        /// Write `bytes` to `w` filtering out control bytes that
        /// would otherwise hijack the terminal — embedded `\x1B`
        /// in an LLM response would smuggle escape sequences into
        /// our overlay paint, breaking the layout (the screenshot
        /// bug). Tabs and printable bytes pass through; newlines
        /// become spaces so each turn renders on a single visual
        /// line that the terminal wraps naturally inside the
        /// scroll region.
        fn writeSanitized(w: *std.Io.Writer, bytes: []const u8) !void {
            for (bytes) |b| {
                if (b == 0x1B or b == 0x7F or (b < 0x20 and b != 0x09)) {
                    // Replace newline with space; drop all other
                    // C0 + ESC + DEL silently.
                    if (b == 0x0A or b == 0x0D) try w.writeAll(" ") else continue;
                } else {
                    try w.writeByte(b);
                }
            }
        }

        /// Render the chat overlay's open or close sequence into
        /// `rt.chat_overlay_buf`. Returns false when the content
        /// overflows the buffer (caller skips the paint rather
        /// than emitting a partial alt-screen sequence).
        ///
        /// Layout (on open):
        ///   - title bar at row 1 + blank row 2
        ///   - turns rendered into a DECSTBM scroll region
        ///     spanning rows 1 .. rows-2 (terminal auto-wraps +
        ///     scrolls long content within that region)
        ///   - chat input at row rows-1 + footer at row rows
        ///     (outside the scroll region so they stay anchored)
        ///
        /// **Known limitation:** on terminals with GLOBAL DECSTBM
        /// scope (rare; most modern terminals isolate DECSTBM
        /// per-buffer), the close path's `\x1B[r` may wipe the
        /// statusbar's reserved scroll region until SIGWINCH or
        /// another paint triggers `sb.activate`. Phase 2c
        /// (proxy-level overlay surface) will route close through
        /// the proxy so `sb.reactivate` fires automatically.
        fn paintChatOverlay(rt: *Runtime) bool {
            var w: std.Io.Writer = .fixed(&rt.chat_overlay_buf);
            if (!rt.chat_overlay_open) {
                // Close: reset scroll region (the alt-screen had its
                // own DECSTBM but resetting before exit is defensive
                // for terminals that don't isolate per-buffer scroll
                // regions); restore cursor visibility; leave alt
                // screen. The order matters — the shell expects its
                // cursor back; doing it after the alt-screen exit
                // would briefly flash the cursor on the underlying
                // screen at row/col (1,1) before the shell repaints.
                w.writeAll("\x1B[r\x1B[?25h\x1B[?1049l") catch return false;
                rt.chat_overlay_buf_len = w.end;
                return true;
            }

            // Query terminal size so we can pin footer + input at
            // the bottom rows and confine turn rendering inside a
            // DECSTBM scroll region (rows 1..rows-2). Without this
            // bound, long assistant turns wrap past the screen and
            // the absolute-positioned footer at `\x1B[999;1H`
            // collides with the wrapped content above it — the
            // user-visible "broken overlay" bug.
            //
            // Falls back to a conservative 24×80 if the ioctl
            // fails (won't in practice on a TTY — main.zig refuses
            // non-TTY stdio — but defensive).
            const size = Pty.querySize(std.posix.STDOUT_FILENO) catch
                pty_mod.WinSize{ .rows = 24, .cols = 80, .xpixel = 0, .ypixel = 0 };
            const rows: u16 = if (size.rows > 4) size.rows else 4;
            const content_bottom: u16 = rows - 2;
            // `size.cols` available but unused — wrap calculations
            // are a future follow-up (codepoint-level turn rendering
            // instead of relying on the terminal's auto-wrap inside
            // the scroll region).

            // Open: enter alt screen, hide the real terminal cursor
            // (the input row paints its own reverse-video block
            // cursor; without `?25l` the real cursor parks adjacent
            // to it and the user sees two), clear, set scroll region
            // to rows 1..content_bottom (leaves the last two rows
            // free for input + footer), cursor home.
            w.print("\x1B[?1049h\x1B[?25l\x1B[2J\x1B[1;{d}r\x1B[1;1H", .{content_bottom}) catch return false;
            // Title bar — dim chrome so it reads as frame, not content.
            // Coloured icon picks up the same fg=141 used in the
            // statusbar AI hint (consistent visual vocabulary).
            w.writeAll("\x1B[2m\x1B[22;38;5;141m\u{2728}\x1B[39;2m atty chat \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\x1B[0m\r\n\r\n") catch return false;

            const has_turns = rt.turns_len > 0;
            const has_conclusion = rt.conclusion_len > 0;
            if (!has_turns and !has_conclusion) {
                w.writeAll("  \x1B[2m(no conversation yet \u{2014} start one with Alt+S)\x1B[0m\r\n") catch return false;
            } else {
                for (rt.turns[0..rt.turns_len]) |turn| {
                    const prefix: []const u8 = switch (turn.kind) {
                        .user => "\x1B[22;1;38;5;14mYou:\x1B[0m ",
                        .assistant_exec => "\x1B[22;38;5;141matty:\x1B[0m ",
                        .observation => "\x1B[2mOutput:\x1B[0m ",
                    };
                    w.writeAll(prefix) catch return false;
                    // Sanitize: strip embedded ESC / control bytes
                    // so a model that sneaks `\x1B[…` into its
                    // reason field can't hijack our overlay paint.
                    // Cap to ~512 chars rendered so a huge JSON
                    // envelope doesn't fill the screen with one
                    // turn; truncation marker dimmed.
                    const slice = if (turn.content.len > 512) turn.content[0..512] else turn.content;
                    writeSanitized(&w, slice) catch return false;
                    if (turn.content.len > 512) {
                        w.writeAll(" \x1B[2m[\u{2026}truncated]\x1B[0m") catch return false;
                    }
                    w.writeAll("\r\n\r\n") catch return false;
                }
                if (has_conclusion and !has_turns) {
                    // Fallback: when the dialog already wrapped up
                    // (turns wiped on dialogReset) but the
                    // conclusion banner survived, surface it as
                    // the overlay's content. Conclusion was built
                    // by atty so it's safe to write unsanitized.
                    w.writeAll(rt.conclusion_buf[0..rt.conclusion_len]) catch return false;
                    w.writeAll("\r\n") catch return false;
                }
            }

            // Input row + footer hint anchored at the bottom rows,
            // OUTSIDE the scroll region so they don't move when
            // turn content overflows + scrolls.
            //
            //   row `rows-1`   → "❯ <input>█"
            //   row `rows`     → "[Alt+Shift+C close · Enter send]"
            //
            // Each absolute-positioned + line-cleared so any
            // pre-existing terminal state on those rows can't
            // bleed through.
            w.print("\x1B[{d};1H\x1B[2K", .{rows - 1}) catch return false;
            w.writeAll("\x1B[22;1;38;5;14m\u{276F}\x1B[0m ") catch return false;
            // Render the input buffer split at the cursor so the
            // reverse-video block cursor lands AT the insertion
            // point. The 512-byte tail clamp from the no-cursor
            // version is kept but skewed around the cursor when
            // the buffer is long.
            {
                const cur = rt.chat_input_cursor;
                const len = rt.chat_input_len;
                // Clamp the visible window: aim to keep the cursor
                // visible. Show up to 512 bytes total, centered
                // around the cursor when the buffer overflows.
                const visible_max: usize = 512;
                var win_start: usize = 0;
                var win_end: usize = len;
                if (len > visible_max) {
                    // Center the cursor; clip to the buffer ends.
                    const half = visible_max / 2;
                    win_start = if (cur > half) cur - half else 0;
                    win_end = if (win_start + visible_max < len) win_start + visible_max else len;
                }
                if (cur > win_start) {
                    writeSanitized(&w, rt.chat_input_buf[win_start..cur]) catch return false;
                }
                // Block-cursor — render the byte AT cursor under
                // reverse video when there's one, otherwise a
                // reverse-video space for end-of-line.
                if (cur < len) {
                    w.writeAll("\x1B[7m") catch return false;
                    writeSanitized(&w, rt.chat_input_buf[cur .. cur + 1]) catch return false;
                    w.writeAll("\x1B[0m") catch return false;
                    if (cur + 1 < win_end) {
                        writeSanitized(&w, rt.chat_input_buf[cur + 1 .. win_end]) catch return false;
                    }
                } else {
                    w.writeAll("\x1B[7m \x1B[0m") catch return false;
                }
            }

            w.print("\x1B[{d};1H\x1B[2K", .{rows}) catch return false;
            w.writeAll("\x1B[2m[Alt+Shift+C close \u{00B7} Enter send]\x1B[0m") catch return false;
            rt.chat_overlay_buf_len = w.end;
            return true;
        }

        /// Paint the inline chat panel into the rows the statusbar
        /// has just reserved above the hint row. The proxy is
        /// responsible for emitting `setReserveRows + activate`
        /// before this paint runs — `activate` blanks the reserved
        /// zone and re-anchors DECSTBM so the shell stops scrolling
        /// into the panel.
        ///
        /// Layout, top→bottom (panel rows = `cfg.inline_chat_rows`,
        /// e.g. 10):
        ///
        ///   • divider row — dim icon + "atty chat" label + Alt+C hint
        ///   • scrollback rows — recent turns (assistant + user),
        ///     wrap auto-handled by terminal inside the bounds set
        ///     by per-row CUP + EL
        ///   • input row — `❯ <typed text>█` with reverse-video block cursor
        ///
        /// Close: emits an empty paint plus a DECSC/DECRC pair so
        /// the cursor returns to the shell's previous position
        /// after the proxy's `setReserveRows(base) + activate` has
        /// shrunk the reservation back. (The proxy clears the freed
        /// rows itself via `activate`; the paint doesn't need to.)
        /// Render a turn's content for the chat scrollback. When
        /// the assistant produced a JSON envelope (the dialog
        /// protocol shape), extract the human-meaningful field —
        /// `description`+`command` for exec, `reason` for done,
        /// `question` for question — and present it as prose +
        /// a dim command preview. Falls back to the raw content
        /// when parsing fails (single-mode replies, prose drift).
        ///
        /// `max_visible` caps the visible cols on a single row;
        /// longer content gets a "[…]" ellipsis. The actual row
        /// CUP + clear is done by the caller; we only emit content
        /// bytes (and SGR resets).
        fn renderTurnContent(w: *std.Io.Writer, turn: dialog.Turn, max_visible: usize) !void {
            const c = turn.content;
            // Quick shape check: assistant turns from the dialog
            // protocol always start with `{` and contain `"action"`.
            // Avoids a full JSON parse on every paint for user /
            // observation turns whose contents are free prose.
            const looks_like_envelope = turn.kind == .assistant_exec and
                c.len > 2 and
                c[0] == '{' and
                std.mem.indexOf(u8, c, "\"action\"") != null;
            if (!looks_like_envelope) {
                const slice = if (c.len > max_visible) c[0..max_visible] else c;
                try writeSanitized(w, slice);
                if (c.len > max_visible) try w.writeAll(" \x1B[2m[\u{2026}]\x1B[0m");
                return;
            }
            // Parse with the dialog parser so any "open_chat as
            // separate object" or trailing-prose drift falls back
            // to the raw render (which at least surfaces what the
            // model emitted instead of vanishing). Allocator: a
            // local fixed-buffer stream avoids touching the
            // dialog allocator from a paint hook.
            const R = dialog.Response(cfg.max_response_bytes);
            var parsed: R = .{};
            // `parseResponse` needs an allocator — the JSON parser
            // walks the tree once. The paint hook doesn't have a
            // long-lived allocator handy; use a heap fallback for
            // the typical small envelope. On any parse error,
            // fall through to raw rendering.
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            dialog.parseResponse(R, arena.allocator(), c, &parsed) catch {
                const slice = if (c.len > max_visible) c[0..max_visible] else c;
                try writeSanitized(w, slice);
                if (c.len > max_visible) try w.writeAll(" \x1B[2m[\u{2026}]\x1B[0m");
                return;
            };
            // Per-action rendering — keep it one row each.
            switch (parsed.action) {
                .exec => {
                    const cmd = parsed.command();
                    const desc = parsed.description();
                    if (desc.len > 0) {
                        try writeSanitized(w, if (desc.len > max_visible / 2) desc[0..(max_visible / 2)] else desc);
                        try w.writeAll(" \x1B[2m\u{2192}\x1B[0m ");
                    }
                    // Command in cyan-on-default to stand out as the
                    // actionable bit.
                    try w.writeAll("\x1B[22;38;5;14m");
                    const cmd_room: usize = if (max_visible > 20) max_visible - 20 else max_visible;
                    try writeSanitized(w, if (cmd.len > cmd_room) cmd[0..cmd_room] else cmd);
                    try w.writeAll("\x1B[0m");
                    if (cmd.len > cmd_room) try w.writeAll(" \x1B[2m[\u{2026}]\x1B[0m");
                },
                .question => {
                    const q = parsed.question();
                    const slice = if (q.len > max_visible) q[0..max_visible] else q;
                    try w.writeAll("\x1B[3m"); // italic
                    try writeSanitized(w, slice);
                    try w.writeAll("\x1B[0m");
                    if (q.len > max_visible) try w.writeAll(" \x1B[2m[\u{2026}]\x1B[0m");
                },
                .done => {
                    const r = parsed.reason();
                    try w.writeAll("\x1B[22;38;5;141m\u{2713}\x1B[0m "); // mauve check
                    const slice = if (r.len > max_visible) r[0..max_visible] else r;
                    try writeSanitized(w, slice);
                    if (r.len > max_visible) try w.writeAll(" \x1B[2m[\u{2026}]\x1B[0m");
                },
            }
        }

        /// Compute the row the real terminal cursor should sit at
        /// after every paintInlineChat call. Pulls from the snapshot
        /// taken at open time (`rt.chat_open_cursor_row`), falling
        /// back to the bottom of the shell scroll region when the
        /// snapshot is unknown OR was clamped past the shell area
        /// (defensive against cursor_tracker drift / SIGWINCH races).
        ///
        /// Anchors to `total_rows - base_reserve` (a row that's
        /// stable across panel open/close) — DO NOT switch to a
        /// live-reserve denominator, that would move the fallback
        /// between open and close and break the close-paint's
        /// ability to land on the same row the open paint used.
        fn inlineRestoreRow(rt: *Runtime, total_rows: u16, base_reserve: u16) u16 {
            const shell_bottom: u16 = if (total_rows > base_reserve) total_rows - base_reserve else 1;
            if (rt.chat_open_cursor_row == 0) return shell_bottom;
            if (rt.chat_open_cursor_row > shell_bottom) return shell_bottom;
            return rt.chat_open_cursor_row;
        }

        fn paintInlineChat(rt: *Runtime, ctx: *m.Context) bool {
            var w: std.Io.Writer = .fixed(&rt.chat_inline_buf);

            if (!rt.chat_inline_open) {
                // CUP via inlineRestoreRow — DECRC is clobbered by
                // applyReserveRows upstream.
                const ct_rows: u16 = ctx.terminal_rows orelse 24;
                const ct_base: u16 = ctx.statusbar_base_reserve orelse 3;
                const restore_row = inlineRestoreRow(rt, ct_rows, ct_base);
                w.print("\x1B[?25h\x1B[{d};1H", .{restore_row}) catch return false;
                rt.chat_inline_buf_len = w.end;
                return true;
            }

            // Read terminal + statusbar geometry from Context — the
            // proxy refreshes these every iteration so a SIGWINCH
            // and any inline-reservation clamp are already reflected.
            // Fall back to a defensive query / 24×80 default for
            // non-TTY callers (unit tests).
            const total_rows: u16 = ctx.terminal_rows orelse blk: {
                const s = Pty.querySize(std.posix.STDOUT_FILENO) catch
                    pty_mod.WinSize{ .rows = 24, .cols = 80, .xpixel = 0, .ypixel = 0 };
                break :blk if (s.rows > 4) s.rows else 4;
            };
            const total_cols: u16 = ctx.terminal_cols orelse 80;
            const base_reserve: u16 = ctx.statusbar_base_reserve orelse 3;
            // `statusbar_reserve` carries the proxy's clamp when
            // the terminal is too small for base + inline_chat_rows;
            // panel_rows = live - base derives the true (possibly
            // clamped) panel height.
            const live_reserve: u16 = ctx.statusbar_reserve orelse
                (base_reserve + cfg.inline_chat_rows);
            if (live_reserve <= base_reserve or total_rows <= live_reserve) {
                // Terminal too small to fit any panel rows on top of
                // the base reservation, or the proxy clamped us into
                // a no-op. Roll the open flag back so the user isn't
                // trapped — proxy will shrink the reservation next
                // tick.
                w.writeAll("\x1B[?25h\x1B[u") catch return false;
                rt.chat_inline_buf_len = w.end;
                return false;
            }
            const panel_rows: u16 = live_reserve - base_reserve;
            const top_row: u16 = total_rows - live_reserve + 1;
            const input_row: u16 = top_row + panel_rows - 1;

            // Save cursor. When focus is IN the panel, hide the real
            // terminal cursor — we draw a block-cursor glyph in the
            // chat input row as the visual marker. When focus is
            // PARKED on the shell prompt above (Ctrl+Up), keep the
            // real cursor VISIBLE because that's where the user is
            // typing; the input-row block glyph dims out to reflect
            // "panel parked." DECRC at the end of the paint puts
            // the real cursor back wherever it was when paint
            // started (typically the shell's prompt position).
            if (rt.chat_focus_in_panel) {
                w.writeAll("\x1B[?25l\x1B[s") catch return false;
            } else {
                w.writeAll("\x1B[?25h\x1B[s") catch return false;
            }

            // Top divider row — dim chrome + mauve icon + cyan
            // shortcut, matching the overlay's visual vocabulary.
            // In incognito mode, swap the ✨ sparkle for a 🕶 glasses
            // glyph (`\u{1F576}`) so the user sees at a glance that
            // their typing won't be recorded locally. NOTE: incognito
            // gates LOCAL recording (atuin / shell history); chat
            // prompts STILL go to the remote LLM API. The visual cue
            // is "won't be saved here," not "won't leave this box."
            const cols_usize: usize = total_cols;
            w.print("\x1B[{d};1H\x1B[2K", .{top_row}) catch return false;
            const title: []const u8 = if (ctx.incognito)
                "\x1B[2m\x1B[22;38;5;141m\u{1F576}\x1B[39;2m atty chat (incognito) \u{2500}"
            else
                "\x1B[2m\x1B[22;38;5;141m\u{2728}\x1B[39;2m atty chat \u{2500}";
            w.writeAll(title) catch return false;
            // Pad the divider with horizontal-line characters across
            // the rest of the row. cols_usize floor at 20 to avoid
            // pathological zero-width panes.
            // 🕶 / ✨ render double-width in Ghostty/kitty/foot/wezterm;
            // "(incognito)" adds 12 cols, label trailer `─ ` adds 2.
            const label_visible: usize = if (ctx.incognito) 26 else 15;
            // " Alt+C close · Enter send" is 25 visible cols.
            const trail_min_clearance: usize = 25;
            const trail_target: usize = if (cols_usize > label_visible + trail_min_clearance)
                cols_usize - label_visible - trail_min_clearance
            else
                4;
            var i: usize = 0;
            while (i < trail_target) : (i += 1) {
                w.writeAll("\u{2500}") catch return false;
            }
            w.writeAll(" \x1B[22;38;5;14mAlt+C\x1B[39;2m close \u{00B7} \x1B[22;38;5;14mEnter\x1B[39;2m send\x1B[0m") catch return false;

            // Scrollback rows — fill from oldest visible turn to
            // most recent, each on its own row, truncated to fit
            // the available cols. Walk turns oldest→newest into a
            // row budget so the MOST RECENT lines anchor at the
            // bottom (above input) and older turns scroll off the
            // top.
            const scrollback_rows: u16 = panel_rows - 2; // reserve top divider + input row
            var row: u16 = top_row + 1;
            // Blank-clear every scrollback row up front so prior
            // chat content doesn't leak when the turns shrink.
            var r: u16 = row;
            while (r < input_row) : (r += 1) {
                w.print("\x1B[{d};1H\x1B[2K", .{r}) catch return false;
            }

            // Build a list of rendered "lines" (one line per turn
            // for now — wrapping is a future follow-up). Render the
            // last N where N = scrollback_rows.
            const start_turn: usize = if (rt.turns_len > scrollback_rows) rt.turns_len - scrollback_rows else 0;
            row = top_row + 1;
            const max_inline_visible: usize = if (cols_usize > 12) cols_usize - 6 else 40;
            for (rt.turns[start_turn..rt.turns_len]) |turn| {
                if (row >= input_row) break;
                w.print("\x1B[{d};1H\x1B[2K", .{row}) catch return false;
                const prefix: []const u8 = switch (turn.kind) {
                    .user => "\x1B[22;1;38;5;14mYou:\x1B[0m ",
                    .assistant_exec => "\x1B[22;38;5;141matty:\x1B[0m ",
                    .observation => "\x1B[2mOutput:\x1B[0m ",
                };
                w.writeAll(prefix) catch return false;
                renderTurnContent(&w, turn, max_inline_visible) catch return false;
                row += 1;
            }
            if (rt.turns_len == 0) {
                w.print("\x1B[{d};1H\x1B[2K", .{top_row + 1}) catch return false;
                w.writeAll("  \x1B[2m(empty \u{2014} type a prompt below \u{00B7} Enter to ask)\x1B[0m") catch return false;
            }

            // Input row — `❯ <input>█` with reverse-video block
            // cursor. Always painted last so the actual terminal
            // cursor (positioned by the final CUP at the end of
            // this paint) sits adjacent to it.
            w.print("\x1B[{d};1H\x1B[2K", .{input_row}) catch return false;
            // Chrome glyph dims when focus is parked on the shell —
            // signals the panel is non-interactive at the moment.
            const prompt_style: []const u8 = if (rt.chat_focus_in_panel)
                "\x1B[22;1;38;5;14m"
            else
                "\x1B[2;38;5;14m";
            w.writeAll(prompt_style) catch return false;
            w.writeAll("\u{276F}\x1B[0m ") catch return false;
            // Render the input buffer split at the cursor so the
            // block-cursor glyph lands AT the insertion point. The
            // 512-byte window from the cursor-less version is kept,
            // centered around the cursor when the buffer overflows.
            {
                const cur = rt.chat_inline_input_cursor;
                const len = rt.chat_inline_input_len;
                const visible_max: usize = 512;
                var win_start: usize = 0;
                var win_end: usize = len;
                if (len > visible_max) {
                    const half = visible_max / 2;
                    win_start = if (cur > half) cur - half else 0;
                    win_end = if (win_start + visible_max < len) win_start + visible_max else len;
                }
                const dim = !rt.chat_focus_in_panel;
                if (dim) w.writeAll("\x1B[2m") catch return false;
                if (cur > win_start) {
                    writeSanitized(&w, rt.chat_inline_input_buf[win_start..cur]) catch return false;
                }
                if (dim) w.writeAll("\x1B[0m") catch return false;

                // Block-cursor glyph: bright reverse-video when
                // focused, dim outline when parked. If cursor is
                // BEFORE end, render the byte under the cursor in
                // reverse video instead of a bare space so the
                // user sees what's about to be edited.
                if (cur < len and rt.chat_focus_in_panel) {
                    w.writeAll("\x1B[7m") catch return false;
                    writeSanitized(&w, rt.chat_inline_input_buf[cur .. cur + 1]) catch return false;
                    w.writeAll("\x1B[0m") catch return false;
                } else if (rt.chat_focus_in_panel) {
                    w.writeAll("\x1B[7m \x1B[0m") catch return false;
                } else {
                    w.writeAll("\x1B[2m\u{2592}\x1B[0m") catch return false;
                }

                if (cur + 1 < win_end and rt.chat_focus_in_panel) {
                    writeSanitized(&w, rt.chat_inline_input_buf[cur + 1 .. win_end]) catch return false;
                } else if (cur < win_end and !rt.chat_focus_in_panel) {
                    // Parked: render the unconsumed tail dimmed too.
                    w.writeAll("\x1B[2m") catch return false;
                    writeSanitized(&w, rt.chat_inline_input_buf[cur..win_end]) catch return false;
                    w.writeAll("\x1B[0m") catch return false;
                }
            }
            // The block-cursor glyph above is a static visual marker;
            // park the real terminal cursor back on the shell row so
            // echoed bytes land at the prompt. See inlineRestoreRow.
            const restore_row_open = inlineRestoreRow(rt, total_rows, base_reserve);
            w.print("\x1B[{d};1H", .{restore_row_open}) catch return false;

            rt.chat_inline_buf_len = w.end;
            return true;
        }

        pub fn provideTermBytes(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
            // Inline chat panel — takes precedence over the
            // alt-screen overlay because they're mutually exclusive
            // (the action handler enforces this) and the inline
            // panel is what the user is interacting with when its
            // paint latch is set.
            if (rt.chat_inline_paint_pending) {
                rt.chat_inline_paint_pending = false;
                if (paintInlineChat(rt, ctx)) {
                    return rt.chat_inline_buf[0..rt.chat_inline_buf_len];
                }
                // Paint failed (terminal too small or buffer
                // overflow). Roll the open flag back so the input
                // swallow releases and the proxy shrinks the
                // reservation on the next tick. Surface a hint so
                // the failure isn't silent.
                if (rt.chat_inline_open) {
                    rt.chat_inline_open = false;
                    latchErr(rt, "inline chat: terminal too small or paint buffer overflow");
                    const inline_overflow_msg = "atty: inline chat: terminal too small or paint buffer overflow\n";
                    _ = std.c.write(2, inline_overflow_msg, inline_overflow_msg.len);
                }
            }
            // Chat overlay paint (phase 2a) takes precedence over
            // the conclusion + cursor-colour paths. The overlay's
            // alt-screen lives at the outer terminal, while
            // conclusion is for scroll-history and cursor-colour is
            // for the prompt area — they're mutually exclusive
            // surfaces.
            if (rt.chat_overlay_paint_pending) {
                rt.chat_overlay_paint_pending = false;
                if (paintChatOverlay(rt)) {
                    return rt.chat_overlay_buf[0..rt.chat_overlay_buf_len];
                }
                // Paint overran the buffer. The close path can't
                // overflow (single `?1049l` byte sequence), so this
                // only fires on open. Roll back `chat_overlay_open`
                // so the input swallow releases — otherwise the
                // user would see a frozen shell that eats every
                // keystroke until they remember to press Alt+C
                // again. Surface a hint so the failure mode isn't
                // silent.
                if (rt.chat_overlay_open) {
                    rt.chat_overlay_open = false;
                    latchErr(rt, "chat overlay too big to render — buffer overflow");
                    // Stderr fallback — the statusbar error surface
                    // is gated on `config.statusbar.enabled`, which
                    // defaults to false. Without this the user
                    // sees Alt+C do nothing with no diagnostic.
                    const overflow_msg = "atty: chat overlay too big to render — buffer overflow\n";
                    _ = std.c.write(2, overflow_msg, overflow_msg.len);
                }
            }
            // Conclusion banner emission takes precedence over the
            // cursor-colour edge logic — the banner is one-shot
            // multi-line output that scrolls into shell history;
            // cursor-colour OSC sequences are infinitely retriable
            // on the next tick. Drains the latch (one-shot
            // semantics).
            if (rt.conclusion_pending and rt.conclusion_len > 0) {
                rt.conclusion_pending = false;
                return rt.conclusion_buf[0..rt.conclusion_len];
            }
            if (!cfg.prefix_signal_cursor) return null;
            // Cursor colour fires when EITHER the prefix is matched
            // (user typing `#: …`) OR persistent dialog/auto mode
            // is active. The latter makes the colour stick across
            // the whole multi-step interaction — useful visual
            // confirmation that you're "talking to the LLM" even
            // when the line content doesn't have the prefix
            // (e.g. while reviewing an LLM-injected command).
            const line = ctx.line.current();
            const matches = std.mem.startsWith(u8, line, cfg.prefix) or rt.dialog_persistent_mode != .off;
            if (matches and !rt.cursor_signal_active) {
                rt.cursor_signal_active = true;
                return cursor_set_seq;
            }
            if (!matches and rt.cursor_signal_active) {
                rt.cursor_signal_active = false;
                return cursor_reset_seq;
            }
            return null;
        }
    };
}
