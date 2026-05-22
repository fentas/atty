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
        fn writeSanitized(w: *std.Io.Writer, bytes: []const u8) anyerror!void {
            // Walk codepoints (not raw bytes) so multi-byte UTF-8
            // sequences with continuation bytes in 0x80..0x9F (a `—`
            // em-dash, an emoji, CJK glyph, etc.) survive intact.
            // The previous byte-level filter dropped those
            // continuation bytes as if they were C1 controls,
            // leaving an orphan leading byte the terminal rendered
            // as `�`. C1 controls are now checked AFTER decode
            // (cp in 0x80..0x9F), not against raw bytes.
            var it = pw.utf8Iter(bytes);
            while (it.next()) |c| {
                if (c.cp < 0x20 or c.cp == 0x7F) {
                    if (c.cp == 0x09) {
                        try w.writeAll("\t");
                    } else if (c.cp == 0x0A or c.cp == 0x0D) {
                        try w.writeAll(" ");
                    }
                    continue;
                }
                if (c.cp >= 0x80 and c.cp <= 0x9F) continue;
                const start = it.i - c.byte_len;
                try w.writeAll(bytes[start..it.i]);
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
        /// On terminals with GLOBAL DECSTBM scope (rare; some
        /// configurations of Ghostty) the close's `\x1B[r` would
        /// wipe the statusbar reservation — the proxy now detects
        /// the module-overlay close edge and fires `sb.reactivate`
        /// within the same tick (`proxy.zig`'s `prev_overlay_active`
        /// edge handler).
        fn paintChatOverlay(rt: *Runtime, ctx: *m.Context) bool {
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
                w.writeAll("  \x1B[2m(no conversation yet \u{2014} start one with Alt+S)\x1B[0m\r\n") catch return false;
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
                    renderOverlayTurnContent(&w, rt.allocator, turn) catch return false;
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
            w.print("\x1B[{d};1H\x1B[2K", .{rows - 1}) catch return false;
            w.writeAll("\x1B[22;1;38;5;14m\u{276F}\x1B[0m ") catch return false;
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
                    writeSanitized(&w, rt.chat_input_buf[win_start..cur]) catch return false;
                }
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
            // The footer sits OUTSIDE the DECSTBM scroll region, so
            // anchoring the "↑ N below" indicator here keeps it
            // visible regardless of how far the scrollback walks.
            if (overlay_offset > 0) {
                var sb: [48]u8 = undefined;
                const ind = std.fmt.bufPrint(&sb, "\x1B[2m[\u{2191} {d} below]\x1B[0m ", .{overlay_offset}) catch "";
                w.writeAll(ind) catch return false;
            }
            w.writeAll("\x1B[2m[Alt+T auto \u{00B7} Alt+M model \u{00B7} Alt+Shift+C close \u{00B7} Enter send \u{00B7} PgUp/PgDn]\x1B[0m") catch return false;
            rt.chat_overlay_buf_len = w.end;
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
                return try renderWrappedRaw(w, c, max_visible, max_rows);
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
                return try renderWrappedRaw(w, c, max_visible, max_rows);
            };
            // Per-action rendering — single row each. The envelope
            // shape is already compact (description → command);
            // wrap would just break the structured summary across
            // rows for no readability win.
            switch (parsed.action) {
                .exec => {
                    const cmd = parsed.command();
                    const desc = parsed.description();
                    if (desc.len > 0) {
                        try writeSanitized(w, pw.truncateToCols(desc, max_visible / 2));
                        try w.writeAll(" \x1B[2m\u{2192}\x1B[0m ");
                    }
                    // Command in cyan-on-default to stand out as the
                    // actionable bit.
                    try w.writeAll("\x1B[22;38;5;14m");
                    const cmd_room: usize = if (max_visible > 20) max_visible - 20 else max_visible;
                    const cslice = pw.truncateToCols(cmd, cmd_room);
                    try writeSanitized(w, cslice);
                    try w.writeAll("\x1B[0m");
                    if (cslice.len < cmd.len) try w.writeAll(" \x1B[2m[\u{2026}]\x1B[0m");
                },
                .question => {
                    const q = parsed.question();
                    const slice = pw.truncateToCols(q, max_visible);
                    try w.writeAll("\x1B[3m"); // italic
                    try writeSanitized(w, slice);
                    try w.writeAll("\x1B[0m");
                    if (slice.len < q.len) try w.writeAll(" \x1B[2m[\u{2026}]\x1B[0m");
                },
                .done => {
                    // Reason is free-form prose. Pre-fix shape capped
                    // at `max_visible` cols → a 600-word LLM reply
                    // got clipped to one row's worth (~74 chars on an
                    // 80-col terminal). Inline panel has rows to
                    // spare; render via the markdown-aware wrap path
                    // so multi-paragraph reasons span multiple rows.
                    // Same `\u{2026}` overflow marker, but applied
                    // per-row by md_render when content exceeds
                    // `max_rows`, not per-byte.
                    try w.writeAll("\x1B[22;38;5;141m\u{2713}\x1B[0m "); // mauve check
                    const r = parsed.reason();
                    // The `✓ ` prefix took 2 visible cols on the first
                    // row; subsequent wrap rows have the full
                    // `max_visible` budget. md_render handles per-row
                    // wrap + the `[…]` overflow marker only when
                    // content actually exceeds max_rows.
                    return md_render.render(w, r, max_visible, max_rows, &writeSanitized);
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
                // `done` envelopes' free-prose reason renders via
                // md_render and can span many rows; exec + question
                // still take exactly one row (compact summary).
                // Cheap shape-check via `envelopeActionIsDone`
                // rather than a full JSON parse — back-walk anchor
                // math only needs a row-count estimate.
                if (envelopeActionIsDone(c)) {
                    // Estimate row count by walking the wrap iterator
                    // over the WHOLE envelope content. Two corrections
                    // applied so the estimate stays a safe upper bound
                    // for what the render path actually emits:
                    //
                    //   1. The wrap iterator sees JSON `\n` escapes
                    //      as two literal chars; the render path
                    //      parses the JSON value and feeds md_render
                    //      which hard-breaks on real newlines. Each
                    //      escape corresponds to AT LEAST one extra
                    //      rendered row that the raw wrap count
                    //      would miss. Adding `escapes_n` to the
                    //      row total bounds this — over-counts
                    //      slightly (the escape's 2 bytes are also
                    //      counted in the wrap rows) but the
                    //      direction is safe: the back-walk anchor
                    //      reserves enough room for the newest turn
                    //      rather than letting it get clipped.
                    //   2. Min 1 row for empty content (matches the
                    //      existing fallthrough at the bottom).
                    var it = pw.wrapIter(c, cols);
                    var rows: usize = 0;
                    while (it.next()) |_| {
                        rows += 1;
                        if (rows >= max_rows) break;
                    }
                    if (rows < max_rows) {
                        var escapes_n: usize = 0;
                        var i: usize = 0;
                        while (i + 1 < c.len) : (i += 1) {
                            if (c[i] == '\\' and c[i + 1] == 'n') {
                                escapes_n += 1;
                                i += 1; // skip past the `n`
                            }
                        }
                        rows = @min(max_rows, rows + escapes_n);
                    }
                    return if (rows == 0) 1 else rows;
                }
                return 1;
            }
            if (c.len == 0) return 1;
            var it = pw.wrapIter(c, cols);
            var rows: usize = 0;
            while (it.next()) |_| {
                rows += 1;
                if (rows >= max_rows) break;
            }
            return if (rows == 0) 1 else rows;
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
            const prompt_style: []const u8 = if (rt.chat_focus_in_panel)
                "\x1B[22;1;38;5;14m"
            else
                "\x1B[2;38;5;14m";
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
                    try w.writeAll("\u{276F}\x1B[0m ");
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
            const scrollback_rows: u16 = if (input_top_row > top_row + 1) input_top_row - top_row - 1 else 0;
            var row: u16 = top_row + 1;
            // Blank-clear every scrollback row up front so prior
            // chat content doesn't leak when the turns shrink.
            var r: u16 = row;
            while (r < input_top_row) : (r += 1) {
                w.print("\x1B[{d};1H\x1B[2K", .{r}) catch return false;
            }

            // `chat_inline_view_offset` shifts the window of the
            // last `scrollback_rows` turns toward the head. Clamp
            // here too — turns_len shrinks after FIFO eviction.
            const max_inline_offset: usize = if (rt.turns_len > 0) rt.turns_len - 1 else 0;
            const inline_offset: usize = if (rt.chat_inline_view_offset > max_inline_offset) max_inline_offset else rt.chat_inline_view_offset;
            const visible_end: usize = rt.turns_len - inline_offset;
            row = top_row + 1;
            const max_inline_visible: usize = if (cols_usize > 12) cols_usize - 6 else 40;
            // When scrolled back, the top scrollback row becomes a
            // dim "↑ N more turn(s) below" header so the user
            // doesn't think new replies vanished — mirrors the
            // overlay's scrolled-back indicator.
            var scrollback_budget: u16 = scrollback_rows;
            if (inline_offset > 0 and scrollback_budget > 1) {
                var sb: [80]u8 = undefined;
                const head = std.fmt.bufPrint(&sb, "  \x1B[2m\u{2191} {d} below \u{00B7} \x1B[22;38;5;14mCtrl+End\x1B[39;2m for tail\x1B[0m", .{inline_offset}) catch "";
                w.print("\x1B[{d};1H\x1B[2K", .{row}) catch return false;
                w.writeAll(head) catch return false;
                row += 1;
                scrollback_budget -= 1;
            }
            // No per-turn truncation: each turn renders its full
            // wrap-chunk count, capped only by the scrollback
            // budget. The OLDEST visible turn naturally gets
            // clipped (via `oldest_turn_cap` in the back-walk
            // below) when total demand exceeds budget; older
            // turns scroll off the top. Use PageUp/PageDown to
            // walk back through chat history.
            const per_turn_max_rows: usize = scrollback_budget;
            // Pick `start_turn` by walking BACKWARDS from the newest
            // visible turn and summing each candidate's rendered-row
            // claim. Previously this was `visible_end -
            // scrollback_budget` (one-row-per-turn assumption), which
            // anchored the OLDEST turns at the panel top and let the
            // newest turns get clipped — opposite of the intended
            // tail-anchored layout. Pre-counting via the same wrap
            // walk used at render time keeps the newest turn fully
            // visible even when older neighbours each consume up to
            // `per_turn_max_rows` rows.
            var start_turn: usize = visible_end;
            var rows_remaining: u16 = scrollback_budget;
            var oldest_turn_cap: u16 = 0;
            while (start_turn > 0 and rows_remaining > 0) {
                const idx = start_turn - 1;
                const turn_rows: u16 = @intCast(@min(
                    countTurnRows(rt.turns[idx], max_inline_visible, per_turn_max_rows),
                    @as(usize, std.math.maxInt(u16)),
                ));
                if (turn_rows >= rows_remaining) {
                    // Include this turn as the OLDEST visible — its
                    // render gets clipped to `rows_remaining` rows
                    // so the newer turns each keep their full claim.
                    // Without the per-oldest cap, the render loop's
                    // generic `min(per_turn_max_rows, remaining)`
                    // would let the newest turn eat the deficit
                    // instead.
                    start_turn = idx;
                    oldest_turn_cap = rows_remaining;
                    rows_remaining = 0;
                    break;
                }
                rows_remaining -= turn_rows;
                start_turn = idx;
            }
            var first_visible_turn = true;
            for (rt.turns[start_turn..visible_end]) |turn| {
                if (row >= input_top_row) break;
                w.print("\x1B[{d};1H\x1B[2K", .{row}) catch return false;
                const prefix: []const u8 = switch (turn.kind) {
                    .user => "\x1B[22;1;38;5;14mYou:\x1B[0m ",
                    .assistant_exec => "\x1B[22;38;5;141matty:\x1B[0m ",
                    .observation => "\x1B[2mOutput:\x1B[0m ",
                };
                w.writeAll(prefix) catch return false;
                const remaining_rows: usize = @intCast(input_top_row - row);
                const turn_rows_cap: usize = if (first_visible_turn and oldest_turn_cap > 0)
                    @min(@as(usize, oldest_turn_cap), remaining_rows)
                else
                    @min(per_turn_max_rows, remaining_rows);
                const rows_used = renderTurnContent(&w, turn, max_inline_visible, turn_rows_cap) catch 1;
                row += @intCast(rows_used);
                first_visible_turn = false;
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
