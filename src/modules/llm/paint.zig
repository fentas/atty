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
const pw = @import("paint_width.zig");
const md_render = @import("md_render.zig");
const pty_mod = @import("../../pty.zig");
const Pty = pty_mod.Pty;
const chat_persist = @import("chat_persist.zig");

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

        /// Write `bytes` to `w` filtering out anything a terminal
        /// could read as a control directive — defense against an
        /// LLM smuggling escape sequences into our paint:
        ///   - C0 controls + DEL (0x00-0x1F + 0x7F): all dropped,
        ///     newlines collapse to single spaces so a turn stays
        ///     on one visual row inside the DECSTBM region.
        ///   - C1 controls (0x80-0x9F): dropped. Most modern
        ///     terminals don't honour 8-bit CSI (0x9B) but a few
        ///     historical ones do; cheap insurance.
        ///   - UTF-8 encoding of C1 (0xC2 followed by 0x80-0x9F):
        ///     drop the pair so the same codepoint can't sneak
        ///     through the multi-byte form. A 0xC2 that's NOT
        ///     followed by a valid continuation byte (0x80-0xBF) is
        ///     also dropped — emitting it alone would land
        ///     malformed UTF-8 on the user's terminal.
        ///   - Tab (0x09) and printable ASCII pass through.
        const writeSanitized = pw.writeSanitized;

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
        /// On terminals with GLOBAL DECSTBM scope (rare; some
        /// configurations of Ghostty) the close's `\x1B[r` would
        /// wipe the statusbar reservation — the proxy now detects
        /// the module-overlay close edge and fires `sb.reactivate`
        /// within the same tick (`proxy.zig`'s `prev_overlay_active`
        /// edge handler).
        fn paintChatOverlay(rt: *Runtime, ctx: *m.Context) bool {
            // Allocating writer — grows the underlying buffer as
            // content lands. Free any previous frame; on success
            // `toOwnedSlice` transfers ownership to
            // `rt.chat_overlay_buf`. Initial 8 KiB capacity covers
            // the open/close chrome and small turn rings; the
            // writer doubles as content grows past the initial
            // allocation.
            if (rt.chat_overlay_buf) |old| {
                rt.allocator.free(old);
                rt.chat_overlay_buf = null;
            }
            var aw = std.Io.Writer.Allocating.initCapacity(rt.allocator, 8 * 1024) catch return false;
            const w = &aw.writer;
            if (!rt.chat_overlay_open) {
                // Close: reset scroll region (the alt-screen had its
                // own DECSTBM but resetting before exit is defensive
                // for terminals that don't isolate per-buffer scroll
                // regions); restore cursor visibility; leave alt
                // screen. The order matters — the shell expects its
                // cursor back; doing it after the alt-screen exit
                // would briefly flash the cursor on the underlying
                // screen at row/col (1,1) before the shell repaints.
                w.writeAll("\x1B[r\x1B[?25h\x1B[?1049l") catch {
                    aw.deinit();
                    return false;
                };
                rt.chat_overlay_buf = aw.toOwnedSlice() catch {
                    aw.deinit();
                    return false;
                };
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
            // Chat-mode question pick-list (#214) — when active,
            // reserve `choice_count` rows above the input row for
            // the choice list. The scroll region shrinks
            // accordingly so turn content can't scroll into the
            // choice list area.
            const question_rows: u16 = if (rt.chat_question_active) @intCast(rt.chat_question_choice_count) else 0;
            const content_bottom: u16 = if (rows > 2 + question_rows) rows - 2 - question_rows else 1;
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
            // Mirror the inline divider's icon + mode-word logic so
            // the overlay surface stays visually consistent: glasses
            // glyph for incognito, parenthetical state flags for
            // any combination of (auto, incognito).
            const overlay_icon: []const u8 = if (ctx.incognito) "\u{1F576}" else "\u{2728}";
            const overlay_mode_word: []const u8 = if (ctx.incognito and rt.auto_mode_active)
                "atty chat (auto, incognito)"
            else if (rt.auto_mode_active)
                "atty chat (auto)"
            else if (ctx.incognito)
                "atty chat (incognito)"
            else
                "atty chat";
            w.print("\x1B[2m\x1B[22;38;5;141m{s}\x1B[39;2m {s} \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\x1B[0m\r\n\r\n", .{ overlay_icon, overlay_mode_word }) catch return false;

            // Clamp the offset against FIFO eviction — pushTurn
            // can shrink `turns_len` after the user scrolled, and
            // an unchecked `turns_len - offset` would underflow.
            const max_offset: usize = if (rt.turns_len > 0) rt.turns_len - 1 else 0;
            const overlay_offset: usize = if (rt.chat_view_offset > max_offset) max_offset else rt.chat_view_offset;
            const tail_end: usize = rt.turns_len - overlay_offset;

            const has_turns = rt.turns_len > 0;
            const has_conclusion = rt.conclusion_formatted != null;
            if (!has_turns and !has_conclusion) {
                w.writeAll("  \x1B[2m(no conversation yet \u{2014} type a prompt below, or Alt+S for a structured dialog)\x1B[0m\r\n") catch return false;
            } else {
                for (rt.turns[0..tail_end]) |turn| {
                    // Structured render: the alt-screen has rows to
                    // spare, so split the envelope into readable
                    // lines instead of dumping raw JSON.
                    const prefix: []const u8 = switch (turn.kind) {
                        .user => "\x1B[22;1;38;5;14mYou:\x1B[0m ",
                        .assistant_exec => "\x1B[22;38;5;141matty:\x1B[0m ",
                        .observation => "\x1B[2mOutput:\x1B[0m ",
                    };
                    w.writeAll(prefix) catch return false;
                    renderOverlayTurnContent(w, rt.allocator, turn) catch return false;
                    w.writeAll("\r\n\r\n") catch return false;
                }
                if (has_conclusion and !has_turns) {
                    // Fallback: when the dialog already wrapped up
                    // (turns wiped on dialogReset) but the
                    // conclusion banner survived, surface it as
                    // the overlay's content. Conclusion was built
                    // by atty so it's safe to write unsanitized.
                    if (rt.conclusion_formatted) |formatted| {
                        w.writeAll(formatted) catch return false;
                        w.writeAll("\r\n") catch return false;
                    }
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
            // Chat-mode question pick-list (#214). Renders the
            // choice list in the rows reserved above the input row.
            // Selected choice gets reverse video + `▶ ` arrow;
            // others get dim `  ` prefix. Free-text row (selected
            // when selected_idx == choice_count) inherits the
            // reverse-video block-cursor styling on the input row
            // below — already handled by the existing input-paint
            // code.
            if (rt.chat_question_active and rt.chat_question_choice_count > 0) {
                const sel = rt.chat_question_selected_idx;
                const cc: u8 = rt.chat_question_choice_count;
                const first_choice_row: u16 = rows - 1 - cc;
                var i: u8 = 0;
                while (i < cc) : (i += 1) {
                    const row_y: u16 = first_choice_row + i;
                    w.print("\x1B[{d};1H\x1B[2K", .{row_y}) catch return false;
                    const is_sel = (sel == i);
                    if (is_sel) {
                        w.writeAll("\x1B[22;38;5;141m\u{25B6}\x1B[0m ") catch return false; // ▶ mauve
                    } else {
                        w.writeAll("  ") catch return false;
                    }
                    const choice_slice = rt.question_choices_storage[i][0..rt.question_choices_lens[i]];
                    if (is_sel) w.writeAll("\x1B[1m") catch return false; // bold selected
                    var num_buf: [8]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&num_buf, "{d}. ", .{i + 1}) catch unreachable;
                    w.writeAll("\x1B[22;1;38;5;14m") catch return false;
                    w.writeAll(num_str) catch return false;
                    w.writeAll("\x1B[0m") catch return false;
                    if (is_sel) w.writeAll("\x1B[1m") catch return false;
                    writeSanitized(w, choice_slice) catch return false;
                    if (is_sel) w.writeAll("\x1B[0m") catch return false;
                }
            }

            w.print("\x1B[{d};1H\x1B[2K", .{rows - 1}) catch return false;
            // Free-text row marker when it's the selected option in
            // the question pick-list — mauve `▶` instead of cyan `❯`.
            const free_text_selected = rt.chat_question_active and
                rt.chat_question_selected_idx == rt.chat_question_choice_count;
            if (free_text_selected) {
                w.writeAll("\x1B[22;1;38;5;141m\u{25B6}\x1B[0m ") catch return false;
            } else {
                w.writeAll("\x1B[22;1;38;5;14m\u{276F}\x1B[0m ") catch return false;
            }
            // Center the cursor in a 512-byte window so long
            // prompts still show what's under the cursor instead
            // of dragging the tail off-screen.
            {
                const cur = rt.chat_input_cursor;
                const len = rt.chat_input_len;
                const visible_max: usize = 512;
                var win_start: usize = 0;
                var win_end: usize = len;
                if (len > visible_max) {
                    const half = visible_max / 2;
                    win_start = if (cur > half) cur - half else 0;
                    win_end = if (win_start + visible_max < len) win_start + visible_max else len;
                    // Cursor near the tail: win_end got clipped to
                    // len, so shift win_start back to fill the full
                    // 512-byte window. Without this, end-of-buffer
                    // cursors only see ~256 bytes of context.
                    if (win_end - win_start < visible_max and win_end >= visible_max) {
                        win_start = win_end - visible_max;
                    }
                }
                if (cur > win_start) {
                    writeSanitized(w, rt.chat_input_buf[win_start..cur]) catch return false;
                }
                if (cur < len) {
                    w.writeAll("\x1B[7m") catch return false;
                    writeSanitized(w, rt.chat_input_buf[cur .. cur + 1]) catch return false;
                    w.writeAll("\x1B[0m") catch return false;
                    if (cur + 1 < win_end) {
                        writeSanitized(w, rt.chat_input_buf[cur + 1 .. win_end]) catch return false;
                    }
                } else {
                    w.writeAll("\x1B[7m \x1B[0m") catch return false;
                }
            }

            w.print("\x1B[{d};1H\x1B[2K", .{rows}) catch return false;
            // The footer sits OUTSIDE the DECSTBM scroll region, so
            // anchoring the "↑ N below" indicator here keeps it
            // visible regardless of how far the scrollback walks.
            if (overlay_offset > 0) {
                var sb: [48]u8 = undefined;
                const ind = std.fmt.bufPrint(&sb, "\x1B[2m[\u{2191} {d} below]\x1B[0m ", .{overlay_offset}) catch "";
                w.writeAll(ind) catch return false;
            }
            w.writeAll("\x1B[2m[Alt+T auto \u{00B7} Alt+M model \u{00B7} Alt+Shift+C close \u{00B7} Enter send \u{00B7} Shift\u{2191}\u{2193}/PgUp/PgDn]\x1B[0m") catch return false;
            // Transfer ownership of the formatted buffer to the
            // Runtime so the provideTermBytes consumer gets a
            // stable slice that survives until the next paint.
            rt.chat_overlay_buf = aw.toOwnedSlice() catch {
                aw.deinit();
                return false;
            };
            return true;
        }

        /// Paint the recall picker — an alt-screen overlay listing
        /// `rt.chat_recall_items` (newest first). One row per
        /// dialog: timestamp + 6-hex suffix. The currently
        /// highlighted row (`rt.chat_recall_selected_idx`) gets
        /// reverse-video styling. Footer hints at the navigation
        /// keys (↑↓ select, Enter load, Esc cancel).
        ///
        /// Same alt-screen scaffold as `paintChatOverlay`: emit
        /// `\x1B[?1049h` on open + `\x1B[?1049l` on close, with the
        /// content payload between them. Heap-allocated buffer
        /// transferred to `rt.chat_recall_buf` so
        /// `provideTermBytes` can hand it off to the consumer
        /// without a copy.
        fn paintChatRecall(rt: *Runtime, _: *m.Context) bool {
            if (rt.chat_recall_buf) |old| {
                rt.allocator.free(old);
                rt.chat_recall_buf = null;
            }
            var aw = std.Io.Writer.Allocating.initCapacity(rt.allocator, 4 * 1024) catch return false;
            const w = &aw.writer;

            if (!rt.chat_recall_open) {
                // Close: leave alt-screen, restore cursor.
                w.writeAll("\x1B[r\x1B[?25h\x1B[?1049l") catch {
                    aw.deinit();
                    return false;
                };
                rt.chat_recall_buf = aw.toOwnedSlice() catch {
                    aw.deinit();
                    return false;
                };
                return true;
            }

            // Open: enter alt-screen, hide cursor, clear, paint.
            w.writeAll("\x1B[?1049h\x1B[?25l\x1B[H\x1B[2J") catch {
                aw.deinit();
                return false;
            };
            // Header — uses the same chat mauve (38;5;141) the
            // overlay + statusbar AI hint use so the visual
            // vocabulary stays consistent across the LLM surfaces.
            w.writeAll("\x1B[22;1;38;5;141m  Recall a dialog\x1B[0m\r\n") catch {
                aw.deinit();
                return false;
            };
            w.writeAll("\x1B[2m  \u{2191}\u{2193} select \u{00B7} Enter load \u{00B7} Esc cancel\x1B[0m\r\n\r\n") catch {
                aw.deinit();
                return false;
            };
            // Items. Format the timestamp portion of the basename
            // ("YYYYMMDDTHHMMSS-XXXXXX") as a human-friendly
            // "YYYY-MM-DD HH:MM:SS" string + the 6-hex suffix.
            const items = rt.chat_recall_items;
            if (items.len == 0) {
                w.writeAll("  \x1B[2m(no past dialogs to recall)\x1B[0m\r\n") catch {
                    aw.deinit();
                    return false;
                };
            } else {
                for (items, 0..) |m_meta, idx| {
                    const is_selected = idx == rt.chat_recall_selected_idx;
                    const sel_open: []const u8 = if (is_selected) "\x1B[7m" else "";
                    const sel_close: []const u8 = if (is_selected) "\x1B[27m" else "";
                    // Defensive: name should match the shape
                    // listDialogs filters for, but bail gracefully
                    // if it doesn't.
                    if (m_meta.name.len < 22) {
                        w.print("  {s}  {s}{s}\r\n", .{ sel_open, m_meta.name, sel_close }) catch {
                            aw.deinit();
                            return false;
                        };
                        continue;
                    }
                    const n = m_meta.name;
                    w.print(
                        "  {s}  {s}-{s}-{s} {s}:{s}:{s}  \x1B[2m{s}\x1B[0m{s}\r\n",
                        .{
                            sel_open,
                            n[0..4],
                            n[4..6],
                            n[6..8],
                            n[9..11],
                            n[11..13],
                            n[13..15],
                            n[16..22],
                            sel_close,
                        },
                    ) catch {
                        aw.deinit();
                        return false;
                    };
                }
            }

            rt.chat_recall_buf = aw.toOwnedSlice() catch {
                aw.deinit();
                return false;
            };
            return true;
        }

        /// Overlay-mode structured turn rendering. The overlay has
        /// the full screen, so assistant_exec turns get spread across
        /// multiple rows: description on row 1, command on row 2
        /// (cyan, indented `      $ ` to align with the prefix
        /// width above), question prompts in italic with
        /// optional choice list, done banners with a check glyph.
        /// User + observation turns stay flat — they're free prose.
        /// Parse failures fall back to writing the raw envelope
        /// through `writeSanitized` (so embedded ESC bytes can't
        /// hijack the paint and newlines collapse to spaces),
        /// capped at 1024 bytes with a dim `[…truncated]` marker.
        /// The point is the user sees SOMETHING the model emitted
        /// rather than a blank turn — even if it's not pretty.
        fn renderOverlayTurnContent(w: *std.Io.Writer, allocator: std.mem.Allocator, turn: dialog.Turn) !void {
            // Bound the per-field render so a 4096-byte command
            // doesn't wrap into 50+ rows and push the input row off
            // the alt-screen. Capped at 480 visible cols (~6 wraps
            // on an 80-col terminal); longer content gets a dim
            // ellipsis marker so the user can open the full
            // command in their shell if they want to see it all.
            const overlay_field_cap: usize = 480;
            const c = turn.content;
            const looks_like_envelope = turn.kind == .assistant_exec and
                c.len > 2 and
                c[0] == '{' and
                std.mem.indexOf(u8, c, "\"action\"") != null;
            // Raw-fallback render: cap by VISIBLE columns, not bytes,
            // so a multi-byte glyph (`•` U+2022, emoji, CJK) never gets
            // sliced mid-sequence into an invalid prefix the terminal
            // renders as `�`. 1024 cols is generous for "we couldn't
            // parse the envelope, surface raw bytes" — content of
            // pathological size hits the buffer/parse path first.
            // Note: `truncateToCols` returns a byte slice that can be
            // longer than 1024 bytes when the content carries many
            // zero-width chars (combining marks, ZWJ); that's the
            // intent — we cap by what the user SEES.
            if (!looks_like_envelope) {
                const slice = pw.truncateToCols(c, 1024);
                try writeSanitized(w, slice);
                if (slice.len < c.len) try w.writeAll(" \x1B[2m[\u{2026}truncated]\x1B[0m");
                return;
            }
            // Heap-arena off the runtime allocator so the stack
            // frame stays small regardless of `cfg.max_response_bytes`
            // (the `Response` struct alone is `2 * max_response_bytes`
            // + change). One arena per call, deinit on return.
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const R = dialog.Response(cfg.max_response_bytes);
            const parsed = arena.allocator().create(R) catch {
                const slice = pw.truncateToCols(c, 1024);
                try writeSanitized(w, slice);
                if (slice.len < c.len) try w.writeAll(" \x1B[2m[\u{2026}truncated]\x1B[0m");
                return;
            };
            parsed.* = .{};
            dialog.parseResponse(R, arena.allocator(), c, parsed) catch {
                const slice = pw.truncateToCols(c, 1024);
                try writeSanitized(w, slice);
                if (slice.len < c.len) try w.writeAll(" \x1B[2m[\u{2026}truncated]\x1B[0m");
                return;
            };

            switch (parsed.action) {
                .exec => {
                    const desc = parsed.description();
                    const cmd = parsed.command();
                    if (desc.len > 0) {
                        const dslice = pw.truncateToCols(desc, overlay_field_cap);
                        try writeSanitized(w, dslice);
                        if (dslice.len < desc.len) try w.writeAll(" \x1B[2m[\u{2026}]\x1B[0m");
                    }
                    // Always break to a new row before the command —
                    // otherwise an empty description would land the
                    // `$ <cmd>` on the same row as the `atty:` prefix,
                    // breaking the two-row layout invariant.
                    try w.writeAll("\r\n");
                    try w.writeAll("\x1B[2m      $ \x1B[0m\x1B[22;1;38;5;14m");
                    const cslice = pw.truncateToCols(cmd, overlay_field_cap);
                    try writeSanitized(w, cslice);
                    try w.writeAll("\x1B[0m");
                    if (cslice.len < cmd.len) try w.writeAll(" \x1B[2m[\u{2026}]\x1B[0m");
                },
                .question => {
                    const q = parsed.question();
                    const qslice = pw.truncateToCols(q, overlay_field_cap);
                    try w.writeAll("\x1B[3m");
                    try writeSanitized(w, qslice);
                    try w.writeAll("\x1B[0m");
                    if (qslice.len < q.len) try w.writeAll(" \x1B[2m[\u{2026}]\x1B[0m");
                    if (parsed.choices_count > 0) {
                        var i: usize = 0;
                        while (i < parsed.choices_count) : (i += 1) {
                            try w.writeAll("\r\n");
                            var num: [16]u8 = undefined;
                            const np = std.fmt.bufPrint(&num, "\x1B[2m   {d}.\x1B[0m ", .{i + 1}) catch unreachable;
                            try w.writeAll(np);
                            const choice = parsed.choice(i);
                            const cslice2 = pw.truncateToCols(choice, overlay_field_cap);
                            try writeSanitized(w, cslice2);
                            if (cslice2.len < choice.len) try w.writeAll(" \x1B[2m[\u{2026}]\x1B[0m");
                        }
                    }
                },
                .done => {
                    // Reason is free-form prose, often multi-paragraph
                    // (the LLM's actual answer to the user's question).
                    // Unlike `exec.command` or `question.text` where a
                    // tight col cap defends against runaway sizes, the
                    // done reason WANTS to wrap across many rows — the
                    // overlay has the full DECSTBM region to scroll
                    // within. Render unsanitized-but-write-sanitized so
                    // the terminal handles wrap naturally. Caps that
                    // were copy-pasted from the exec branch were
                    // cutting 600-word LLM responses at ~480 chars
                    // with a `[…]` marker — exactly what the user
                    // can't tolerate.
                    const r = parsed.reason();
                    try w.writeAll("\x1B[22;38;5;141m\u{2713}\x1B[0m ");
                    try writeSanitized(w, r);
                },
            }
        }

        /// Returns rows used (>= 1) so the caller can advance its
        /// row counter — wrap means raw prose turns can claim
        /// multiple rows, and the scrollback loop's anchor math
        /// depends on knowing exactly how many. Envelopes stay
        /// single-row: their `desc → cmd` shape is already compact,
        /// and wrapping would split structured fields across rows
        /// for no readability win. `max_rows` exists because one
        /// runaway reply would otherwise consume the whole panel;
        /// overflow surfaces in the alt-screen overlay
        /// (Alt+Shift+C) which has the full DECSTBM region.
        fn renderTurnContent(w: *std.Io.Writer, turn: dialog.Turn, max_visible: usize, max_rows: usize) !usize {
            return renderTurnContentWithSkip(w, turn, max_visible, 0, max_rows);
        }

        /// Render a turn skipping the first `skip_rows` of its
        /// produced content, emitting up to `max_rows` after.
        /// Used by the per-row scrollback path to slice through a
        /// tall turn that doesn't fit the panel in one shot.
        ///
        /// `skip_rows` semantics differ by envelope shape — both
        /// are correct for their content, but mixing them in one
        /// caller without understanding the split has bitten us:
        ///
        ///   - `exec` / `question` are single-row envelopes. The
        ///     skip is a binary gate: `skip_rows >= 1` → return 0
        ///     ("this turn was fully scrolled past, don't advance
        ///     the panel row counter"). Their `desc → cmd` shape
        ///     is intentionally compact so wrapping wouldn't help.
        ///   - `done` envelopes can be tall (the reason text wraps
        ///     across many rows). `skip_rows` is row-granular here:
        ///     the `✓ ` prefix lives on the logical first row, so
        ///     `skip_rows >= 1` drops the prefix AND the first
        ///     reason row; subsequent rows render via
        ///     `md_render.renderWithSkip` with the residual skip.
        ///   - Non-envelope `assistant_*` content delegates to
        ///     `renderWrappedRawWithSkip`, which is row-granular
        ///     in the same way as the `done` arm.
        fn renderTurnContentWithSkip(w: *std.Io.Writer, turn: dialog.Turn, max_visible: usize, skip_rows: usize, max_rows: usize) !usize {
            const c = turn.content;
            const looks_like_envelope = turn.kind == .assistant_exec and
                c.len > 2 and
                c[0] == '{' and
                std.mem.indexOf(u8, c, "\"action\"") != null;
            if (!looks_like_envelope) {
                return try renderWrappedRawWithSkip(w, c, max_visible, skip_rows, max_rows);
            }
            const R = dialog.Response(cfg.max_response_bytes);
            var parsed: R = .{};
            // FixedBufferAllocator on a stack buffer avoids the
            // mmap/munmap per paint that std.heap.page_allocator
            // pays — for a tall scrollback this fires hundreds of
            // times per frame. Size the buffer comptime from
            // `cfg.max_response_bytes`: the JSON parser uses
            // `.alloc_always` so every parsed string is copied
            // out of the input, roughly doubling the byte budget;
            // 2× plus 4 KiB of AST overhead covers the Parsed
            // struct + per-choice slice nodes for envelopes at
            // the configured max size without falling back to
            // the raw-render path under valid input.
            var parse_buf: [cfg.max_response_bytes * 2 + 4096]u8 = undefined;
            var parse_fba = std.heap.FixedBufferAllocator.init(&parse_buf);
            dialog.parseResponse(R, parse_fba.allocator(), c, &parsed) catch {
                return try renderWrappedRawWithSkip(w, c, max_visible, skip_rows, max_rows);
            };
            switch (parsed.action) {
                .exec => {
                    if (skip_rows >= 1 or max_rows == 0) return 0;
                    const cmd = parsed.command();
                    const desc = parsed.description();
                    if (desc.len > 0) {
                        try writeSanitized(w, pw.truncateToCols(desc, max_visible / 2));
                        try w.writeAll(" \x1B[2m\u{2192}\x1B[0m ");
                    }
                    try w.writeAll("\x1B[22;38;5;14m");
                    const cmd_room: usize = if (max_visible > 20) max_visible - 20 else max_visible;
                    const cslice = pw.truncateToCols(cmd, cmd_room);
                    try writeSanitized(w, cslice);
                    try w.writeAll("\x1B[0m");
                    if (cslice.len < cmd.len) try w.writeAll(" \x1B[2m[\u{2026}]\x1B[0m");
                },
                .question => {
                    if (skip_rows >= 1 or max_rows == 0) return 0;
                    const q = parsed.question();
                    const slice = pw.truncateToCols(q, max_visible);
                    try w.writeAll("\x1B[3m");
                    try writeSanitized(w, slice);
                    try w.writeAll("\x1B[0m");
                    if (slice.len < q.len) try w.writeAll(" \x1B[2m[\u{2026}]\x1B[0m");
                },
                .done => {
                    if (max_rows == 0) return 0;
                    // Emit the ✓ prefix only when row 1 is in the
                    // visible window (skip_rows == 0). For deeper
                    // scrolls, the prefix is "above" the cut and
                    // md_render handles the continuation rows.
                    if (skip_rows == 0) {
                        try w.writeAll("\x1B[22;38;5;141m\u{2713}\x1B[0m ");
                    }
                    const r = parsed.reason();
                    const wrap_cols: usize = if (max_visible > 2) max_visible - 2 else max_visible;
                    return md_render.renderWithSkip(w, r, wrap_cols, skip_rows, max_rows, &writeSanitized);
                },
            }
            return 1;
        }

        /// Estimate how many panel rows a turn would consume if
        /// rendered now. Mirrors `renderTurnContent`'s envelope-vs-
        /// raw decision and the same wrap iterator so the back-walk
        /// in `paintInlineChat` picks `start_turn` accurately
        /// (newest-turn-anchored).
        ///
        /// Envelope rows:
        ///   - `exec` / `question` always claim 1 row (compact
        ///     single-line summary in the render path).
        ///   - `done` claims multiple rows — its free-prose reason
        ///     renders via md_render which hard-breaks on `\n`.
        ///     Estimator walks the wrap iter over the raw envelope
        ///     bytes + adds the count of `\n` JSON escapes (the
        ///     wrap iter misses these because the JSON encoding
        ///     puts them as 2-char `\n` literals). Over-estimates
        ///     slightly but stays safe vs the actual render —
        ///     under-counting would clip the newest turn's tail
        ///     under back-walk pressure.
        ///
        /// Raw turns walk the wrap iterator counting chunks up to
        /// `max_rows`. Cheap — no allocations.
        /// Whitespace-tolerant check for an envelope whose action
        /// value is `"done"`. The full JSON parser at the render
        /// path handles this fine; `countTurnRows` only needs a
        /// cheap shape probe for the back-walk row-count estimate.
        ///
        /// Matches: `"action":"done"`, `"action": "done"`,
        /// `"action" : "done"` (any ASCII whitespace around the
        /// colon). Skips matches whose opening `"` is backslash-
        /// escaped so an LLM emitting `\"action\":` literally
        /// inside a reason string can't shadow the real top-level
        /// `"action"` key further on in the envelope.
        fn envelopeActionIsDone(c: []const u8) bool {
            const key_lit = "\"action\"";
            var search_start: usize = 0;
            while (search_start < c.len) {
                const rel = std.mem.indexOf(u8, c[search_start..], key_lit) orelse return false;
                const key_pos = search_start + rel;
                // Skip a `"action"` whose opening quote is escaped
                // (preceded by a backslash that isn't itself
                // escaped). Common shape: `"reason":"... \"action\":
                // \"done\" ..."` — the first `"action"` is inside
                // a JSON string value, not the top-level key.
                if (key_pos > 0 and c[key_pos - 1] == '\\') {
                    // Could be `\"` (escape) or `\\"` (literal
                    // backslash + opening quote). Walk back to
                    // count consecutive backslashes; an odd count
                    // means the quote is escaped.
                    var bs: usize = 0;
                    var k = key_pos;
                    while (k > 0 and c[k - 1] == '\\') : (k -= 1) bs += 1;
                    if (bs % 2 == 1) {
                        search_start = key_pos + 1;
                        continue;
                    }
                }
                var i = key_pos + key_lit.len;
                while (i < c.len and (c[i] == ' ' or c[i] == '\t' or c[i] == '\n' or c[i] == '\r')) i += 1;
                if (i >= c.len or c[i] != ':') {
                    search_start = key_pos + 1;
                    continue;
                }
                i += 1;
                while (i < c.len and (c[i] == ' ' or c[i] == '\t' or c[i] == '\n' or c[i] == '\r')) i += 1;
                const done_lit = "\"done\"";
                if (i + done_lit.len > c.len) return false;
                return std.mem.eql(u8, c[i..(i + done_lit.len)], done_lit);
            }
            return false;
        }

        fn countTurnRows(turn: dialog.Turn, cols: usize, max_rows: usize) usize {
            const c = turn.content;
            const looks_like_envelope = turn.kind == .assistant_exec and
                c.len > 2 and
                c[0] == '{' and
                std.mem.indexOf(u8, c, "\"action\"") != null;
            if (looks_like_envelope) {
                if (envelopeActionIsDone(c)) {
                    // Parse the envelope so we count the rendered
                    // reason via the SAME md_render row math the
                    // paint path uses. The previous wrap-iter +
                    // escapes_n heuristic was a safe upper bound for
                    // the back-walk anchor but over-counted for the
                    // per-row windowing (#213's offset clamp).
                    const R = dialog.Response(cfg.max_response_bytes);
                    var parsed: R = .{};
                    // See renderTurnContentWithSkip for the FBA
                    // sizing rationale — same paint-frame cost +
                    // .alloc_always doubling concern.
                    var parse_buf: [cfg.max_response_bytes * 2 + 4096]u8 = undefined;
                    var parse_fba = std.heap.FixedBufferAllocator.init(&parse_buf);
                    dialog.parseResponse(R, parse_fba.allocator(), c, &parsed) catch {
                        // Parse failure falls through to raw render in
                        // renderTurnContent — count that path too.
                        const raw = md_render.countRows(c, cols);
                        return @min(raw, max_rows);
                    };
                    if (parsed.action == .done) {
                        const reason = parsed.reason();
                        const wrap_cols: usize = if (cols > 2) cols - 2 else cols;
                        return @min(md_render.countRows(reason, wrap_cols), max_rows);
                    }
                    // Parsed but not actually done (rare — envelope-
                    // action mismatch): fall through.
                }
                // Envelope-shaped exec/question/malformed: real
                // envelopes emit 1 compact row; malformed cases
                // fall through to renderWrappedRaw and span N.
                // md_render.countRows mirrors the wrap+newline
                // path the renderer uses; safe upper bound for
                // both valid (1) and malformed (N) cases.
            }
            if (c.len == 0) return 1;
            return @min(md_render.countRows(c, cols), max_rows);
        }

        /// Render a raw (non-envelope) turn via the markdown-aware
        /// renderer: hard breaks at `\n`, SGR styling for
        /// `**bold**` and `` `code` `` spans, per-line wrap to
        /// `cols` with the overflow `[…]` marker at `max_rows`.
        /// Delegates to `md_render.render` so the per-row state
        /// machine + SGR span handling lives in one place.
        fn renderWrappedRaw(w: *std.Io.Writer, content: []const u8, cols: usize, max_rows: usize) anyerror!usize {
            return md_render.render(w, content, cols, max_rows, &writeSanitized);
        }

        fn renderWrappedRawWithSkip(w: *std.Io.Writer, content: []const u8, cols: usize, skip_rows: usize, max_rows: usize) anyerror!usize {
            return md_render.renderWithSkip(w, content, cols, skip_rows, max_rows, &writeSanitized);
        }

        /// Compute the (row, col) position the real terminal cursor
        /// should sit at after every paintInlineChat call. Pulls
        /// from the snapshot taken at open time
        /// (`chat_open_cursor_row` + `chat_open_cursor_col`), falls
        /// back to (shell_bottom, 1) when the snapshot is unknown
        /// OR the row was clamped past the shell area (defensive
        /// against cursor_tracker drift / SIGWINCH races).
        ///
        /// Row anchors to `total_rows - base_reserve` (a row that's
        /// stable across panel open/close) — DO NOT switch to a
        /// live-reserve denominator, that would move the fallback
        /// between open and close and break the close-paint's
        /// ability to land on the same row the open paint used.
        ///
        /// Col uses the snapshot directly (with 1 fallback): the
        /// open paint captures `prompt_end_col` from the OSC 133
        /// `;B` anchor, so subsequent paints CUP back to where the
        /// user's typing would resume — not col 1 (which would
        /// place the cursor at the start of the prompt row, on top
        /// of the PS1 chrome).
        /// Render the chat input buffer across `input_top_row ..
        /// input_row` (inclusive). One row per `\n`-separated line.
        /// First row gets the `❯` prompt; continuation rows get a
        /// dim `…` chrome glyph so the multi-line shape is visible.
        /// Cursor glyph (reverse-video block when focused, dim cell
        /// when parked) lands on whichever line contains the cursor
        /// byte. Lines that exceed `input_row` get clipped — the
        /// caller's `input_lines` math already accounts for the cap.
        fn paintInputBlock(w: *std.Io.Writer, rt: *Runtime, input_top_row: u16, input_row: u16) !void {
            // Chat-mode question pick-list (#308): when active AND
            // the free-text row is the selected option, render the
            // prompt glyph as mauve ▶ instead of cyan ❯ so the
            // pick-list selection state is visible on the input
            // row too — matches the overlay's behaviour at
            // paint.zig:248-254.
            const free_text_selected = rt.chat_focus_in_panel and
                rt.chat_question_active and
                rt.chat_question_choice_count > 0 and
                rt.chat_question_selected_idx == rt.chat_question_choice_count;
            const prompt_style: []const u8 = if (free_text_selected)
                "\x1B[22;1;38;5;141m"
            else if (rt.chat_focus_in_panel)
                "\x1B[22;1;38;5;14m"
            else
                "\x1B[2;38;5;14m";
            const prompt_glyph: []const u8 = if (free_text_selected) "\u{25B6}" else "\u{276F}";
            const buf = rt.chat_inline_input_buf[0..rt.chat_inline_input_len];
            const cur = rt.chat_inline_input_cursor;
            const focus = rt.chat_focus_in_panel;

            // Walk buffer, splitting at `\n`. Emit each segment on
            // its own row.
            var seg_start: usize = 0;
            var line_idx: u16 = 0;
            var current_row: u16 = input_top_row;
            var pos: usize = 0;
            while (pos <= buf.len) : (pos += 1) {
                const at_end = pos == buf.len;
                const is_nl = !at_end and buf[pos] == '\n';
                if (!at_end and !is_nl) continue;

                const seg = buf[seg_start..pos];
                const seg_cur_local: ?usize = if (cur >= seg_start and cur <= pos) cur - seg_start else null;

                try w.print("\x1B[{d};1H\x1B[2K", .{current_row});
                if (line_idx == 0) {
                    try w.writeAll(prompt_style);
                    try w.writeAll(prompt_glyph);
                    try w.writeAll("\x1B[0m ");
                } else {
                    try w.writeAll("\x1B[2m\u{2026}\x1B[0m ");
                }

                try paintInputLine(w, seg, seg_cur_local, focus);

                if (is_nl) {
                    line_idx += 1;
                    current_row += 1;
                    if (current_row > input_row) break;
                    seg_start = pos + 1;
                } else {
                    break;
                }
            }
        }

        /// Render a single line of input — text up to the cursor,
        /// cursor glyph (or EOL block when `cur_local` lands at the
        /// end), and the tail. Applies a 512-byte window around the
        /// cursor so a long pasted prompt still surfaces context on
        /// either side instead of dragging the tail off-screen.
        fn paintInputLine(w: *std.Io.Writer, line: []const u8, cur_local: ?usize, focus: bool) !void {
            const len = line.len;
            const cur_pos: ?usize = if (cur_local) |cl| (if (cl <= len) cl else null) else null;

            var win_start: usize = 0;
            var win_end: usize = len;
            if (len > 512) {
                const visible_max: usize = 512;
                const cur_for_window = cur_pos orelse len;
                const half = visible_max / 2;
                win_start = if (cur_for_window > half) cur_for_window - half else 0;
                win_end = if (win_start + visible_max < len) win_start + visible_max else len;
                if (win_end - win_start < visible_max and win_end >= visible_max) {
                    win_start = win_end - visible_max;
                }
                // Snap both window edges to UTF-8 codepoint
                // boundaries — a continuation byte (0x80..0xBF) at
                // either edge would let `writeSanitized` slice a
                // multi-byte sequence and the terminal would render
                // `�`. Walk forward past any continuation byte.
                while (win_start < len and (line[win_start] & 0xC0) == 0x80) {
                    win_start += 1;
                }
                while (win_end < len and (line[win_end] & 0xC0) == 0x80) {
                    win_end += 1;
                }
            }

            const dim = !focus;
            if (cur_pos) |c_abs| {
                if (c_abs >= win_start) {
                    // The "cell under the cursor" is the FULL UTF-8
                    // sequence starting at c_abs, not just one byte
                    // — slicing `line[c_abs..c_abs+1]` would emit a
                    // half-codepoint when the user pasted multi-
                    // byte chars (e.g. `•`) and rendered as `�`.
                    // Cursor advancement is still byte-wise (the
                    // edit ops in applyChatEdit work in bytes), so
                    // a cursor parked mid-codepoint shows the bytes
                    // starting at that offset and the terminal
                    // handles the invalid prefix — uncommon path.
                    const cell_advance: usize = blk: {
                        if (c_abs >= len) break :blk 0;
                        var iter = pw.utf8Iter(line[c_abs..]);
                        if (iter.next()) |c| {
                            const end = c_abs + c.byte_len;
                            if (end <= len) break :blk c.byte_len;
                        }
                        break :blk 1;
                    };
                    if (dim) try w.writeAll("\x1B[2m");
                    if (c_abs > win_start) try writeSanitized(w, line[win_start..c_abs]);
                    if (dim) try w.writeAll("\x1B[0m");
                    if (focus) {
                        if (c_abs < len) {
                            try w.writeAll("\x1B[7m");
                            try writeSanitized(w, line[c_abs .. c_abs + cell_advance]);
                            try w.writeAll("\x1B[0m");
                        } else {
                            try w.writeAll("\x1B[7m \x1B[0m");
                        }
                    } else {
                        if (c_abs < len) {
                            try w.writeAll("\x1B[2m");
                            try writeSanitized(w, line[c_abs .. c_abs + cell_advance]);
                            try w.writeAll("\x1B[0m");
                        } else {
                            try w.writeAll("\x1B[2m\u{2592}\x1B[0m");
                        }
                    }
                    if (c_abs + cell_advance < win_end) {
                        if (dim) try w.writeAll("\x1B[2m");
                        try writeSanitized(w, line[c_abs + cell_advance .. win_end]);
                        if (dim) try w.writeAll("\x1B[0m");
                    }
                } else {
                    // Cursor is BEFORE the window — rare with the
                    // window math above, but defensive: just render
                    // the visible slice without a cursor glyph.
                    if (dim) try w.writeAll("\x1B[2m");
                    try writeSanitized(w, line[win_start..win_end]);
                    if (dim) try w.writeAll("\x1B[0m");
                }
            } else {
                if (dim) try w.writeAll("\x1B[2m");
                try writeSanitized(w, line[win_start..win_end]);
                if (dim) try w.writeAll("\x1B[0m");
            }
        }

        fn inlineRestorePos(rt: *Runtime, total_rows: u16, base_reserve: u16) struct { row: u16, col: u16 } {
            const shell_bottom: u16 = if (total_rows > base_reserve) total_rows - base_reserve else 1;
            const row: u16 = blk: {
                if (rt.chat_open_cursor_row == 0) break :blk shell_bottom;
                if (rt.chat_open_cursor_row > shell_bottom) break :blk shell_bottom;
                break :blk rt.chat_open_cursor_row;
            };
            const col: u16 = if (rt.chat_open_cursor_col == 0) 1 else rt.chat_open_cursor_col;
            return .{ .row = row, .col = col };
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
        fn paintInlineChat(rt: *Runtime, ctx: *m.Context) bool {
            var w: std.Io.Writer = .fixed(&rt.chat_inline_buf);

            if (!rt.chat_inline_open) {
                // CUP via inlineRestorePos — DECRC is clobbered by
                // applyReserveRows upstream.
                const ct_rows: u16 = ctx.terminal_rows orelse 24;
                const ct_base: u16 = ctx.statusbar_base_reserve orelse 3;
                const pos = inlineRestorePos(rt, ct_rows, ct_base);
                w.print("\x1B[?25h\x1B[{d};{d}H", .{ pos.row, pos.col }) catch return false;
                rt.chat_inline_buf_len = w.end;
                return true;
            }

            // Lazy snapshot of the shell prompt position — the toggle
            // action handler set both to 0 as a defer marker because
            // the proxy's reservation-grow path runs AFTER the action
            // but BEFORE this paint, and may have scrolled the prompt
            // up to make room. By paint time `ctx.cursor_row/col`
            // already reflect the post-scroll position (proxy updates
            // them right after emitting the scroll-up sequence), so
            // we capture HERE to land the restore CUP on the prompt's
            // new row instead of stale pre-scroll geometry.
            if (rt.chat_open_cursor_row == 0) {
                rt.chat_open_cursor_row = ctx.cursor_row orelse 0;
                rt.chat_open_cursor_col = ctx.cursor_col orelse 0;
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
            // Effective panel height — `chat_inline_rows_override`
            // (set by Ctrl+Alt+Up/Down on the live session) wins
            // over the comptime `cfg.inline_chat_rows` default.
            // `ctx.statusbar_reserve` reflects the proxy's clamped
            // reservation; it tracks the override on the next tick
            // after the grow/shrink action via the dispatcher's
            // applyReserveRows path.
            const effective_inline_rows: u16 = rt.chat_inline_rows_override orelse cfg.inline_chat_rows;
            const live_reserve: u16 = ctx.statusbar_reserve orelse
                (base_reserve + effective_inline_rows + cfg.inline_chat_top_gap);
            // Panel needs at least 3 rows after the top gap is taken
            // out: divider + ≥1 scrollback + input. Below that, the
            // `scrollback_rows = panel_rows - 2` calc later in this
            // function underflows u16 and the per-row blank loop
            // writes ~65k CUPs into a tiny buffer (paint-buf
            // overflow, panel rolls back, user sees "terminal too
            // small"). Guarded here on the LIVE values (post proxy
            // clamp + post top_gap) rather than the static cfg so a
            // proxy-clamped reservation still bails out cleanly.
            if (live_reserve <= base_reserve or total_rows <= live_reserve or
                live_reserve - base_reserve < cfg.inline_chat_top_gap + 3)
            {
                // Terminal too small to fit any panel rows on top of
                // the base reservation, or the proxy clamped us into
                // a no-op. Roll the open flag back so the user isn't
                // trapped — proxy will shrink the reservation next
                // tick.
                w.writeAll("\x1B[?25h\x1B[u") catch return false;
                rt.chat_inline_buf_len = w.end;
                return false;
            }
            // Top gap stays blank — visual breathing room between
            // the shell prompt and the panel divider. The early-out
            // above guarantees `live_reserve - base_reserve >=
            // inline_chat_top_gap + 3`, so subtraction is safe.
            const top_gap: u16 = cfg.inline_chat_top_gap;
            const panel_rows: u16 = live_reserve - base_reserve - top_gap;
            const top_row: u16 = total_rows - live_reserve + 1 + top_gap;
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
            // Incognito swaps the ✨ sparkle for 🕶 glasses
            // (`\u{1F576}`) so the user sees at a glance that
            // typing won't be recorded locally. NOTE: incognito
            // gates LOCAL recording (atuin / shell history); chat
            // prompts STILL go to the remote LLM API.
            //
            // The divider also surfaces the active provider so
            // the user knows which model is responding (#173 #6).
            // Resolved via `resolveProviderForMode(.chat, …)` so
            // a per-mode `providers[]` config that ships a chat-
            // only entry reads correctly even when
            // `current_provider_idx` points at a single-only
            // entry that would otherwise show wrong.
            const cols_usize: usize = total_cols;
            w.print("\x1B[{d};1H\x1B[2K", .{top_row}) catch return false;
            // Provider resolution uses the LIVE dispatch mode so the
            // chrome label matches the provider that will actually
            // serve the next request. Chat surfaces now dispatch as
            // `.dialog`/`.auto` (per `currentDispatchMode` in
            // hooks.zig); hardcoding `.chat` here was a relic of the
            // earlier prose-only chat mode and would mis-advertise
            // when a user's `providers[]` has a chat-only entry that
            // no longer matches the live dispatch.
            const chrome_mode: types.Mode = if (rt.auto_mode_active) .auto else .dialog;
            const resolved = types.resolveProviderForMode(chrome_mode, cfg.providers, cfg.provider, rt.current_provider_idx);
            const raw_label: []const u8 = if (resolved.name.len > 0) resolved.name else types.providerLabel(resolved.provider);
            const icon: []const u8 = if (ctx.incognito) "\u{1F576}" else "\u{2728}";
            // Mode word reflects both incognito (no recording) and
            // auto (atty auto-executes LLM commands). Both flags can
            // co-apply — surface them parenthetically so the user
            // sees the live state at a glance.
            const mode_word: []const u8 = if (ctx.incognito and rt.auto_mode_active)
                "atty chat (auto, incognito)"
            else if (rt.auto_mode_active)
                "atty chat (auto)"
            else if (ctx.incognito)
                "atty chat (incognito)"
            else
                "atty chat";
            // Clamp the label to a third of the available cols so a
            // long provider name doesn't squeeze the trailing
            // `Alt+C close · Enter send` shortcut hint off the row.
            // Trailing `…` (U+2026, 1 col) marks the cut so users
            // know the full name is longer. Both the overflow check
            // and the truncation walk codepoints so wide glyphs
            // (CJK / emoji) bill 2 cols and multi-byte sequences
            // can't get sliced mid-codepoint.
            // 32-col cap on the label keeps `label_buf` sized for
            // the worst-case all-4-byte-codepoint label (32 × 4 +
            // 3 ellipsis bytes ≤ 256). Without the inner cap, a
            // user on a very wide terminal could push label_cap
            // past `label_buf.len - 3`; the previous `@min` re-cut
            // the codepoint-aligned truncated slice mid-sequence
            // (caught by Copilot review on #175).
            var label_buf: [256]u8 = undefined;
            const label_cap: usize = @min(32, @max(8, cols_usize / 3));
            const raw_label_cols: usize = pw.measureCols(raw_label);
            const provider_label: []const u8 = if (raw_label_cols > label_cap and label_cap > 1) blk: {
                const truncated = pw.truncateToCols(raw_label, label_cap - 1);
                @memcpy(label_buf[0..truncated.len], truncated);
                @memcpy(label_buf[truncated.len .. truncated.len + 3], "\u{2026}");
                break :blk label_buf[0 .. truncated.len + 3];
            } else raw_label;
            // Format: `<icon> <mode_word> · <provider_label> ─`
            w.print("\x1B[2m\x1B[22;38;5;141m{s}\x1B[39;2m {s} \u{00B7} \x1B[22;38;5;14m{s}\x1B[39;2m \u{2500}", .{ icon, mode_word, provider_label }) catch return false;
            // Visible-col count for the trail-clearance math —
            // icon (2 wide) + space + mode_word + " · " (3 cols:
            // sp + U+00B7 + sp) + provider_label + " ─" (2).
            const label_visible: usize =
                pw.measureCols(icon) + 1 +
                pw.measureCols(mode_word) + 3 +
                pw.measureCols(provider_label) + 2;
            // Divider trailing hint — only the surface-level shortcuts
            // (close + send) live here so the header reads as chrome,
            // not a cheat-sheet. The mode + provider toggles
            // (`Alt+T auto` / `Alt+M model`) live in the statusbar
            // (`chat_open_hint` in llm.zig's `statusText`) so they're
            // always visible without competing for the divider's
            // column budget. Two sizes:
            //   full: " Alt+C close · Enter send" (25 cols)
            //   short: " Alt+C · Enter"            (14 cols)
            const hint_full = " \x1B[22;38;5;14mAlt+C\x1B[39;2m close \u{00B7} \x1B[22;38;5;14mEnter\x1B[39;2m send\x1B[0m";
            const hint_short = " \x1B[22;38;5;14mAlt+C\x1B[39;2m \u{00B7} \x1B[22;38;5;14mEnter\x1B[39;2m\x1B[0m";
            const min_dashes: usize = 4;
            const hint: []const u8 = if (cols_usize >= label_visible + 25 + min_dashes)
                hint_full
            else if (cols_usize >= label_visible + 14 + min_dashes)
                hint_short
            else
                "\x1B[0m";
            const hint_cols: usize = if (hint.ptr == hint_full.ptr)
                25
            else if (hint.ptr == hint_short.ptr)
                14
            else
                0;
            const trail_target: usize = if (cols_usize > label_visible + hint_cols + min_dashes)
                cols_usize - label_visible - hint_cols
            else
                min_dashes;
            var i: usize = 0;
            while (i < trail_target) : (i += 1) {
                w.writeAll("\u{2500}") catch return false;
            }
            w.writeAll(hint) catch return false;

            // Scrollback rows — fill from oldest visible turn to
            // most recent, each on its own row, truncated to fit
            // the available cols. Walk turns oldest→newest into a
            // row budget so the MOST RECENT lines anchor at the
            // bottom (above input) and older turns scroll off the
            // top.
            // Multi-line input (Shift+Enter inserts `\n` into the
            // buffer): grow the input area up from `input_row` by
            // one row per embedded newline, capped at half the
            // panel so scrollback isn't completely starved. Plain
            // single-line typing keeps `input_lines = 1` and the
            // layout matches the pre-multiline behaviour.
            var buf_newlines: usize = 0;
            for (rt.chat_inline_input_buf[0..rt.chat_inline_input_len]) |bb| {
                if (bb == '\n') buf_newlines += 1;
            }
            const desired_input_lines: u16 = @intCast(1 + buf_newlines);
            const input_lines_cap: u16 = if (panel_rows >= 4) @max(@as(u16, 1), panel_rows / 2) else 1;
            const input_lines: u16 = @min(desired_input_lines, input_lines_cap);
            const input_top_row: u16 = input_row - (input_lines - 1);
            // Chat-mode question pick-list (#308): reserve N rows
            // immediately above the input area for the choice list.
            // Mirrors the overlay's reservation at paint.zig:130 —
            // the inline panel didn't render the picker pre-#308,
            // so arrow-key navigation worked silently but the user
            // couldn't see selection. Cap at half the available
            // space ABOVE input so scrollback isn't fully starved
            // for tall choice lists on small terminals.
            const raw_question_rows: u16 = if (rt.chat_question_active and rt.chat_question_choice_count > 0)
                @intCast(rt.chat_question_choice_count)
            else
                0;
            const room_above_input: u16 = if (input_top_row > top_row + 1) input_top_row - top_row - 1 else 0;
            const max_question_rows: u16 = if (room_above_input >= 2) room_above_input / 2 else 0;
            const question_rows: u16 = @min(raw_question_rows, max_question_rows);
            const question_top_row: u16 = input_top_row - question_rows;
            const scrollback_rows: u16 = if (question_top_row > top_row + 1) question_top_row - top_row - 1 else 0;
            var row: u16 = top_row + 1;
            // Blank-clear every scrollback row up front so prior
            // chat content doesn't leak when the turns shrink.
            var r: u16 = row;
            while (r < question_top_row) : (r += 1) {
                w.print("\x1B[{d};1H\x1B[2K", .{r}) catch return false;
            }
            // Paint the question choice list, if active. Renders
            // bottom-up: choice 0 lands at `question_top_row`,
            // last choice immediately above `input_top_row`.
            // Selected row gets the mauve ▶ + bold; others get a
            // dim 2-space prefix to keep column alignment.
            if (question_rows > 0) {
                const sel = rt.chat_question_selected_idx;
                var qi: u8 = 0;
                while (qi < question_rows) : (qi += 1) {
                    const qrow: u16 = question_top_row + qi;
                    w.print("\x1B[{d};1H\x1B[2K", .{qrow}) catch return false;
                    const is_sel = (sel == qi);
                    if (is_sel) {
                        w.writeAll("\x1B[22;38;5;141m\u{25B6}\x1B[0m ") catch return false;
                    } else {
                        w.writeAll("  ") catch return false;
                    }
                    var num_buf: [8]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&num_buf, "{d}. ", .{qi + 1}) catch unreachable;
                    w.writeAll("\x1B[22;1;38;5;14m") catch return false;
                    w.writeAll(num_str) catch return false;
                    w.writeAll("\x1B[0m") catch return false;
                    if (is_sel) w.writeAll("\x1B[1m") catch return false;
                    const choice_slice = rt.question_choices_storage[qi][0..rt.question_choices_lens[qi]];
                    writeSanitized(&w, choice_slice) catch return false;
                    if (is_sel) w.writeAll("\x1B[0m") catch return false;
                }
            }

            // `chat_inline_view_offset` is in ROWS now (post-#213):
            // the offset counts rendered rows scrolled UP from the
            // live tail. Offset 0 = newest content at panel bottom.
            // Larger offset reveals progressively older rows
            // (possibly mid-turn — a tall LLM `done` reason becomes
            // navigable instead of only viewable end-clipped).
            row = top_row + 1;
            const max_inline_visible: usize = if (cols_usize > 12) cols_usize - 6 else 40;

            // Pre-compute per-turn row counts + total. Without a
            // pre-pass the row→turn translation needs another
            // back-walk in the wrong direction; one forward sweep
            // keeps the math straightforward. Counts use the
            // unbounded estimate (`maxInt(u16)`) so the offset
            // clamp + window slicing see the TRUE row totals.
            const big: usize = std.math.maxInt(u16);
            // Sized from cfg.history_turns_max so any future config
            // bump above the previous 256-row cap surfaces at
            // compile time instead of silent panel-truncation.
            comptime std.debug.assert(cfg.history_turns_max <= 256);
            var turn_row_buf: [cfg.history_turns_max]usize = undefined;
            var content_total_rows: usize = 0;
            for (rt.turns[0..rt.turns_len], 0..) |t, idx| {
                turn_row_buf[idx] = countTurnRows(t, max_inline_visible, big);
                content_total_rows += turn_row_buf[idx];
            }

            // Header row reserved when scrolled back. Decrement
            // scrollback budget by 1 IF offset > 0.
            //
            // Cap offset at `total_rows - 1` so the user can scroll
            // up to the very first row even when the panel budget
            // > total content (each step still navigates one row).
            // The full-content-fits clamp is enforced naturally:
            // the visible window calculation below clamps
            // visible_start_row to 0 when offset has consumed all
            // the content.
            const max_inline_offset: usize = if (content_total_rows > 1) content_total_rows - 1 else 0;
            const inline_offset: usize = @min(rt.chat_inline_view_offset, max_inline_offset);
            var scrollback_budget: u16 = scrollback_rows;
            if (inline_offset > 0 and scrollback_budget > 1) {
                var sb: [80]u8 = undefined;
                const head = std.fmt.bufPrint(&sb, "  \x1B[2m\u{2191} {d} below \u{00B7} \x1B[22;38;5;14mCtrl+End\x1B[39;2m for tail\x1B[0m", .{inline_offset}) catch "";
                w.print("\x1B[{d};1H\x1B[2K", .{row}) catch return false;
                w.writeAll(head) catch return false;
                row += 1;
                scrollback_budget -= 1;
            }

            // Visible row window in [start, end) coordinates over
            // the all-turn concatenation (cumulative_top accumulates
            // turn_row_buf entries oldest→newest).
            const visible_end_row: usize = content_total_rows - inline_offset;
            const visible_start_row: usize = if (visible_end_row > scrollback_budget) visible_end_row - scrollback_budget else 0;

            // Walk turns oldest→newest. For each, compute its row
            // span; intersect with the visible window; render
            // (possibly with skip_rows at the top + a row budget
            // at the bottom).
            var cumulative_top: usize = 0;
            for (rt.turns[0..rt.turns_len], 0..) |turn, idx| {
                const turn_rows = turn_row_buf[idx];
                const turn_top = cumulative_top;
                const turn_bot = cumulative_top + turn_rows;
                cumulative_top = turn_bot;

                if (turn_bot <= visible_start_row) continue;
                if (turn_top >= visible_end_row) break;
                if (row >= input_top_row) break;

                const skip = if (turn_top < visible_start_row) visible_start_row - turn_top else 0;
                const remaining_panel_rows: usize = @intCast(input_top_row - row);
                const window_room: usize = visible_end_row - @max(turn_top, visible_start_row);
                const budget = @min(turn_rows - skip, @min(window_room, remaining_panel_rows));
                if (budget == 0) continue;

                w.print("\x1B[{d};1H\x1B[2K", .{row}) catch return false;
                // The kind-prefix is conceptually part of row 1 of
                // the turn. Skip emitting it when row 1 isn't in
                // the window (skip > 0).
                if (skip == 0) {
                    const prefix: []const u8 = switch (turn.kind) {
                        .user => "\x1B[22;1;38;5;14mYou:\x1B[0m ",
                        .assistant_exec => "\x1B[22;38;5;141matty:\x1B[0m ",
                        .observation => "\x1B[2mOutput:\x1B[0m ",
                    };
                    w.writeAll(prefix) catch return false;
                }
                const rows_used = renderTurnContentWithSkip(&w, turn, max_inline_visible, skip, budget) catch 1;
                // 0 means countTurnRows over-counted vs md_render's
                // actual emission (the wrap-iter heuristic
                // over-estimates for some done envelopes). Rewind
                // the row cursor so the blank slot is reusable
                // instead of leaving a gap in the panel.
                if (rows_used == 0) {
                    // Already emitted the CUP+clear above; that's
                    // fine — the next loop iteration overwrites
                    // the same row via its own CUP.
                    continue;
                }
                row += @intCast(rows_used);
            }
            if (rt.turns_len == 0 and scrollback_rows > 0) {
                w.print("\x1B[{d};1H\x1B[2K", .{top_row + 1}) catch return false;
                w.writeAll("  \x1B[2m(empty \u{2014} type a prompt below \u{00B7} Enter to ask)\x1B[0m") catch return false;
            }

            // Input area — `❯ <input>█` with reverse-video block
            // cursor on the first row; continuation rows (when the
            // buffer contains `\n` from Shift+Enter) start with a
            // dim `…` chrome glyph at col 1 so the user can see
            // multiple lines and tell where the input area ends.
            // Painted last so the final CUP parks the real cursor
            // adjacent to the block-cursor glyph.
            paintInputBlock(&w, rt, input_top_row, input_row) catch return false;
            // Park the real terminal cursor on the shell row — the
            // block-cursor glyph above is purely visual. See
            // inlineRestorePos for the row + col math.
            const restore_pos_open = inlineRestorePos(rt, total_rows, base_reserve);
            w.print("\x1B[{d};{d}H", .{ restore_pos_open.row, restore_pos_open.col }) catch return false;

            rt.chat_inline_buf_len = w.end;
            // Stash the input-block geometry so the typing fast-path
            // (`paintInlineChatInputFast`) can replay
            // `paintInputBlock` without re-deriving panel rows,
            // top_gap, input_lines, etc. Cache invalidates on any
            // event that arms `chat_inline_paint_pending` (resize,
            // turn arrival, scroll, mode toggle) — those re-enter
            // this full-paint path and refresh the values.
            rt.chat_inline_paint_input_top_row = input_top_row;
            rt.chat_inline_paint_input_row = input_row;
            rt.chat_inline_paint_input_lines = input_lines;
            rt.chat_inline_paint_input_lines_cap = input_lines_cap;
            rt.chat_inline_paint_total_cols = total_cols;
            rt.chat_inline_paint_incognito = ctx.incognito;
            rt.chat_inline_paint_cache_valid = true;
            rt.chat_inline_input_dirty = false;
            return true;
        }

        /// Fast-path repaint for the common case: user typed a
        /// character (or backspace / arrow) while the chat panel
        /// is open, nothing else changed. Skips the per-turn
        /// `countTurnRows` walk and the scrollback render, emitting
        /// only the input block + cursor restore.
        ///
        /// Bails (returns false → caller falls back to full paint)
        /// when the cache is stale, the terminal cols changed
        /// (cached coords no longer describe the same viewport),
        /// the incognito flag changed (chrome would be wrong), or
        /// the CLAMPED input-line count (`min(1+newlines,
        /// input_lines_cap)`) would shift the scrollback boundary.
        /// Newlines past the cap don't trigger a bail — at that
        /// point the input area is at its ceiling and additional
        /// `\n` strokes keep geometry stable.
        fn paintInlineChatInputFast(rt: *Runtime, ctx: *m.Context) bool {
            if (!rt.chat_inline_paint_cache_valid or !rt.chat_inline_open) return false;
            const total_cols: u16 = ctx.terminal_cols orelse 80;
            if (total_cols != rt.chat_inline_paint_total_cols) return false;
            // Ctrl+Shift+I lives in the proxy and toggles
            // `ctx.incognito` without a per-module notify hook. The
            // divider chrome (icon + mode_word) depends on this
            // flag, so a mismatch means the cached chrome is stale.
            if (ctx.incognito != rt.chat_inline_paint_incognito) return false;

            // Compare the CLAMPED input-line count (not the raw
            // newline count). Once the input is already at
            // `input_lines_cap`, additional newlines don't move
            // `input_top_row` and the scrollback boundary is stable
            // — fast-path can keep firing.
            var buf_newlines: u16 = 0;
            for (rt.chat_inline_input_buf[0..rt.chat_inline_input_len]) |bb| {
                if (bb == '\n') buf_newlines += 1;
            }
            const desired_input_lines: u16 = 1 + buf_newlines;
            const live_input_lines: u16 = @min(desired_input_lines, rt.chat_inline_paint_input_lines_cap);
            if (live_input_lines != rt.chat_inline_paint_input_lines) return false;

            var w: std.Io.Writer = .fixed(&rt.chat_inline_buf);
            // Focus state isn't cached — every focus toggle arms
            // `chat_inline_paint_pending`, which refreshes the cache
            // before fast-path can see a stale value.
            if (rt.chat_focus_in_panel) {
                w.writeAll("\x1B[?25l\x1B[s") catch return false;
            } else {
                w.writeAll("\x1B[?25h\x1B[s") catch return false;
            }
            paintInputBlock(&w, rt, rt.chat_inline_paint_input_top_row, rt.chat_inline_paint_input_row) catch return false;

            const total_rows: u16 = ctx.terminal_rows orelse 24;
            const base_reserve: u16 = ctx.statusbar_base_reserve orelse 3;
            const restore_pos = inlineRestorePos(rt, total_rows, base_reserve);
            w.print("\x1B[{d};{d}H", .{ restore_pos.row, restore_pos.col }) catch return false;

            rt.chat_inline_buf_len = w.end;
            return true;
        }

        /// Shared cleanup when an inline-chat paint attempt fails
        /// (terminal too small or paint-buffer overflow). Roll the
        /// open flag back so the input swallow releases and the
        /// proxy shrinks the reservation on the next tick; latch
        /// the error hint and write a stderr line so the failure
        /// isn't silent.
        fn recoverInlineChatPaintFailure(rt: *Runtime) void {
            rt.chat_inline_paint_cache_valid = false;
            if (rt.chat_inline_open) {
                rt.chat_inline_open = false;
                latchErr(rt, "inline chat: terminal too small or paint buffer overflow");
                const inline_overflow_msg = "atty: inline chat: terminal too small or paint buffer overflow\n";
                _ = std.c.write(2, inline_overflow_msg, inline_overflow_msg.len);
            }
        }

        pub fn provideTermBytes(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
            // Inline chat panel — takes precedence over the
            // alt-screen overlay because they're mutually exclusive
            // (the action handler enforces this) and the inline
            // panel is what the user is interacting with when its
            // paint latch is set.
            if (rt.chat_inline_paint_pending) {
                rt.chat_inline_paint_pending = false;
                rt.chat_inline_input_dirty = false;
                if (paintInlineChat(rt, ctx)) {
                    return rt.chat_inline_buf[0..rt.chat_inline_buf_len];
                }
                recoverInlineChatPaintFailure(rt);
            } else if (rt.chat_inline_input_dirty) {
                rt.chat_inline_input_dirty = false;
                if (paintInlineChatInputFast(rt, ctx)) {
                    return rt.chat_inline_buf[0..rt.chat_inline_buf_len];
                }
                // Fast-path bailed (cache stale, geometry changed,
                // chrome state changed). Fall through to a full
                // repaint via the same buffer.
                if (paintInlineChat(rt, ctx)) {
                    return rt.chat_inline_buf[0..rt.chat_inline_buf_len];
                }
                recoverInlineChatPaintFailure(rt);
            }
            // Chat overlay paint (phase 2a) takes precedence over
            // the conclusion + cursor-colour paths. The overlay's
            // alt-screen lives at the outer terminal, while
            // conclusion is for scroll-history and cursor-colour is
            // for the prompt area — they're mutually exclusive
            // surfaces.
            if (rt.chat_overlay_paint_pending) {
                rt.chat_overlay_paint_pending = false;
                if (paintChatOverlay(rt, ctx)) {
                    if (rt.chat_overlay_buf) |slice| return slice;
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
            // Recall picker paint — same alt-screen scaffolding
            // pattern as the chat overlay. Mutually exclusive with
            // the chat surfaces (the action handler refuses to open
            // when any chat surface is active).
            if (rt.chat_recall_paint_pending) {
                rt.chat_recall_paint_pending = false;
                if (paintChatRecall(rt, ctx)) {
                    if (rt.chat_recall_buf) |slice| return slice;
                }
                // Paint failed — free the items list (would otherwise
                // leak until detach), reset open state, and arm a
                // final close-path paint so the alt-screen exit
                // sequence still lands on the user's terminal.
                if (rt.chat_recall_open) {
                    if (rt.chat_recall_items.len > 0) {
                        chat_persist.freeDialogMetaList(rt.allocator, rt.chat_recall_items);
                        rt.chat_recall_items = &.{};
                    }
                    rt.chat_recall_selected_idx = 0;
                    rt.chat_recall_open = false;
                    rt.chat_recall_paint_pending = true;
                    latchErr(rt, "recall picker render failed");
                }
            }
            // Conclusion banner emission takes precedence over the
            // cursor-colour edge logic — the banner is one-shot
            // multi-line output that scrolls into shell history.
            // The proxy's `writeAll` on the returned slice handles
            // arbitrary sizes via posix-level looping, so single-
            // emission is correct even for multi-KiB banners.
            // Per-tick chunking would interleave the conclusion
            // bytes with cursor + statusbar events between ticks,
            // breaking the terminal's "follow new output to the
            // bottom" heuristic and leaving the new shell prompt
            // off-screen below the user's viewport.
            if (rt.conclusion_pending) {
                if (rt.conclusion_formatted) |formatted| {
                    rt.conclusion_pending = false;
                    return formatted;
                }
                rt.conclusion_pending = false;
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
