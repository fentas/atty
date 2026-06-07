//! Hook entry points for the LLM module — `onInput`, `onAction`,
//! `onOutput`, `onTick`, `onLineCommit`, `pollShellInput` — plus
//! the dialog state-machine helpers they share (`handleDialogResponse`,
//! `startDialog*`, `fireDialogRequest`, …). Extracted from `llm.zig`
//! to keep the implementation file scannable; the production code
//! is verbatim — only the wrapping `Module(cfg, Runtime)` factory
//! is new.
//!
//! Public re-exports live in `llm.zig` as `pub const onInput = hooks.onInput;`
//! etc. so the comptime dispatcher's `@hasDecl` walks still find
//! every hook on the `configure()` return type.

const std = @import("std");
const m = @import("../../module.zig");
const dialog = @import("dialog.zig");
const types = @import("types.zig");
const sys_context = @import("sys_context.zig");
const worker_mod_ns = @import("worker.zig");
const chat_persist = @import("chat_persist.zig");
const keymap = @import("../../keymap.zig");
const nowMs = @import("../_lib.zig").nowMs;
const parse = @import("parse.zig");

/// Strip C0 + C1 control bytes from a user-visible status line.
/// Delegates to `parse.stripControlBytes` so the C1 handling
/// (raw 0x80–0x9F, UTF-8-encoded 0xC2 0x80–0x9F) matches the
/// sibling sanitizers used on PTY- and terminal-bound LLM output.
/// The status bar is a single physical row — an unsanitized ESC,
/// CSI (0x9B), or SS3 could reposition the cursor, clear the
/// screen, or splice arbitrary SGR styling, turning a benign env-
/// var display into an injection vector.
pub fn sanitizeForStatus(buf: []u8, raw: []const u8) []const u8 {
    const n = parse.stripControlBytes(raw, buf);
    return buf[0..n];
}

/// True when `bytes` contains a sequence that visibly clears the
/// primary screen / scrollback. Three shapes the shell's `clear`
/// utility / ncurses / `Ctrl+L` emit:
///   - `\x1B[2J`  — erase-in-display (visible area)
///   - `\x1B[3J`  — erase-in-display (scrollback) — ncurses E3
///   - `\x1Bc`    — RIS / hard reset
/// Cursor moves (`\x1B[H`) often accompany the first form; we don't
/// match them separately because they alone don't wipe content.
/// False positives would over-close the inline panel; this set
/// covers the canonical `clear`-style cases without sweeping in
/// SGR / cursor-only sequences.
pub fn containsClearSequence(bytes: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        if (bytes[i] != 0x1B) continue;
        const next = bytes[i + 1];
        if (next == 'c') return true;
        if (next == '[' and i + 3 < bytes.len) {
            // CSI 2J / 3J. Skip optional numeric parameter then look
            // for the J terminator with the right digit.
            const p = bytes[i + 2];
            const t = bytes[i + 3];
            if ((p == '2' or p == '3') and t == 'J') return true;
        }
    }
    return false;
}

pub fn Module(comptime cfg: types.Config, comptime Runtime: type) type {
    return struct {
        // worker_mod is the comptime-instantiated request-shaper +
        // worker-thread factory. Same pattern as paint.zig / llm.zig.
        const worker_mod = worker_mod_ns.Module(cfg);
        const RequestKind = worker_mod.RequestKind;
        const worker = worker_mod.worker;
        const doRequest = worker_mod.doRequest;
        const doDialogRequest = worker_mod.doDialogRequest;

        // dialog_helpers re-binds the Runtime-touching state-machine
        // helpers used by the hooks below.
        const dialog_helpers = dialog.Module(cfg, Runtime);
        const latchHint = dialog_helpers.latchHint;
        const latchErr = dialog_helpers.latchErr;
        const queueInjection = dialog_helpers.queueInjection;
        const freeTurns = dialog_helpers.freeTurns;
        const appendCaptured = dialog_helpers.appendCaptured;
        const advancePastMarker = dialog_helpers.advancePastMarker;
        const captureConclusion = dialog_helpers.captureConclusion;

        /// Push a turn to the in-memory ring AND (when persistence
        /// is enabled and the dialog isn't incognito) append the
        /// turn as one NDJSON line to the current session file.
        /// Best-effort: disk failures leave the in-memory push
        /// intact. Incognito sessions skip the disk path entirely
        /// — `incognito gates LOCAL recording` is the contract the
        /// UI advertises (see paint.zig divider docstring).
        fn pushTurn(rt: *Runtime, ctx: *m.Context, kind: dialog.TurnKind, content: []u8) !void {
            try dialog_helpers.pushTurn(rt, kind, content);
            if (!ctx.incognito and rt.chat_persist_path.len > 0) {
                if (chat_persist.appendTurn(rt.allocator, rt.chat_persist_path, kind, content)) {
                    rt.chat_persist_has_writes = true;
                }
            }
        }

        /// Drop the unused 0-byte reservation when no record was
        /// appended, then free the path slice. Used by both the
        /// rotation path and the early-bail rotation cases.
        fn dropUnusedReservation(rt: *Runtime) void {
            if (rt.chat_persist_path.len == 0) return;
            if (!rt.chat_persist_has_writes) {
                const z = rt.allocator.dupeZ(u8, rt.chat_persist_path) catch null;
                if (z) |s| {
                    defer rt.allocator.free(s);
                    _ = chat_persist.unlinkPath(s.ptr);
                }
            }
            rt.allocator.free(rt.chat_persist_path);
            rt.chat_persist_path = &.{};
        }

        /// Reserve the next session path. No-op when the dialogs
        /// dir is unavailable; failures leave `chat_persist_path`
        /// empty so subsequent `pushTurn`s silently skip the disk.
        fn rotatePersistencePath(rt: *Runtime) void {
            if (rt.chat_persist_dir.len == 0) return;
            if (chat_persist.createSessionPath(rt.allocator, rt.chat_persist_dir)) |path| {
                if (path.len > 0) {
                    rt.chat_persist_path = path;
                } else {
                    rt.allocator.free(path);
                }
            } else |_| {}
            rt.chat_persist_has_writes = false;
            // Any retained `conclusion_formatted` was already
            // persisted by the wrapper's pre-reset flush (or was a
            // cancel path with no banner). The banner stays in
            // memory for overlay recall but must not re-persist
            // into THIS file — pending stays false until the next
            // `captureConclusion` sets it.
            rt.chat_persist_conclusion_pending = false;
        }

        /// Free the recall picker's owned state + arm the close
        /// paint. Used by Enter (after a successful load) and Esc.
        /// Idempotent — safe to call when the picker isn't open.
        fn closeRecallPicker(rt: *Runtime) void {
            if (rt.chat_recall_items.len > 0) {
                chat_persist.freeDialogMetaList(rt.allocator, rt.chat_recall_items);
                rt.chat_recall_items = &.{};
            }
            rt.chat_recall_selected_idx = 0;
            if (rt.chat_recall_open) {
                rt.chat_recall_open = false;
                rt.chat_recall_paint_pending = true;
            }
        }

        /// Load a persisted dialog file's records into the in-memory
        /// ring. Wipes the current turns + conclusion first. Returns
        /// true on success; on failure latches a hint + returns
        /// false (caller decides whether to keep the picker open).
        ///
        /// Direct `dialog_helpers.pushTurn` bypasses the disk-write
        /// wrapper — load must not re-append to the current session
        /// file.
        fn loadDialogFromMeta(rt: *Runtime, meta: chat_persist.DialogMeta) bool {
            const path_z = rt.allocator.dupeZ(u8, meta.path) catch {
                latchHint(rt, "out of memory loading dialog");
                return false;
            };
            defer rt.allocator.free(path_z);
            const fd = chat_persist.openReadOnly(path_z.ptr);
            if (fd < 0) {
                latchHint(rt, "couldn't open the dialog file");
                return false;
            }
            defer _ = chat_persist.closeFd(fd);
            var raw: std.ArrayList(u8) = .empty;
            defer raw.deinit(rt.allocator);
            var chunk: [8 * 1024]u8 = undefined;
            const max_bytes: usize = 4 * 1024 * 1024;
            while (raw.items.len < max_bytes) {
                const want: usize = @min(chunk.len, max_bytes - raw.items.len);
                const got = chat_persist.readBytes(fd, &chunk, want);
                if (got <= 0) break;
                raw.appendSlice(rt.allocator, chunk[0..@as(usize, @intCast(got))]) catch {
                    latchHint(rt, "out of memory loading dialog");
                    return false;
                };
            }

            // Wipe current state so a partial parse doesn't mix in.
            dialog_helpers.freeTurns(rt);
            if (rt.conclusion_formatted) |old| {
                rt.allocator.free(old);
                rt.conclusion_formatted = null;
            }
            rt.chat_persist_conclusion_pending = false;

            var line_start: usize = 0;
            var i: usize = 0;
            var oom_during_load = false;
            while (i <= raw.items.len) : (i += 1) {
                if (i == raw.items.len or raw.items[i] == '\n') {
                    const line = raw.items[line_start..i];
                    line_start = i + 1;
                    const trimmed = std.mem.trimEnd(u8, line, "\r\n");
                    if (trimmed.len == 0) continue;
                    const rec = chat_persist.parseRecord(rt.allocator, trimmed) catch |err| switch (err) {
                        error.OutOfMemory => {
                            oom_during_load = true;
                            break;
                        },
                        else => continue,
                    };
                    switch (rec) {
                        .turn => |t| {
                            dialog_helpers.pushTurn(rt, t.kind, t.content) catch {
                                rt.allocator.free(t.content);
                            };
                        },
                        .conclusion => |c| {
                            if (rt.conclusion_formatted) |old| rt.allocator.free(old);
                            rt.conclusion_formatted = c;
                        },
                    }
                }
            }
            if (oom_during_load) {
                latchHint(rt, "out of memory loading dialog — partial state may remain");
                return false;
            }
            return true;
        }

        /// dialogReset wrapper — flushes the captured conclusion to
        /// the current session file (the `.done` path sets
        /// `conclusion_formatted` BEFORE calling dialogReset), then
        /// rotates the session path so the next dialog lands in a
        /// fresh file. Empty reservations get `unlink`ed so we
        /// don't accumulate 0-byte files for cancel paths.
        ///
        /// The flush is gated on `chat_persist_conclusion_pending`
        /// so a banner retained across a previous dialogReset
        /// (kept in memory for the overlay's recall behavior)
        /// doesn't get re-appended to the next dialog's file.
        /// ALSO gated on `chat_persist_has_writes` so an incognito
        /// dialog's conclusion doesn't leak past the per-turn
        /// incognito gate — if no turn was persisted to this file,
        /// the conclusion isn't either, and the empty reservation
        /// gets `unlink`ed below.
        fn dialogReset(rt: *Runtime, io: std.Io) void {
            if (rt.chat_persist_path.len > 0 and rt.chat_persist_conclusion_pending and rt.chat_persist_has_writes) {
                if (rt.conclusion_formatted) |banner| {
                    _ = chat_persist.appendConclusion(rt.allocator, rt.chat_persist_path, banner);
                }
            }
            // Clear pending unconditionally — an incognito skip or
            // a write failure must not re-flush the same banner on
            // the next reset.
            rt.chat_persist_conclusion_pending = false;
            dialog_helpers.dialogReset(rt, io);
            dropUnusedReservation(rt);
            rotatePersistencePath(rt);
        }

        /// abortDialog wrapper — no conclusion to flush on the
        /// error path; just rotate after the helper's internal
        /// dialogReset call (which sees the un-wrapped sibling in
        /// dialog_helpers' scope, NOT this wrapper, so we don't
        /// rotate twice).
        fn abortDialog(rt: *Runtime, io: std.Io, msg: []const u8) void {
            dialog_helpers.abortDialog(rt, io, msg);
            dropUnusedReservation(rt);
            rotatePersistencePath(rt);
        }

        const Turn = dialog.Turn;
        const DialogResponse = dialog.Response(cfg.max_response_bytes);

        // Thin wrappers around `dialog.*` — pin the `DialogResponse`
        // factory + `buildRequestBody` so call sites stay short.
        // llm.zig re-exports these as `pub const parseDialogResponse
        // = hooks.parseDialogResponse;` so tests can reach them
        // through the configure() return without an import dance.
        pub fn parseDialogResponse(
            allocator: std.mem.Allocator,
            raw: []const u8,
            out: *DialogResponse,
        ) !void {
            _ = allocator;
            dialog.parseFencedResponse(DialogResponse, raw, out);
        }
        pub const buildDialogRequestBody = dialog.buildRequestBody;

        // Shared comptime strings (inert-mode notice + dialog system
        // prompt) live in `consts.zig` so this file and llm.zig
        // both import them without a circular dependency.
        const llm_consts = @import("consts.zig").Module(cfg);
        const inert_error_msg = llm_consts.inert_error_msg;
        const effective_dialog_system_prompt = llm_consts.effective_dialog_system_prompt;
        const effective_auto_system_prompt = llm_consts.effective_auto_system_prompt;

        /// Parsed chat-input keystroke. Folds single-byte control
        /// codes (Ctrl+A/E/B/F/U/K/W, Backspace, DEL, Enter, Ctrl+D)
        /// and multi-byte CSI sequences (Left/Right/Home/End from
        /// terminals that don't push the kitty kbd flag) into a
        /// single discriminated union so both panel + overlay
        /// paths share one editor.
        const ChatKey = union(enum) {
            none,
            close, // Ctrl+D
            enter,
            insert: u8,
            backspace,
            delete_forward,
            move_left,
            move_right,
            // chat-mode question pick-list (#214) consumes these to
            // navigate choices; when no pick-list is active they
            // walk the cursor across `\n` boundaries inside the
            // multi-line input buffer (column-preserving, clamped).
            move_up,
            move_down,
            move_home,
            move_end,
            escape, // chat-mode question cancel (#214)
            kill_to_start,
            kill_to_end,
            kill_word_back,
            clear_all, // Ctrl+C — wipe buffer, keep panel open
        };

        /// Pull the next chat-input keystroke from `input[i..]`.
        /// Advances `i` past the consumed bytes. Drops unknown CSI
        /// finals to .none rather than treating their final letter
        /// as a printable insert.
        ///
        /// Cross-`read` boundary limitation: an incomplete CSI tail
        /// (e.g. `ESC [ 3` waiting for `~`) is drained to chunk end,
        /// so if the kernel splits the sequence across two reads the
        /// continuation bytes (the lone `~`) land as a printable
        /// insert on the next call. Stateful CSI carryover would fix
        /// it cleanly but adds an interactive-state field on the
        /// runtime; deferred. Terminals emit cursor-keys atomically
        /// in one write, so a split is unusual outside signal-
        /// interrupt cases.
        fn parseChatKey(input: []const u8, i: *usize, paste_active: *bool) ChatKey {
            const b = input[i.*];

            // Bracketed paste mode. While the terminal has framed
            // bytes between `\x1B[200~` and `\x1B[201~`, treat every
            // byte as content — `\r`/`\n` insert as literal newlines
            // (NOT submit), and control bytes that would otherwise
            // edit the buffer are dropped so a paste of e.g. a python
            // script with embedded backspaces doesn't shred the
            // buffer. The closing marker can straddle a chunk
            // boundary; if we see `\x1B` here we wait for at least 6
            // bytes before declaring the marker malformed and falling
            // back to literal insert.
            if (paste_active.*) {
                // Emergency abort: Ctrl+C / Ctrl+D bypass paste mode
                // unconditionally so the user can always escape a
                // stuck paste (terminal crashed mid-paste, closing
                // marker never arrived) — otherwise the panel can't
                // be closed at all once we've entered paste mode.
                // Fall through to the normal handling below by
                // clearing the flag and letting the rest of the
                // function classify the byte.
                if (b == 0x03 or b == 0x04) {
                    paste_active.* = false;
                } else {
                    if (b == 0x1B) {
                        if (i.* + 5 < input.len and std.mem.startsWith(u8, input[i.*..], "\x1B[201~")) {
                            i.* += 6;
                            paste_active.* = false;
                            return .none;
                        }
                        // Partial marker or some other ESC — wait for
                        // more bytes. (Adversarial paste content
                        // containing a literal `\x1B[201~` would end
                        // the paste early; terminals double-escape
                        // internal ESC bytes to prevent this in
                        // well-behaved implementations.)
                        if (i.* + 5 >= input.len) {
                            i.* = input.len;
                            return .none;
                        }
                        // Not a closing marker — treat the ESC as
                        // content.
                    }
                    i.* += 1;
                    return switch (b) {
                        0x0D, 0x0A => .{ .insert = '\n' },
                        0x09, 0x20...0x7E, 0x80...0xFF => .{ .insert = b },
                        else => .none, // drop other control bytes inside paste
                    };
                }
            }

            // Incomplete escape tail (chunk ends with `ESC`, `ESC [`,
            // or `ESC O`). Treat as a standalone Esc keystroke when
            // the chat-mode question UI consumer wants to react to
            // it; the partial-CSI risk is small because terminals
            // emit cursor-key sequences atomically. Caller can
            // discriminate by checking remaining input.len.
            if (b == 0x1B and i.* + 1 >= input.len) {
                i.* = input.len;
                return .escape;
            }
            // Alt+Enter — legacy fallback for Shift+Enter on terminals
            // not in kitty kbd mode (where Enter and Shift+Enter share
            // the same byte). Common chat-UI convention (Slack, Discord,
            // …) and harmless on kitty-kbd terminals since they
            // wouldn't emit this shape for Shift+Enter anyway.
            if (b == 0x1B and i.* + 1 < input.len and
                (input[i.* + 1] == 0x0D or input[i.* + 1] == 0x0A))
            {
                i.* += 2;
                return .{ .insert = '\n' };
            }
            // Bracketed paste start: `\x1B[200~`. Mark the state and
            // consume the marker bytes silently. The next iteration
            // will hit the `paste_active` branch above.
            if (b == 0x1B and i.* + 5 < input.len and
                std.mem.startsWith(u8, input[i.*..], "\x1B[200~"))
            {
                i.* += 6;
                paste_active.* = true;
                return .none;
            }
            // Incomplete `\x1B[200~` straddling a chunk boundary —
            // wait for more bytes rather than mis-classify.
            if (b == 0x1B and i.* + 1 < input.len and input[i.* + 1] == '[' and
                i.* + 5 >= input.len and
                std.mem.startsWith(u8, "\x1B[200~"[0..(input.len - i.*)], input[i.*..]))
            {
                i.* = input.len;
                return .none;
            }
            if (b == 0x1B and (input[i.* + 1] == '[' or input[i.* + 1] == 'O') and i.* + 2 >= input.len) {
                i.* = input.len;
                return .none;
            }
            // SS3 (application-cursor mode) — `ESC O <letter>` is
            // what many terminals emit for arrow / Home / End when
            // the cursor-key mode is application instead of normal.
            // Map the same handful we accept on CSI; drop the rest
            // as a 3-byte sequence so the trailing letter doesn't
            // leak as a printable.
            if (b == 0x1B and i.* + 2 < input.len and input[i.* + 1] == 'O') {
                const c = input[i.* + 2];
                i.* += 3;
                return switch (c) {
                    'D' => .move_left,
                    'C' => .move_right,
                    'A' => .move_up,
                    'B' => .move_down,
                    'H' => .move_home,
                    'F' => .move_end,
                    else => .none,
                };
            }
            if (b == 0x1B and i.* + 2 < input.len and input[i.* + 1] == '[') {
                const c = input[i.* + 2];
                // CSI structure: `ESC [` then optional parameter
                // bytes (0x30-0x3F) and intermediate bytes
                // (0x20-0x2F), then a single final byte (0x40-0x7E).
                // If `c` is already a final, consume the 3-byte
                // sequence; otherwise scan forward for the final.
                if (c >= 0x40 and c <= 0x7E) {
                    // VT-style CSI never reaches here because none
                    // of {1,3,4,7,8} are in 0x40..0x7E — they're
                    // handled by the digit branch below.
                    i.* += 3;
                    return switch (c) {
                        'A' => .move_up,
                        'B' => .move_down,
                        'D' => .move_left,
                        'C' => .move_right,
                        'H' => .move_home,
                        'F' => .move_end,
                        else => .none,
                    };
                }
                // Per ECMA-48: CSI = ESC `[` P* I* F where
                //   P = 0x30..0x3F (digits, `;`, `?`, `<`/`>`/`=`)
                //   I = 0x20..0x2F (intermediates: SP, `!`, `"`, … `/`)
                //   F = 0x40..0x7E (final byte)
                // Trigger the scan on any P or I byte (everything
                // 0x20..0x3F) so a CSI starting with an intermediate
                // (`ESC [ ! p` etc.) doesn't fall through to the
                // unrecognized-intermediate arm below and leak its
                // tail. Two finals carry meaning for chat input:
                //   ~  → VT-style function keys (Home/End/Delete)
                //   u  → kitty kbd "CSI-u" (Shift+Enter etc.)
                // Anything else gets consumed silently.
                if (c >= 0x20 and c <= 0x3F) {
                    var scan: usize = i.* + 2;
                    var p1: usize = 0;
                    var p2: usize = 0;
                    var have_p1 = false;
                    var have_p2 = false;
                    var saw_semi = false;
                    var unknown_param = false;
                    while (scan < input.len) : (scan += 1) {
                        const x = input[scan];
                        if (x >= '0' and x <= '9') {
                            // Cap accumulation at 1M — realistic CSI
                            // params fit in 16 bits; this guards
                            // against malformed/adversarial input
                            // running `p = p*10 + d` until usize
                            // overflows + traps in safety builds.
                            if (!saw_semi) {
                                if (p1 < 0x100000) p1 = p1 * 10 + (x - '0');
                                have_p1 = true;
                            } else {
                                if (p2 < 0x100000) p2 = p2 * 10 + (x - '0');
                                have_p2 = true;
                            }
                        } else if (x == ';') {
                            saw_semi = true;
                        } else if (x >= 0x40 and x <= 0x7E) {
                            i.* = scan + 1;
                            if (x == '~' and have_p1) {
                                return switch (p1) {
                                    1, 7 => .move_home,
                                    3 => .delete_forward,
                                    4, 8 => .move_end,
                                    else => .none,
                                };
                            }
                            if (x == 'u' and have_p1 and !unknown_param) {
                                // CSI-u: <codepoint>;<mod>u
                                // mod value 1=none, 2=Shift, 3=Alt,
                                // 4=Shift+Alt, 5=Ctrl, 6=Shift+Ctrl,
                                // 7=Ctrl+Alt, 8=Shift+Alt+Ctrl, … —
                                // shift-bit is `(mod - 1) & 1`.
                                const mod: usize = if (have_p2) p2 else 1;
                                const shift = ((mod -| 1) & 1) != 0;
                                if (p1 == 13 and shift) return .{ .insert = '\n' };
                                // Bare CSI-u (no modifier) for an
                                // ASCII printable codepoint folds to
                                // an insert — some terminals at
                                // higher kitty progressive-enhance
                                // levels send `\x1b[8226;1u` etc.
                                // for typed chars instead of raw
                                // bytes. Multi-byte codepoints
                                // (p1 > 0x7E) need a state machine
                                // to emit remaining UTF-8 bytes
                                // across calls; left out for now —
                                // atty pushes only flag 1, where
                                // terminals emit raw UTF-8 for typed
                                // non-ASCII.
                                if (mod == 1 and p1 >= 0x20 and p1 <= 0x7E) return .{ .insert = @intCast(p1) };
                            }
                            return .none;
                        } else {
                            unknown_param = true;
                        }
                    }
                    // Incomplete CSI — drain to chunk end so the
                    // caller's loop terminates; the continuation
                    // bytes (the missing final) will arrive on the
                    // next read and reparse cleanly because their
                    // own first byte won't be 0x1B.
                    i.* = input.len;
                    return .none;
                }
                // Unrecognized intermediate (rare). Consume the
                // 3-byte prefix so the loop terminates; the rest
                // will reparse as best as the next iteration can.
                i.* += 3;
                return .none;
            }
            i.* += 1;
            return switch (b) {
                0x01 => .move_home, // Ctrl+A
                0x05 => .move_end, // Ctrl+E
                0x02 => .move_left, // Ctrl+B
                0x06 => .move_right, // Ctrl+F
                0x08, 0x7F => .backspace, // Ctrl+H / DEL
                0x03 => .clear_all, // Ctrl+C — wipe the prompt
                0x04 => .close, // Ctrl+D
                0x0B => .kill_to_end, // Ctrl+K
                0x15 => .kill_to_start, // Ctrl+U
                0x17 => .kill_word_back, // Ctrl+W
                0x0D, 0x0A => .enter,
                // 0x80..0xFF lets multi-byte UTF-8 paste land in
                // the buffer byte-by-byte — the terminal reassembles
                // the codepoint on render. Without this, typing or
                // pasting `•` (`0xE2 0x80 0xA2`) was silently
                // dropped because every byte hit the `.none` arm.
                0x20...0x7E, 0x80...0xFF => .{ .insert = b },
                else => .none,
            };
        }

        /// Apply a parsed key to (buf, len, cursor). Returns true
        /// when the edit changed any state (caller arms the paint
        /// latch in that case). The .close / .enter variants are
        /// caller-handled (this function returns false for them so
        /// the caller still treats the byte specially) — every
        /// other key mutates the buffer here.
        fn applyChatEdit(buf: []u8, len: *usize, cursor: *usize, key: ChatKey) bool {
            switch (key) {
                .insert => |c| {
                    if (len.* >= buf.len) return false;
                    var j: usize = len.*;
                    while (j > cursor.*) : (j -= 1) buf[j] = buf[j - 1];
                    buf[cursor.*] = c;
                    len.* += 1;
                    cursor.* += 1;
                    return true;
                },
                .backspace => {
                    if (cursor.* == 0) return false;
                    var j: usize = cursor.* - 1;
                    while (j + 1 < len.*) : (j += 1) buf[j] = buf[j + 1];
                    len.* -= 1;
                    cursor.* -= 1;
                    return true;
                },
                .delete_forward => {
                    if (cursor.* >= len.*) return false;
                    var j: usize = cursor.*;
                    while (j + 1 < len.*) : (j += 1) buf[j] = buf[j + 1];
                    len.* -= 1;
                    return true;
                },
                .move_left => {
                    if (cursor.* == 0) return false;
                    cursor.* -= 1;
                    return true;
                },
                .move_right => {
                    if (cursor.* >= len.*) return false;
                    cursor.* += 1;
                    return true;
                },
                .move_up => {
                    var line_start: usize = cursor.*;
                    while (line_start > 0 and buf[line_start - 1] != '\n') : (line_start -= 1) {}
                    if (line_start == 0) return false;
                    const col = cursor.* - line_start;
                    const prev_line_end = line_start - 1;
                    var prev_line_start: usize = prev_line_end;
                    while (prev_line_start > 0 and buf[prev_line_start - 1] != '\n') : (prev_line_start -= 1) {}
                    const prev_line_len = prev_line_end - prev_line_start;
                    cursor.* = prev_line_start + @min(col, prev_line_len);
                    return true;
                },
                .move_down => {
                    var line_start: usize = cursor.*;
                    while (line_start > 0 and buf[line_start - 1] != '\n') : (line_start -= 1) {}
                    var line_end: usize = cursor.*;
                    while (line_end < len.* and buf[line_end] != '\n') : (line_end += 1) {}
                    if (line_end >= len.*) return false;
                    const col = cursor.* - line_start;
                    const next_line_start = line_end + 1;
                    var next_line_end: usize = next_line_start;
                    while (next_line_end < len.* and buf[next_line_end] != '\n') : (next_line_end += 1) {}
                    const next_line_len = next_line_end - next_line_start;
                    cursor.* = next_line_start + @min(col, next_line_len);
                    return true;
                },
                .move_home => {
                    if (cursor.* == 0) return false;
                    cursor.* = 0;
                    return true;
                },
                .move_end => {
                    if (cursor.* == len.*) return false;
                    cursor.* = len.*;
                    return true;
                },
                .kill_to_start => {
                    if (cursor.* == 0) return false;
                    var j: usize = 0;
                    while (cursor.* + j < len.*) : (j += 1) buf[j] = buf[cursor.* + j];
                    len.* -= cursor.*;
                    cursor.* = 0;
                    return true;
                },
                .kill_to_end => {
                    if (cursor.* == len.*) return false;
                    len.* = cursor.*;
                    return true;
                },
                .clear_all => {
                    if (len.* == 0 and cursor.* == 0) return false;
                    len.* = 0;
                    cursor.* = 0;
                    return true;
                },
                .kill_word_back => {
                    if (cursor.* == 0) return false;
                    var k: usize = cursor.*;
                    // Skip trailing whitespace, then a run of
                    // non-whitespace. Matches readline's M-Backspace
                    // / Ctrl+W shape closely enough that the muscle
                    // memory carries over.
                    while (k > 0 and (buf[k - 1] == ' ' or buf[k - 1] == '\t')) : (k -= 1) {}
                    while (k > 0 and buf[k - 1] != ' ' and buf[k - 1] != '\t') : (k -= 1) {}
                    if (k == cursor.*) return false;
                    var j: usize = k;
                    while (cursor.* + (j - k) < len.*) : (j += 1) buf[j] = buf[cursor.* + (j - k)];
                    len.* -= cursor.* - k;
                    cursor.* = k;
                    return true;
                },
                else => return false,
            }
        }

        pub fn onInput(rt: *Runtime, ctx: *m.Context, input: []const u8) m.Error!m.Action {
            // Keymap actions (Alt+Shift+C close, Esc, Ctrl+Shift+X)
            // dispatch in the proxy BEFORE this hook fires, so the
            // user can still close the surface even mid-typing.
            //
            // Inline panel: focus is IN the panel only when
            // `chat_focus_in_panel` is set. `Ctrl+Up` parks focus on
            // the shell prompt above; while parked the panel stays
            // painted but `.forward`s input so it goes to bash.
            if (rt.chat_inline_open and rt.chat_focus_in_panel) {
                var i: usize = 0;
                while (i < input.len) {
                    const key = parseChatKey(input, &i, &rt.chat_paste_active);
                    // Chat-mode question pick-list (#214) intercept.
                    // Up/Down navigate the choices + free-text row.
                    // Enter on a choice submits the choice text;
                    // Enter on the free-text row falls through to
                    // the normal `.enter` arm below. Esc cancels
                    // the pick-list (lets the user free-type).
                    if (rt.chat_question_active and rt.chat_question_choice_count > 0) {
                        switch (key) {
                            .move_up => {
                                if (rt.chat_question_selected_idx > 0) {
                                    rt.chat_question_selected_idx -= 1;
                                    rt.chat_inline_paint_pending = true;
                                }
                                continue;
                            },
                            .move_down => {
                                if (rt.chat_question_selected_idx < rt.chat_question_choice_count) {
                                    rt.chat_question_selected_idx += 1;
                                    rt.chat_inline_paint_pending = true;
                                }
                                continue;
                            },
                            .escape => {
                                rt.chat_question_active = false;
                                rt.chat_inline_paint_pending = true;
                                continue;
                            },
                            .enter => {
                                const sel = rt.chat_question_selected_idx;
                                if (sel < rt.chat_question_choice_count) {
                                    // Submit the picked choice as the
                                    // user's answer. Same submission
                                    // path as a typed answer.
                                    const choice = rt.question_choices_storage[sel][0..rt.question_choices_lens[sel]];
                                    const copy = rt.allocator.dupe(u8, choice) catch {
                                        latchErr(rt, "out of memory submitting pick");
                                        continue;
                                    };
                                    pushTurn(rt, ctx, .user, copy) catch {
                                        rt.allocator.free(copy);
                                        latchErr(rt, "out of memory submitting pick");
                                        continue;
                                    };
                                    rt.chat_question_active = false;
                                    rt.chat_inline_input_len = 0;
                                    rt.chat_inline_input_cursor = 0;
                                    fireDialogRequest(rt, ctx) catch {
                                        latchErr(rt, "couldn't send pick — see status");
                                    };
                                    rt.chat_inline_paint_pending = true;
                                    continue;
                                }
                                // selected_idx == choice_count → free-text;
                                // fall through to the normal .enter arm below.
                            },
                            else => {
                                // Any insert / edit keystroke flips
                                // focus to the free-text row + falls
                                // through to the editor below. Matches
                                // Claude Code's "start typing →
                                // free-text" pattern.
                                const is_edit = switch (key) {
                                    .insert, .backspace, .delete_forward, .move_left, .move_right, .move_home, .move_end => true,
                                    else => false,
                                };
                                if (is_edit and rt.chat_question_selected_idx != rt.chat_question_choice_count) {
                                    rt.chat_question_selected_idx = rt.chat_question_choice_count;
                                    rt.chat_inline_paint_pending = true;
                                }
                            },
                        }
                    }
                    switch (key) {
                        .close => {
                            // Ctrl+D — close the panel. Stop
                            // processing the rest of THIS chunk so
                            // post-Ctrl+D bytes don't land in the
                            // now-closed panel's buffer.
                            rt.chat_inline_open = false;
                            rt.chat_paste_active = false;
                            rt.chat_inline_rows_override = null;
                            rt.chat_inline_paint_pending = true;
                            return .swallow;
                        },
                        .enter => {
                            // Trim trailing spaces/tabs from the
                            // submitted line (preserves any embedded
                            // newlines from Shift+Enter — those are
                            // intentional content). Empty check looks
                            // at all-whitespace including newlines so
                            // a buffer of just `\n\n` from accidental
                            // Shift+Enter strokes is treated as empty.
                            var trimmed_len = rt.chat_inline_input_len;
                            while (trimmed_len > 0 and (rt.chat_inline_input_buf[trimmed_len - 1] == ' ' or rt.chat_inline_input_buf[trimmed_len - 1] == '\t')) : (trimmed_len -= 1) {}
                            var has_content = false;
                            for (rt.chat_inline_input_buf[0..trimmed_len]) |bb| {
                                if (bb != ' ' and bb != '\t' and bb != '\n' and bb != '\r') {
                                    has_content = true;
                                    break;
                                }
                            }
                            if (!has_content) {
                                rt.chat_inline_input_len = 0;
                                rt.chat_inline_input_cursor = 0;
                                rt.chat_inline_paint_pending = true;
                                continue;
                            }
                            rt.chat_inline_input_len = trimmed_len;
                            // Trimming may have left the cursor past
                            // the new EOL — clamp before any path that
                            // could survive without resetting it.
                            if (rt.chat_inline_input_cursor > trimmed_len) {
                                rt.chat_inline_input_cursor = trimmed_len;
                            }

                            const can_fire = !rt.in_flight and
                                (rt.dialog_state == .idle or
                                    rt.dialog_state == .awaiting_question_answer);
                            if (!can_fire) {
                                latchHint(rt, "request in flight — wait for the response, or Ctrl+Shift+X to cancel");
                                rt.chat_inline_paint_pending = true;
                                continue;
                            }

                            const copy = rt.allocator.dupe(u8, rt.chat_inline_input_buf[0..rt.chat_inline_input_len]) catch {
                                latchErr(rt, "out of memory submitting chat turn");
                                rt.chat_inline_input_len = 0;
                                rt.chat_inline_input_cursor = 0;
                                rt.chat_inline_paint_pending = true;
                                continue;
                            };
                            pushTurn(rt, ctx, .user, copy) catch {
                                rt.allocator.free(copy);
                                latchErr(rt, "out of memory submitting chat turn");
                                rt.chat_inline_input_len = 0;
                                rt.chat_inline_input_cursor = 0;
                                rt.chat_inline_paint_pending = true;
                                continue;
                            };
                            rt.chat_inline_input_len = 0;
                            rt.chat_inline_input_cursor = 0;
                            fireDialogRequest(rt, ctx) catch {
                                latchErr(rt, "couldn't send chat turn — see status");
                            };
                            rt.chat_inline_paint_pending = true;
                        },
                        else => {
                            if (applyChatEdit(
                                &rt.chat_inline_input_buf,
                                &rt.chat_inline_input_len,
                                &rt.chat_inline_input_cursor,
                                key,
                            )) {
                                rt.chat_inline_input_dirty = true;
                            } else if (rt.chat_paste_active and key == .insert) {
                                // Buffer hit cap mid-paste. Without
                                // surfacing this, users believe the
                                // whole paste landed and assistant
                                // replies refer to a phantom tail.
                                latchHint(rt, "paste truncated — chat input buffer full");
                            }
                        },
                    }
                }
                return .swallow;
            }

            if (rt.chat_recall_open) {
                // Recall picker — alt-screen overlay. Swallow every
                // keystroke; only arrows / Enter / Esc do anything.
                var i: usize = 0;
                while (i < input.len) {
                    const key = parseChatKey(input, &i, &rt.chat_paste_active);
                    switch (key) {
                        .move_up => {
                            if (rt.chat_recall_selected_idx > 0) {
                                rt.chat_recall_selected_idx -= 1;
                                rt.chat_recall_paint_pending = true;
                            }
                        },
                        .move_down => {
                            if (rt.chat_recall_items.len > 0 and rt.chat_recall_selected_idx + 1 < rt.chat_recall_items.len) {
                                rt.chat_recall_selected_idx += 1;
                                rt.chat_recall_paint_pending = true;
                            }
                        },
                        .enter => {
                            // Snapshot the chosen meta before close
                            // frees the list. Then load + open the
                            // inline panel + reset session-toggle
                            // bookkeeping (mirror llm_inline_chat_toggle).
                            if (rt.chat_recall_selected_idx >= rt.chat_recall_items.len) {
                                closeRecallPicker(rt);
                                continue;
                            }
                            const sel = rt.chat_recall_items[rt.chat_recall_selected_idx];
                            const path_copy = rt.allocator.dupe(u8, sel.path) catch {
                                latchErr(rt, "out of memory loading dialog");
                                closeRecallPicker(rt);
                                continue;
                            };
                            const name_copy = rt.allocator.dupe(u8, sel.name) catch {
                                // Name dupe is the second alloc — path
                                // succeeded so the load CAN proceed,
                                // but the user-facing hint would print
                                // a blank name without this fallback.
                                rt.allocator.free(path_copy);
                                latchErr(rt, "out of memory loading dialog");
                                closeRecallPicker(rt);
                                continue;
                            };
                            // Same alloc-failure shape as path/name
                            // above: free what we already own + bail
                            // with a user-facing error so we never
                            // hand free() a slice we didn't allocate.
                            const preview_copy = rt.allocator.alloc(u8, 0) catch {
                                rt.allocator.free(path_copy);
                                rt.allocator.free(name_copy);
                                latchErr(rt, "out of memory loading dialog");
                                closeRecallPicker(rt);
                                continue;
                            };
                            const meta_copy = chat_persist.DialogMeta{
                                .path = path_copy,
                                .name = name_copy,
                                .preview = preview_copy,
                            };
                            defer {
                                rt.allocator.free(meta_copy.path);
                                rt.allocator.free(meta_copy.name);
                                rt.allocator.free(meta_copy.preview);
                            }
                            closeRecallPicker(rt);

                            if (loadDialogFromMeta(rt, meta_copy)) {
                                rt.chat_inline_open = true;
                                rt.chat_inline_paint_pending = true;
                                rt.chat_focus_in_panel = true;
                                rt.chat_refocus_pending = false;
                                rt.chat_inline_rows_override = null;
                                rt.conclusion_pending = false;
                                const loaded_any = rt.turns_len > 0 or rt.conclusion_formatted != null;
                                var name_buf: [128]u8 = undefined;
                                const msg = if (loaded_any)
                                    std.fmt.bufPrint(&name_buf, "recalled dialog: {s}", .{meta_copy.name}) catch "recalled dialog"
                                else
                                    std.fmt.bufPrint(&name_buf, "dialog {s} is empty or corrupted", .{meta_copy.name}) catch "dialog empty or corrupted";
                                latchHint(rt, msg);
                            }
                            // Stop processing the rest of this input
                            // chunk — focus has moved to the inline
                            // panel; let the next read drive it.
                            return .swallow;
                        },
                        .escape => {
                            closeRecallPicker(rt);
                            return .swallow;
                        },
                        else => {},
                    }
                }
                return .swallow;
            }

            if (rt.chat_overlay_open) {
                var i: usize = 0;
                while (i < input.len) {
                    const key = parseChatKey(input, &i, &rt.chat_paste_active);
                    // Chat-mode question pick-list (#214) — same
                    // shape as the inline panel handler above.
                    if (rt.chat_question_active and rt.chat_question_choice_count > 0) {
                        switch (key) {
                            .move_up => {
                                if (rt.chat_question_selected_idx > 0) {
                                    rt.chat_question_selected_idx -= 1;
                                    rt.chat_overlay_paint_pending = true;
                                }
                                continue;
                            },
                            .move_down => {
                                if (rt.chat_question_selected_idx < rt.chat_question_choice_count) {
                                    rt.chat_question_selected_idx += 1;
                                    rt.chat_overlay_paint_pending = true;
                                }
                                continue;
                            },
                            .escape => {
                                rt.chat_question_active = false;
                                rt.chat_overlay_paint_pending = true;
                                continue;
                            },
                            .enter => {
                                const sel = rt.chat_question_selected_idx;
                                if (sel < rt.chat_question_choice_count) {
                                    const choice = rt.question_choices_storage[sel][0..rt.question_choices_lens[sel]];
                                    const copy = rt.allocator.dupe(u8, choice) catch {
                                        latchErr(rt, "out of memory submitting pick");
                                        continue;
                                    };
                                    pushTurn(rt, ctx, .user, copy) catch {
                                        rt.allocator.free(copy);
                                        latchErr(rt, "out of memory submitting pick");
                                        continue;
                                    };
                                    rt.chat_question_active = false;
                                    rt.chat_input_len = 0;
                                    rt.chat_input_cursor = 0;
                                    fireDialogRequest(rt, ctx) catch {
                                        latchErr(rt, "couldn't send pick — see status");
                                    };
                                    rt.chat_overlay_paint_pending = true;
                                    continue;
                                }
                                // selected_idx == choice_count → fall through
                            },
                            else => {
                                const is_edit = switch (key) {
                                    .insert, .backspace, .delete_forward, .move_left, .move_right, .move_home, .move_end => true,
                                    else => false,
                                };
                                if (is_edit and rt.chat_question_selected_idx != rt.chat_question_choice_count) {
                                    rt.chat_question_selected_idx = rt.chat_question_choice_count;
                                    rt.chat_overlay_paint_pending = true;
                                }
                            },
                        }
                    }
                    switch (key) {
                        .close => {
                            // Ctrl+D closes the overlay. Stop the
                            // chunk so post-Ctrl+D bytes don't land
                            // in the now-closed overlay's buffer.
                            rt.chat_overlay_open = false;
                            rt.chat_paste_active = false;
                            rt.chat_overlay_paint_pending = true;
                            return .swallow;
                        },
                        .enter => {
                            // Trim trailing whitespace, refuse when
                            // mid-cycle, dupe-push-fire. Same logic
                            // as the inline branch above; the only
                            // delta is which buffer + paint latch
                            // is touched.
                            var trimmed_len = rt.chat_input_len;
                            while (trimmed_len > 0 and (rt.chat_input_buf[trimmed_len - 1] == ' ' or rt.chat_input_buf[trimmed_len - 1] == '\t')) : (trimmed_len -= 1) {}
                            if (trimmed_len == 0) {
                                rt.chat_input_len = 0;
                                rt.chat_input_cursor = 0;
                                rt.chat_overlay_paint_pending = true;
                                continue;
                            }
                            rt.chat_input_len = trimmed_len;
                            if (rt.chat_input_cursor > trimmed_len) {
                                rt.chat_input_cursor = trimmed_len;
                            }

                            const can_fire = !rt.in_flight and
                                (rt.dialog_state == .idle or
                                    rt.dialog_state == .awaiting_question_answer);
                            if (!can_fire) {
                                latchHint(rt, "request in flight — wait for the response, or Ctrl+Shift+X to cancel");
                                rt.chat_overlay_paint_pending = true;
                                continue;
                            }

                            const copy = rt.allocator.dupe(u8, rt.chat_input_buf[0..rt.chat_input_len]) catch {
                                latchErr(rt, "out of memory submitting chat turn");
                                rt.chat_input_len = 0;
                                rt.chat_input_cursor = 0;
                                rt.chat_overlay_paint_pending = true;
                                continue;
                            };
                            pushTurn(rt, ctx, .user, copy) catch {
                                rt.allocator.free(copy);
                                latchErr(rt, "out of memory submitting chat turn");
                                rt.chat_input_len = 0;
                                rt.chat_input_cursor = 0;
                                rt.chat_overlay_paint_pending = true;
                                continue;
                            };
                            rt.chat_input_len = 0;
                            rt.chat_input_cursor = 0;
                            fireDialogRequest(rt, ctx) catch {
                                latchErr(rt, "couldn't send chat turn — see status");
                            };
                            rt.chat_overlay_paint_pending = true;
                        },
                        else => {
                            if (applyChatEdit(
                                &rt.chat_input_buf,
                                &rt.chat_input_len,
                                &rt.chat_input_cursor,
                                key,
                            )) {
                                rt.chat_overlay_paint_pending = true;
                            }
                        },
                    }
                }
                return .swallow;
            }

            // Auto-exec abort window: any keystroke during the
            // armed window disarms the pending Enter. The
            // suggested command stays on the prompt for the user
            // to edit / abort with Ctrl+Shift+X or Esc.
            if (rt.auto_exec_armed) rt.auto_exec_armed = false;

            // Observe the line state to maintain `ai_mode_active`.
            // Runs on EVERY keystroke (cheap — just a prefix
            // check). When the user types `#: ` the flag flips to
            // true; the statusText hook reads the flag and swaps
            // the bar's text to the AI mode hint. Backspacing the
            // prefix flips it back. Mode is observational only;
            // the action keys (Alt+A / Alt+S / Alt+Shift+S) are
            // what actually trigger LLM work — see `onAction`
            // below + `docs/llm-exec-mode-design.md`.
            rt.ai_mode_active = std.mem.startsWith(u8, ctx.line.current(), cfg.prefix);

            const is_enter = blk: {
                for (input) |b| if (b == 0x0D or b == 0x0A) break :blk true;
                break :blk false;
            };
            if (!is_enter) return .forward;

            // Question-answer mode: the user's typed answer is for
            // the LLM, not the shell. Replace the Enter with Ctrl+U
            // (bash kills the readline buffer; the answer never runs
            // as a command) AND commit the pre-replace line so
            // onLineCommit fires with the answer text — our
            // state-machine branch there pushes it as a `.user` turn.
            if (rt.dialog_state == .awaiting_question_answer) {
                return .{ .replace_commit = "\x15" };
            }

            // Same lookup pattern as guardrail: applyInput already
            // ran, so the line we want is in lastCommitted.
            const line = ctx.line.lastCommitted() orelse ctx.line.current();

            // Persistent dialog / auto mode: while active, every
            // Enter on a non-empty line gets sent to the LLM as a
            // `.user` turn AND runs as a shell command (the line
            // could be an LLM-suggested command that the user
            // edited, OR a free-form follow-up — in both cases we
            // want the LLM to see what was actually executed).
            //
            // Gating on the dialog state machine being IDLE here is
            // important: if we're already mid-flight (.generating,
            // .suggesting, .executing, .capturing_output,
            // .observation_ready), the LLM will get the
            // observation as the next user turn automatically via
            // OSC 133 capture — adding another `.user` turn here
            // would double-up.
            //
            // The Enter passes through to the shell (we return
            // `.forward`, not `.replace_commit`), so the typed
            // command actually runs. The dialog request fires
            // async on the worker thread; output flows back via
            // OSC 133 capture as the next observation turn.
            if (rt.dialog_persistent_mode != .off and rt.dialog_state == .idle) {
                if (line.len > 0) {
                    // Strip the optional `#: ` prefix so the user
                    // can use the same Enter-fires-LLM behaviour
                    // whether they prepend the prefix or not.
                    const body = if (std.mem.startsWith(u8, line, cfg.prefix))
                        std.mem.trim(u8, line[cfg.prefix.len..], " \t")
                    else
                        std.mem.trim(u8, line, " \t");
                    if (body.len > 0 and body.len <= cfg.max_prompt_bytes and !rt.inert and rt.osc133_capture.active) {
                        const initial = rt.allocator.dupe(u8, body) catch return .forward;
                        pushTurn(rt, ctx, .user, initial) catch {
                            rt.allocator.free(initial);
                            return .forward;
                        };
                        rt.auto_mode_active = (rt.dialog_persistent_mode == .auto);
                        fireDialogRequest(rt, ctx) catch |err| {
                            abortDialog(rt, ctx.io, switch (err) {
                                error.BodyTooLarge => "dialog body too large for buffer — increase Config.body_buf_bytes",
                                error.OutOfMemory => "out of memory firing dialog request",
                                else => "internal error firing dialog request",
                            });
                        };
                        // Let the Enter pass through so the command
                        // also runs in the shell. Output → OSC 133
                        // → next observation turn.
                    }
                }
                return .forward;
            }

            if (!std.mem.startsWith(u8, line, cfg.prefix)) return .forward;

            // Enter on `#: …` is configurable via `Config.enter_action`.
            // Default `.none` (no-op) — explicit action keys
            // (Alt+A / Alt+S / Alt+Shift+S) are the security gate
            // against accidental LLM calls. Users can opt back into
            // the pre-Alt-key trigger flow by setting `.single`,
            // `.dialog`, or `.auto` in their config.
            switch (cfg.enter_action) {
                .none => return .forward,
                .single => {
                    const result = triggerSinglePrompt(rt, ctx, line, .replace_commit_on_enter);
                    // Mirror the Alt+A eager-clear of
                    // `ai_mode_active`. The shell wipes the line
                    // via the returned `.replace_commit = "\x15"`,
                    // so the prefix is gone from line_state on the
                    // next keystroke. Clearing ai_mode_active now
                    // means the verbose statusbar hint disappears
                    // immediately, not on the next keypress —
                    // same flicker-free behaviour as the Alt+A
                    // path. Gated on api_base.len for the same
                    // reason: inert mode keeps the user in AI mode
                    // so they can fix config + retry.
                    if (!rt.inert and result == .replace_commit) {
                        rt.ai_mode_active = false;
                    }
                    return result;
                },
                .dialog, .auto => return startDialogViaEnter(rt, ctx, cfg.enter_action == .auto),
            }
        }

        /// Dispatch site for the keymap actions `llm_exec_*`. The
        /// proxy calls this for every binding match; the module
        /// gates each action on `ai_mode_active` (i.e. the user is
        /// currently inside an AI prompt — the line starts with
        /// `#: `). Outside AI mode, the actions no-op silently so
        /// stray Alt-key presses don't surprise the user.
        ///
        /// **Returns** true when the action was handled (proxy
        /// swallows the binding bytes); false when not (proxy
        /// lets the bytes flow through to readline / the inner
        /// program — so e.g. Alt+a outside AI mode still hits
        /// readline's "set-mark" or whatever the user has bound
        /// there).
        ///
        /// Per-action behaviour:
        /// - `llm_exec_single`: same as `#:<Enter>` — kick the
        ///   worker with the current line body, queue Ctrl+U for
        ///   the next `pollShellInput` tick to wipe the typed
        ///   `#: …` text. The LLM response gets injected when it
        ///   lands.
        /// - `llm_exec_dialog` / `_auto`: route through
        ///   `startDialog` — fires the multi-turn dialog request,
        ///   then waits for `;C`/`;D` markers between exec steps.
        ///   `_auto` additionally arms an auto-submit timer
        ///   (`cfg.auto_delay_ms`) so each suggested command runs
        ///   without manual Enter; any keystroke aborts the timer.
        /// - `llm_exec_cycle_model`: rotates `current_model_idx`
        ///   through `cfg.providers[]`; no-op + hint when there's
        ///   only the single-model fallback.
        /// - `llm_exec_toggle_help`: latches a one-line help hint
        ///   summarising the active model / endpoint / cancel key.
        /// - `llm_exec_cancel`: clears any in-flight state, bumps
        ///   the worker's req_gen so a late response is dropped,
        ///   wipes the typed prompt via Ctrl+U injection, clears
        ///   ai_mode_active. Works outside AI mode too (drains
        ///   any leftover state).
        pub fn onAction(rt: *Runtime, ctx: *m.Context, action: keymap.Action) m.Error!bool {
            switch (action) {
                .llm_exec_single => {
                    if (!rt.ai_mode_active) return false;
                    const line = ctx.line.current();
                    const body = std.mem.trim(u8, line[cfg.prefix.len..], " \t");
                    // Empty body — user pressed Alt+A right after
                    // typing `#: ` with no task. Info hint, no
                    // worker call, no Ctrl+U; user keeps typing.
                    if (body.len == 0) {
                        latchHint(rt, "type your task after `#: ` then press Alt+A");
                        return true; // consumed (we displayed feedback)
                    }
                    // Over-length body — explicit hint instead of
                    // a silent no-op. Without this, `trigger
                    // SinglePrompt`'s internal `body.len >
                    // max_prompt_bytes` branch would return
                    // `.forward` without queuing Ctrl+U or
                    // latching feedback, and the Alt+A press
                    // would visibly do nothing.
                    if (body.len > cfg.max_prompt_bytes) {
                        latchHint(rt, "prompt too long — shorten the task and try again");
                        return true;
                    }
                    _ = triggerSinglePrompt(rt, ctx, line, .queue_pending_injection);
                    // Clear AI mode immediately — the line is
                    // about to be wiped by Ctrl+U, so the prefix
                    // won't match next time `onInput` recomputes
                    // the flag. Without this, the verbose hint
                    // would linger in the statusbar until the
                    // user's next keystroke.
                    //
                    // BUT only when the worker actually got the
                    // prompt. In inert mode (no api_base resolved
                    // at attach), `triggerSinglePrompt` latches
                    // the "no endpoint" error and returns without
                    // queuing Ctrl+U — so the typed `#: …` text
                    // stays on the prompt. If we cleared
                    // ai_mode_active here, the very next
                    // keystroke would see the prefix still on
                    // line_state.current() and flip the flag
                    // back to true, producing a visible one-
                    // tick flicker in the statusbar hint. Inert
                    // mode is the user's signal to fix their
                    // config + re-try, so leave them IN AI mode
                    // — the error notification points at the
                    // fix.
                    if (!rt.inert) rt.ai_mode_active = false;
                    return true;
                },
                // Alt+S / Alt+Shift+S TOGGLE persistent mode rather
                // than firing a one-shot request. Mode stays on
                // across multiple command cycles until the user
                // deactivates (Esc / Ctrl+Shift+X / same-key
                // toggle) OR the LLM emits `action=done`. While in
                // mode, every Enter on a non-empty line is sent to
                // the LLM as a `.user` turn AND runs as a shell
                // command — see the Enter branch of `onInput`.
                //
                // First entry into mode ALSO fires the initial
                // request if `ai_mode_active` is true (the user
                // already typed `#: …`) — same kick-off behaviour
                // as the old action-based design. After that, the
                // user can keep typing prompts at the bare shell
                // prompt without the `#: ` prefix.
                .llm_exec_dialog => return toggleDialogMode(rt, ctx, .dialog),
                .llm_exec_auto => return toggleDialogMode(rt, ctx, .auto),
                .llm_exec_cycle_model => {
                    // Alt+M fires in any LLM-active context: the
                    // `#: ` prompt-prefix flow (`ai_mode_active`),
                    // an open chat surface, OR a mid-dialog state
                    // (Alt+S started a dialog but neither chat
                    // surface is open AND the prompt buffer has
                    // been wiped post-commit so `ai_mode_active`
                    // is back to false). Without all three the
                    // user can't switch providers mid-flow —
                    // defeats the point of a multi-provider config
                    // (#173 #7).
                    const llm_active = rt.ai_mode_active or rt.chat_inline_open or rt.chat_overlay_open or rt.dialog_persistent_mode != .off or rt.dialog_state != .idle;
                    if (!llm_active) return false;
                    if (cfg.providers.len == 0) {
                        latchHint(rt, "single-provider config — set `providers = &.{ ... }` to cycle");
                        return true;
                    }
                    // Cycle forward, skipping non-cycleable entries
                    // and entries whose `for_modes` doesn't cover
                    // the user's current dispatch mode. Self-select
                    // (the loop landing back on `current_provider_idx`)
                    // counts as "no other entry matches" — latch
                    // the no-op hint instead of advertising the
                    // same provider with a `(N/N)` indicator.
                    const mode = currentDispatchMode(rt);
                    const start_idx = rt.current_provider_idx;
                    var next = start_idx;
                    var tried: usize = 0;
                    while (tried < cfg.providers.len) : (tried += 1) {
                        next = (next + 1) % cfg.providers.len;
                        if (next == start_idx) break;
                        const entry = cfg.providers[next];
                        if (entry.cycleable and entry.for_modes.matches(mode)) {
                            rt.current_provider_idx = next;
                            const label: []const u8 = if (entry.name.len > 0) entry.name else providerLabel(entry.config);
                            var msg_buf: [128]u8 = undefined;
                            const msg = std.fmt.bufPrint(&msg_buf, "provider: {s} ({d}/{d})", .{ label, next + 1, cfg.providers.len }) catch label;
                            latchHint(rt, msg);
                            // The chat panel divider renders the
                            // active provider via
                            // resolveProviderForMode(.chat, …); arm
                            // a repaint so the user sees the cycle
                            // reflected in the chrome, not only in
                            // the statusbar hint.
                            if (rt.chat_inline_open) rt.chat_inline_paint_pending = true;
                            if (rt.chat_overlay_open) rt.chat_overlay_paint_pending = true;
                            return true;
                        }
                    }
                    latchHint(rt, "no other providers cycle to this mode");
                    return true;
                },
                .llm_exec_toggle_help => {
                    if (!rt.ai_mode_active) return false;
                    // Help overlay — surface state that isn't in
                    // the verbose AI hint: current model + how
                    // many alternates are in the cycle, the
                    // resolved endpoint, and a pointer at the
                    // single way to actually cancel. Limited to
                    // ~256 bytes; truncates gracefully on narrow
                    // terms.
                    //
                    // BOTH cycle_info and the final message live in
                    // `buf` so the cycle slice doesn't escape a
                    // nested scope (a previous draft put cycle_info's
                    // backing array inside a `blk` expression — the
                    // slice outlived the array, classic stack-use-
                    // after-scope hazard). One outer buffer, two
                    // bufPrint calls into disjoint subslices.
                    var buf: [256]u8 = undefined;
                    // Endpoint string is env-derived ($LLM_API_BASE
                    // or the per-provider api_base). A hostile env
                    // var like `http://x\x1b[2J` would land control
                    // bytes in the latched status line and let the
                    // user clear the screen, reposition the cursor,
                    // or splice arbitrary SGR styling into the bar.
                    // Sanitize before it hits the formatter.
                    var endpoint_buf: [256]u8 = undefined;
                    const mode = currentDispatchMode(rt);
                    const resolved = worker_mod_ns.resolveProviderForMode(
                        mode,
                        cfg.providers,
                        cfg.provider,
                        rt.current_provider_idx,
                    );
                    const current: []const u8 = if (resolved.name.len > 0)
                        resolved.name
                    else
                        providerLabel(resolved.provider);
                    // Cycle info lives in the first 32 bytes of buf.
                    // Find the resolved entry's index so the
                    // `(i/n)` indicator matches the provider name
                    // we just rendered — important when
                    // resolveProviderForMode fell through to a
                    // first-matching entry that isn't at
                    // current_provider_idx.
                    const resolved_idx: usize = blk: {
                        for (cfg.providers, 0..) |entry, i| {
                            if (std.meta.eql(entry.config, resolved.provider)) break :blk i;
                        }
                        break :blk rt.current_provider_idx;
                    };
                    const cycle_info: []const u8 = if (cfg.providers.len > 1)
                        std.fmt.bufPrint(buf[0..32], " ({d}/{d})", .{ resolved_idx + 1, cfg.providers.len }) catch ""
                    else
                        "";
                    const endpoint_raw: []const u8 = if (rt.inert)
                        "(inert — no endpoint)"
                    else switch (resolved.provider) {
                        // For HTTP, surface the actual endpoint URL —
                        // env-resolved per request. Fall back to
                        // `rt.api_base` (resolved at attach for the
                        // single-shorthand path) when the entry's
                        // env vars haven't been read yet here.
                        .http => |h| if (h.api_base.len > 0) h.api_base else rt.api_base,
                        .subprocess => |sub| if (sub.argv.len > 0) sub.argv[0] else "(subprocess)",
                    };
                    const endpoint = sanitizeForStatus(&endpoint_buf, endpoint_raw);
                    // Message goes into the remaining bytes. cycle_info
                    // is referenced before its underlying storage is
                    // overwritten — bufPrint copies the formatted
                    // string verbatim, so this read-then-write order
                    // is safe.
                    const msg = std.fmt.bufPrint(buf[32..], "provider: {s}{s} · endpoint: {s} · Esc cancel · Ctrl+Shift+I incognito", .{ current, cycle_info, endpoint }) catch {
                        latchHint(rt, current);
                        return true;
                    };
                    latchHint(rt, msg);
                    return true;
                },
                .llm_chat_overlay_toggle => {
                    // Empty-open is intentional: the overlay's input
                    // row is the entry point for a fresh chat.
                    if (!rt.chat_overlay_open) {
                        // Mutual exclusion — if the inline panel is
                        // open, close it first so cursor focus is
                        // unambiguous and `extraReserveRows` returns
                        // to zero. Mirror of the inline-toggle arm.
                        if (rt.chat_inline_open) {
                            rt.chat_inline_open = false;
                            rt.chat_paste_active = false;
                            rt.chat_inline_rows_override = null;
                            rt.chat_inline_paint_pending = true;
                        }
                        rt.chat_overlay_open = true;
                        // Disarm the conclusion auto-emit latch —
                        // the overlay already renders the conclusion
                        // as content, so firing the banner again on
                        // the next tick would print the same text
                        // twice (once in the overlay, once scrolled
                        // into shell history after the overlay
                        // closes).
                        rt.conclusion_pending = false;
                    } else {
                        rt.chat_overlay_open = false;
                        rt.chat_paste_active = false;
                    }
                    rt.chat_overlay_paint_pending = true;
                    return true;
                },
                .llm_inline_chat_toggle => {
                    // Inline chat panel — slim chat surface above the
                    // statusbar. Shell stays visible above; cursor
                    // focus moves into the panel's input row. Mutually
                    // exclusive with the full overlay — opening one
                    // closes the other so cursor focus is unambiguous.
                    //
                    // Refuse to open when there's no statusbar: the
                    // panel's row reservation goes through the
                    // statusbar's DECSTBM machinery; without it the
                    // shell scrolls through the panel and the user's
                    // keystrokes are swallowed with no visible
                    // feedback. statusbar_reserve is null in that
                    // case (proxy didn't populate it). Closing while
                    // already open is still allowed — paint will
                    // emit the DECRC.
                    if (!rt.chat_inline_open and ctx.statusbar_reserve == null) {
                        latchHint(rt, "inline chat needs the statusbar — set `config.statusbar.enabled = true`");
                        const no_sb_msg = "atty: inline chat needs the statusbar — set `config.statusbar.enabled = true`\n";
                        _ = std.c.write(2, no_sb_msg, no_sb_msg.len);
                        return true;
                    }
                    if (rt.chat_overlay_open) {
                        // Close the overlay first; its exit sequence
                        // lands via provideTermBytes on the next tick.
                        rt.chat_overlay_open = false;
                        rt.chat_paste_active = false;
                        rt.chat_overlay_paint_pending = true;
                    }
                    rt.chat_inline_open = !rt.chat_inline_open;
                    rt.chat_inline_paint_pending = true;
                    // #167 — any manual Alt+C toggle (open OR close)
                    // clears the refocus latch so a pending `.exec`-
                    // armed snap doesn't override a fresh user
                    // focus choice on the next `;D`.
                    rt.chat_refocus_pending = false;
                    if (!rt.chat_inline_open) {
                        // Drop the live height override on close so
                        // the next open starts at `cfg.inline_chat_rows`
                        // again. The user opted into a bigger panel
                        // for THIS session, not as a persistent
                        // preference.
                        rt.chat_inline_rows_override = null;
                        // Also drop any in-flight bracketed paste —
                        // same rationale as the other close sites
                        // (stuck flag would make next session's Enter
                        // insert `\n` instead of submit). Round-2
                        // subagent caught this site because the close
                        // is via `= !rt.chat_inline_open` rather than
                        // `= false`, so the regex sweep missed it.
                        rt.chat_paste_active = false;
                    }
                    if (rt.chat_inline_open) {
                        // Disarm the conclusion auto-emit latch so the
                        // banner doesn't fire while inline chat is
                        // active — the user is already chatting, the
                        // separate banner would clutter the panel.
                        rt.conclusion_pending = false;
                        // Default: focus starts in the panel (matches
                        // the previous always-swallow behaviour).
                        rt.chat_focus_in_panel = true;
                        // Defer the prompt-position snapshot to the
                        // FIRST paint (sentinel 0 = not yet captured).
                        // Why not capture here? When the proxy's
                        // reservation-grow path scrolls the prompt UP
                        // to make room for the panel, that scroll
                        // happens AFTER this action handler runs but
                        // BEFORE the panel paints. Capturing now would
                        // record the PRE-scroll row, then the panel's
                        // restore CUP would land in the new panel zone
                        // — bash's next prompt redraw would chase the
                        // cursor, scrolling the prompt UP again on
                        // each redraw. Lazy capture picks up the
                        // POST-scroll ctx.cursor_row that the proxy
                        // refreshed between scroll and paint.
                        rt.chat_open_cursor_row = 0;
                        rt.chat_open_cursor_col = 0;
                    }
                    return true;
                },
                .chat_focus_to_shell => {
                    // Only meaningful when the inline panel is open.
                    // Park the panel: keystrokes flow through to the
                    // shell, panel chrome stays painted but doesn't
                    // swallow input. Repaint dims the input row to
                    // reflect "parked." No-op + don't consume the
                    // keystroke if the panel isn't open — let the
                    // shell handle Ctrl+Up natively (e.g. tmux pane
                    // navigation).
                    if (!rt.chat_inline_open) return false;
                    if (rt.chat_focus_in_panel) {
                        rt.chat_focus_in_panel = false;
                        rt.chat_inline_paint_pending = true;
                    }
                    return true;
                },
                .chat_focus_to_chat => {
                    if (!rt.chat_inline_open) return false;
                    if (!rt.chat_focus_in_panel) {
                        rt.chat_focus_in_panel = true;
                        rt.chat_inline_paint_pending = true;
                    }
                    return true;
                },
                .chat_recall => {
                    // Refuse if the recall picker itself is already
                    // open or the full-screen overlay is up — those
                    // own the alt-screen. The inline panel doesn't
                    // own the alt-screen, so we auto-close it BELOW
                    // (after every failure path has succeeded) and
                    // open the picker on top. Closing earlier would
                    // leave the user with a closed inline panel AND
                    // no picker when (e.g.) listDialogs fails or the
                    // archive is empty.
                    if (rt.chat_overlay_open or rt.chat_recall_open) {
                        latchHint(rt, "close the chat panel first, then Alt+R to recall a past dialog");
                        return true;
                    }
                    // Same statusbar prerequisite as the inline-chat
                    // toggle: opening without a reserved row would let
                    // the shell scroll through the panel.
                    if (ctx.statusbar_reserve == null) {
                        latchHint(rt, "inline chat needs the statusbar — set `config.statusbar.enabled = true`");
                        const no_sb_msg = "atty: inline chat needs the statusbar — set `config.statusbar.enabled = true`\n";
                        _ = std.c.write(2, no_sb_msg, no_sb_msg.len);
                        return true;
                    }
                    if (rt.chat_persist_dir.len == 0) {
                        latchHint(rt, "chat persistence is disabled or unavailable (see chat_persist_enabled)");
                        return true;
                    }

                    const list = chat_persist.listDialogs(rt.allocator, ctx.io, rt.chat_persist_dir) catch {
                        latchHint(rt, "couldn't read dialog archive — see chat_persist_dir");
                        return true;
                    };

                    if (list.len == 0) {
                        chat_persist.freeDialogMetaList(rt.allocator, list);
                        latchHint(rt, "no past dialogs to recall — run an Alt+S dialog first");
                        return true;
                    }

                    // All prerequisites passed — auto-close the
                    // inline panel now and open the picker. Closing
                    // earlier would leave a stuck "closed panel + no
                    // picker" state on any of the failure paths
                    // above. Also clear the live row-override so a
                    // future inline reopen starts from the configured
                    // default (matches the other inline-close sites:
                    // Ctrl+D, Alt+C, overlay handoff, recall load).
                    if (rt.chat_inline_open) {
                        rt.chat_inline_open = false;
                        rt.chat_paste_active = false;
                        rt.chat_focus_in_panel = false;
                        rt.chat_inline_rows_override = null;
                        rt.chat_inline_paint_pending = true;
                    }

                    // Transfer ownership of the list to the Runtime;
                    // closeRecallPicker frees on Enter/Esc.
                    rt.chat_recall_items = list;
                    rt.chat_recall_selected_idx = 0;
                    rt.chat_recall_open = true;
                    rt.chat_recall_paint_pending = true;
                    return true;
                },
                .chat_scroll_to_tail => {
                    const target_overlay = rt.chat_overlay_open;
                    const target_inline = !target_overlay and rt.chat_inline_open and rt.chat_focus_in_panel;
                    if (!target_overlay and !target_inline) return false;
                    const offset_ptr: *usize = if (target_overlay) &rt.chat_view_offset else &rt.chat_inline_view_offset;
                    if (offset_ptr.* != 0) {
                        offset_ptr.* = 0;
                        if (target_overlay) {
                            rt.chat_overlay_paint_pending = true;
                        } else {
                            rt.chat_inline_paint_pending = true;
                        }
                    }
                    return true;
                },
                .chat_scroll_up, .chat_scroll_down, .chat_scroll_page_up, .chat_scroll_page_down => {
                    // Pick the target surface — overlay wins when both
                    // are conceptually open (mutual exclusion makes that
                    // unreachable today, but defensive). Refuse with
                    // `false` when neither is active so PageUp/PageDown
                    // pass through to the shell.
                    const target_overlay = rt.chat_overlay_open;
                    const target_inline = !target_overlay and rt.chat_inline_open and rt.chat_focus_in_panel;
                    if (!target_overlay and !target_inline) return false;
                    if (rt.turns_len == 0) return true;

                    // The inline panel uses ROW-based offsets (per
                    // #213) — the paint computes total_rows and
                    // clamps the offset to the row-budget cap, so
                    // the action handler doesn't need to recompute
                    // it here. Overlay still uses turn-based offset
                    // (single-screen view; no per-turn scroll
                    // navigation needed). The clamp difference is
                    // why max_offset diverges.
                    const max_offset: usize = if (target_overlay)
                        (if (rt.turns_len > 0) rt.turns_len - 1 else 0)
                    else
                        std.math.maxInt(usize);
                    const offset_ptr: *usize = if (target_overlay) &rt.chat_view_offset else &rt.chat_inline_view_offset;
                    // Page size mirrors the visible scrollback. The
                    // overlay shows ~all turns up to 24 rows so use
                    // 8 (per-turn semantics); the inline panel uses
                    // `inline_chat_rows - 2` which is exactly the
                    // visible budget in rows.
                    const page: usize = if (target_overlay) 8 else if (cfg.inline_chat_rows >= 2) cfg.inline_chat_rows - 2 else 1;

                    switch (action) {
                        .chat_scroll_up => offset_ptr.* = @min(offset_ptr.* + 1, max_offset),
                        .chat_scroll_down => offset_ptr.* = if (offset_ptr.* > 0) offset_ptr.* - 1 else 0,
                        .chat_scroll_page_up => offset_ptr.* = @min(offset_ptr.* + page, max_offset),
                        .chat_scroll_page_down => offset_ptr.* = if (offset_ptr.* > page) offset_ptr.* - page else 0,
                        else => unreachable,
                    }

                    if (target_overlay) {
                        rt.chat_overlay_paint_pending = true;
                    } else {
                        rt.chat_inline_paint_pending = true;
                    }
                    return true;
                },
                .llm_chat_toggle_auto => {
                    // Only meaningful while a chat surface is open
                    // — outside chat the persistent-dialog modes
                    // (Alt+S / Alt+Shift+S) own the auto/dialog
                    // distinction. Toggle the auto flag, arm a
                    // repaint so the chat panel chrome reflects
                    // the new state.
                    if (!(rt.chat_inline_open or rt.chat_overlay_open)) return false;
                    rt.auto_mode_active = !rt.auto_mode_active;
                    if (rt.chat_inline_open) rt.chat_inline_paint_pending = true;
                    if (rt.chat_overlay_open) rt.chat_overlay_paint_pending = true;
                    return true;
                },
                .llm_chat_inline_grow, .llm_chat_inline_shrink => {
                    if (!rt.chat_inline_open) return false;
                    const current: u16 = rt.chat_inline_rows_override orelse cfg.inline_chat_rows;
                    // Terminal-aware upper bound. proxy.zig's
                    // `applyReserveRows` clamps the reservation
                    // against the live terminal height, but
                    // `paintInlineChat` uses the OVERRIDE directly to
                    // lay out rows — without a runtime cap, a held
                    // Ctrl+Alt+Up keeps growing the override past
                    // `terminal_rows`, paintInlineChat overflows the
                    // fixed paint buffer, and recoverInlineChatPaintFailure
                    // slams the panel closed. Reserve at least 4 rows
                    // above the panel for the shell prompt + breathing
                    // room; fall back to a permissive cap when the
                    // terminal geometry hasn't been populated yet
                    // (test fixtures, pre-first-resize state).
                    const max_panel: u16 = blk: {
                        // Fall through to the original permissive cap
                        // when terminal geometry hasn't been populated
                        // (test fixtures, pre-first-resize state). The
                        // clamp at proxy.zig's `applyReserveRows` is the
                        // safety net in those modes.
                        const t_rows = ctx.terminal_rows orelse 0;
                        const base = ctx.statusbar_base_reserve orelse 0;
                        const headroom: u16 = 4;
                        if (t_rows == 0 or t_rows <= base + headroom + cfg.inline_chat_top_gap) {
                            break :blk std.math.maxInt(u16) / 4;
                        }
                        break :blk t_rows - base - headroom - cfg.inline_chat_top_gap;
                    };
                    const next: u16 = switch (action) {
                        .llm_chat_inline_grow => if (current < max_panel) current + 1 else current,
                        .llm_chat_inline_shrink => if (current > 3) current - 1 else current,
                        else => unreachable,
                    };
                    if (next != current) {
                        rt.chat_inline_rows_override = next;
                        rt.chat_inline_paint_pending = true;
                    }
                    return true;
                },
                .llm_exec_cancel => {
                    // Only claim consumed when there's actual
                    // state to clear — otherwise the user's
                    // Ctrl+Shift+X bytes flow through to any
                    // inner program (vim / emacs / less) that
                    // might bind them. Without this gate every
                    // stray Ctrl+Shift+X in a normal shell got
                    // eaten by atty.
                    const dialog_active = rt.dialog_state != .idle;
                    const mode_active = rt.dialog_persistent_mode != .off;
                    const had_work = rt.in_flight or rt.ai_mode_active or rt.pending_injection_len > 0 or dialog_active or mode_active;
                    if (!had_work) return false;

                    // Dialog cancel funnels through dialogReset
                    // which handles the req_gen bump + turn
                    // cleanup + state machine reset. Always wipe
                    // the prompt — the suggested command (or
                    // `#: …` prefix) is typically visible.
                    dialogReset(rt, ctx.io);
                    queueInjection(rt, "\x15");
                    // Reset line_state to match the post-Ctrl+U
                    // shell state. The injection wipes the shell's
                    // readline buffer but `applyInput` doesn't see
                    // it (injections flow atty→shell, while
                    // line_state observes shell→user / user→shell);
                    // without this reset, line_state would keep the
                    // pre-cancel `#: …` prefix and the next Enter
                    // would re-fire the legacy single-shot
                    // trigger in `onInput`.
                    ctx.line.reset();
                    rt.ai_mode_active = false;
                    // Also exit persistent dialog/auto mode if active
                    // — the user wants out of the whole flow, not
                    // just the in-flight request.
                    rt.dialog_persistent_mode = .off;
                    rt.auto_mode_active = false;
                    return true;
                },
                else => return false, // not our action
            }
        }

        /// Trigger source — affects whether we return `.replace_commit`
        /// (the legacy `#:<Enter>` path) or queue the Ctrl+U on
        /// `pending_injection` (the `Alt+A` action path, which has no
        /// return-value channel to the proxy).
        const TriggerKind = enum { replace_commit_on_enter, queue_pending_injection };

        fn triggerSinglePrompt(
            rt: *Runtime,
            ctx: *m.Context,
            line: []const u8,
            kind: TriggerKind,
        ) m.Action {
            const body = std.mem.trim(u8, line[cfg.prefix.len..], " \t");
            if (body.len == 0 or body.len > cfg.max_prompt_bytes) return .forward;
            if (rt.inert) {
                // Inert mode — the user has the module configured
                // but no endpoint resolved at attach time. Latch
                // the muted-red ⚠ error notification.
                latchErr(rt, inert_error_msg);
                return .forward;
            }

            // Stage the provider INDEX. Worker resolves the provider
            // via `resolveProvider(req_kind, cfg.providers, cfg.provider, idx)`.
            // Empty `cfg.providers` → sentinel; otherwise pass the
            // current index (defensive clamp on out-of-range —
            // shouldn't happen because Alt+M wraps).
            const idx_to_send: usize = if (cfg.providers.len == 0)
                std.math.maxInt(usize)
            else if (rt.current_provider_idx < cfg.providers.len)
                rt.current_provider_idx
            else
                0;

            // Hand the prompt to the worker. Same locking + req-gen
            // bump as before — see the original onInput comment for
            // the stale-response guard rationale.
            rt.shared.mutex.lockUncancelable(ctx.io);
            defer rt.shared.mutex.unlock(ctx.io);
            @memcpy(rt.shared.req_buf[0..body.len], body);
            rt.shared.req_len = body.len;
            rt.shared.current_provider_idx = idx_to_send;
            rt.shared.dispatch_mode = .single;
            rt.shared.req_kind = .single;
            rt.shared.req_pending = true;
            rt.shared.req_gen +%= 1;
            rt.shared.res_done = false;
            if (rt.shared.res_buf) |old| {
                rt.allocator.free(old);
                rt.shared.res_buf = null;
            }
            rt.shared.res_len = 0;
            // Single-mode is one-shot — never resume. Each `Alt+A`
            // gets a fresh CLI session. Otherwise unrelated
            // single-shots would thread into the same conversation
            // forever (no reset path exists for single mode).
            rt.shared.request_session_id_len = 0;
            rt.shared.cv.signal(ctx.io);
            rt.in_flight = true;

            switch (kind) {
                .replace_commit_on_enter => return .{ .replace_commit = "\x15" },
                .queue_pending_injection => {
                    // onAction can't return an Action that the
                    // proxy injects. Queue the Ctrl+U on
                    // `pending_injection` so the next
                    // pollShellInput tick (~50ms) surfaces it
                    // ahead of any LLM response. Same visible
                    // effect: line gets wiped, response gets
                    // injected when ready.
                    queueInjection(rt, "\x15");
                    return .forward;
                },
            }
        }

        /// OSC 133 output capture for dialog mode. Always feeds the
        /// per-runtime tracker (so `osc133_capture.active` is current
        /// the moment the user hits Alt+S); state transitions and
        /// byte capture only fire while a dialog is mid-execution.
        ///
        /// We use a SECOND osc133 instance independent of the proxy's
        /// global one because the proxy's tracker is consumed
        /// destructively by `drainEdges()` — sharing it would race
        /// the subprocess-stack consumer.
        pub fn onOutput(rt: *Runtime, ctx: *m.Context, output: []const u8) m.Error!void {
            _ = ctx;
            rt.osc133_capture.feed(output);
            const edges = rt.osc133_capture.drainEdges();

            // The inline panel's open flag is atty-side state; a
            // shell-emitted screen-clear wipes the visible area
            // without notifying us, so without this sync the next
            // Alt+C would toggle against state that doesn't match
            // what's on screen. The carry-buffer probe handles
            // clear sequences that split across adjacent PTY read
            // boundaries. The full overlay owns the alt-screen so
            // a primary-screen clear can't touch it.
            if (rt.chat_inline_open) {
                const carry_prefix = rt.clear_seq_carry[0..rt.clear_seq_carry_len];
                if (carry_prefix.len > 0) {
                    var probe: [12]u8 = undefined;
                    const head_len = @min(output.len, probe.len - carry_prefix.len);
                    @memcpy(probe[0..carry_prefix.len], carry_prefix);
                    @memcpy(probe[carry_prefix.len .. carry_prefix.len + head_len], output[0..head_len]);
                    if (containsClearSequence(probe[0 .. carry_prefix.len + head_len])) {
                        rt.chat_inline_open = false;
                        rt.chat_paste_active = false;
                    }
                }
                if (rt.chat_inline_open and containsClearSequence(output)) {
                    rt.chat_inline_open = false;
                    rt.chat_paste_active = false;
                }
                const tail_len: usize = @min(output.len, rt.clear_seq_carry.len);
                @memcpy(rt.clear_seq_carry[0..tail_len], output[output.len - tail_len ..]);
                rt.clear_seq_carry_len = @intCast(tail_len);
            }

            // Outside dialog execution, the only reason to feed was
            // to keep `active` tracking up to date. No state work
            // needed when we're idle/generating/suggesting (the
            // command hasn't run yet, so `;C` hasn't fired).
            const tracking = rt.dialog_state == .executing or rt.dialog_state == .capturing_output;
            if (!tracking) return;

            // `edgeOffset(i)` returns the byte index of the OSC
            // marker's LEADING ESC. So `output[cursor..offset]`
            // captures cleanly: everything BEFORE the marker is
            // command output; the marker bytes themselves never
            // enter the observation. After the edge fires we
            // advance `cursor` past the marker (we don't know the
            // exact terminator length here without re-parsing, so
            // we conservatively forward-scan to the first BEL or
            // ST tail and resume just past it).
            var cursor: u32 = 0;
            var capturing = rt.dialog_state == .capturing_output;
            for (edges, 0..) |edge, i| {
                const offset = rt.osc133_capture.edgeOffset(i);
                switch (edge) {
                    .cmd_start => {
                        // Stray `;C` mid-capture (no preceding `;D`):
                        // append the pre-marker bytes to the current
                        // observation BEFORE deciding the next state.
                        // We deliberately KEEP the in-progress
                        // observation across the stray marker rather
                        // than starting fresh — concatenated output is
                        // more useful to the LLM than a silently
                        // dropped half. The reset below is gated on
                        // `!capturing` for exactly this reason.
                        if (capturing and offset > cursor) {
                            appendCaptured(rt, output[cursor..@min(offset, output.len)]);
                        }
                        if (!capturing and rt.dialog_state == .executing) {
                            rt.dialog_state = .capturing_output;
                            rt.captured_output_len = 0;
                            rt.captured_truncated = false;
                            capturing = true;
                        }
                        cursor = advancePastMarker(output, offset);
                    },
                    .cmd_end, .prompt_start_implicit_end => {
                        if (capturing) {
                            if (offset > cursor) {
                                appendCaptured(rt, output[cursor..@min(offset, output.len)]);
                            }
                            capturing = false;
                            rt.dialog_state = .observation_ready;
                            // Firing the next request from onOutput
                            // would mean doing JSON serialization +
                            // mutex acquisition on the master-output
                            // hot path. Defer to `onTick` instead —
                            // ~50ms latency is fine for a dialog
                            // loop where the LLM round-trip is the
                            // dominant cost anyway.
                        }
                        // #167 — command finished, shell is back at
                        // a prompt. Refocus the chat panel if the
                        // exec arm armed the latch AND the panel
                        // is still open (user may have toggled
                        // Alt+C shut while the command was
                        // running). Arm `chat_inline_paint_pending`
                        // so paintInlineChat re-renders the cursor
                        // visibility (?25h/?25l) and panel dim
                        // state on the next tick — without it the
                        // UI mutates focus silently and the user
                        // sees a stale dimmed panel + invisible
                        // cursor location.
                        if (rt.chat_refocus_pending) {
                            if (rt.chat_inline_open) {
                                rt.chat_focus_in_panel = true;
                                rt.chat_inline_paint_pending = true;
                                // #303 — invalidate the cached prompt-row
                                // snapshot. The command just ran, output
                                // scrolled the shell prompt down by N rows;
                                // the next paint must re-capture from the
                                // current `ctx.cursor_row/col` instead of
                                // CUP-ing back to the stale pre-exec row
                                // (which would land the next insertion on
                                // top of the previous output).
                                rt.chat_open_cursor_row = 0;
                                rt.chat_open_cursor_col = 0;
                            }
                            rt.chat_refocus_pending = false;
                        }
                        cursor = advancePastMarker(output, offset);
                    },
                }
            }
            if (capturing and cursor < output.len) {
                appendCaptured(rt, output[cursor..]);
            }
        }

        /// `.observation_ready` → `.generating` transition. Triggered
        /// here (not in onOutput) so the JSON serialization and
        /// mutex acquisition stay off the master-output hot path.
        pub fn onTick(rt: *Runtime, ctx: *m.Context, elapsed_ms: u64) m.Error!void {
            _ = elapsed_ms;

            // Auto-exec: fire \r after the configured delay if
            // the user hasn't pressed any key (onInput would've
            // cleared `auto_exec_armed`). One-shot — clear the
            // flag once we enqueue the Enter so we don't re-fire
            // on the next tick.
            //
            // The injection path in proxy.zig bypasses
            // dispatchLineCommit (only stdin keystrokes pump that
            // pipeline), so the `.suggesting → .executing`
            // transition that onLineCommit would normally run
            // gets done here directly — otherwise capturing of
            // the upcoming `;C`/`;D` edges would never start and
            // the dialog would stall in .suggesting.
            if (rt.auto_exec_armed and rt.dialog_state == .suggesting) {
                const elapsed: i64 = nowMs() - rt.auto_exec_t0_ms;
                if (elapsed >= @as(i64, @intCast(cfg.auto_delay_ms))) {
                    rt.auto_exec_armed = false;
                    queueInjection(rt, "\r");
                    rt.dialog_state = .executing;
                }
            }

            if (rt.dialog_state != .observation_ready) return;

            // Push the observation as a turn, build the next
            // request, signal the worker. Any allocation failure
            // here aborts the dialog cleanly — we latch an error
            // and reset to idle so the user isn't stuck in a
            // half-state.
            const observation_slice = if (rt.captured_truncated)
                std.fmt.allocPrint(
                    rt.allocator,
                    "{s}\n[truncated — output exceeded {d} bytes]",
                    .{ rt.captured_output[0..rt.captured_output_len], cfg.captured_output_bytes },
                ) catch {
                    abortDialog(rt, ctx.io, "out of memory building observation");
                    return;
                }
            else
                rt.allocator.dupe(u8, rt.captured_output[0..rt.captured_output_len]) catch {
                    abortDialog(rt, ctx.io, "out of memory building observation");
                    return;
                };

            pushTurn(rt, ctx, .observation, observation_slice) catch {
                rt.allocator.free(observation_slice);
                abortDialog(rt, ctx.io, "out of memory recording observation");
                return;
            };
            rt.captured_output_len = 0;
            rt.captured_truncated = false;

            fireDialogRequest(rt, ctx) catch |err| {
                abortDialog(rt, ctx.io, switch (err) {
                    error.BodyTooLarge => "context too large — cancel and start a new task",
                    error.OutOfMemory => "out of memory firing follow-up request",
                    else => "internal error firing follow-up request",
                });
            };
        }

        /// Enter-key transition for dialog mode: while in
        /// `.suggesting`, the user just confirmed the suggested
        /// command — move to `.executing` so `onOutput` knows to
        /// start capturing when `;C` fires.
        ///
        /// Gated on a non-empty committed line: if the user
        /// deleted the suggestion before pressing Enter (or
        /// committed a blank line for any other reason), we'd
        /// otherwise eagerly capture the NEXT command's output as
        /// a stale observation. The reset is safer — the dialog
        /// returns to `.idle` (via dialogReset) and the user can
        /// retry from a clean state.
        pub fn onLineCommit(rt: *Runtime, ctx: *m.Context, line: []const u8) m.Error!void {
            // Question-answer path: the user typed a free-form
            // reply to the LLM's question. onInput already returned
            // `.replace_commit = "\x15"`, so bash receives Ctrl+U
            // (kills the buffer) instead of Enter — no command
            // runs. We just push the answer as the next `.user`
            // turn and fire the follow-up request.
            if (rt.dialog_state == .awaiting_question_answer) {
                const trimmed = std.mem.trim(u8, line, " \t");
                if (trimmed.len == 0) {
                    latchHint(rt, "empty answer — dialog cancelled");
                    dialogReset(rt, ctx.io);
                    rt.ai_mode_active = false;
                    return;
                }
                const answer = rt.allocator.dupe(u8, trimmed) catch {
                    abortDialog(rt, ctx.io, "out of memory recording answer");
                    return;
                };
                pushTurn(rt, ctx, .user, answer) catch {
                    rt.allocator.free(answer);
                    abortDialog(rt, ctx.io, "out of memory recording answer");
                    return;
                };
                fireDialogRequest(rt, ctx) catch |err| {
                    abortDialog(rt, ctx.io, switch (err) {
                        error.BodyTooLarge => "context too large — cancel and start a new task",
                        error.OutOfMemory => "out of memory firing follow-up request",
                        else => "internal error firing follow-up request",
                    });
                };
                return;
            }

            if (rt.dialog_state != .suggesting) return;
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) {
                latchHint(rt, "empty command — dialog cancelled, retry from scratch");
                dialogReset(rt, ctx.io);
                rt.ai_mode_active = false;
                return;
            }
            rt.dialog_state = .executing;
        }

        pub fn pollShellInput(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
            // Drain `pending_injection` ahead of the worker's
            // response. Used by the `onAction` path (Alt+A) to
            // route `\x15` (Ctrl+U) to the pty so the typed
            // `#: …` is wiped — onAction has no return-value
            // channel to the proxy. One-shot; cleared on read.
            if (rt.pending_injection_len > 0) {
                const n = rt.pending_injection_len;
                @memcpy(rt.inject_buf[0..n], rt.pending_injection[0..n]);
                rt.inject_len = n;
                rt.pending_injection_len = 0;
                return rt.inject_buf[0..n];
            }

            // Inner scope so the mutex is released BEFORE we run
            // the dialog-response handler, which may re-acquire
            // the mutex in `fireDialogRequest`.
            var res_kind: RequestKind = .single;
            var n: usize = 0;
            {
                rt.shared.mutex.lockUncancelable(ctx.io);
                defer rt.shared.mutex.unlock(ctx.io);
                if (!rt.shared.res_done) return null;
                // Drop responses from a stale generation — a newer
                // prompt has already been submitted; the worker's
                // reply for THAT one is still pending. Keep
                // `in_flight = true` because the user IS waiting on
                // the newer request; clearing it would prematurely
                // remove the 🧠 thinking… status.
                if (rt.shared.res_gen != rt.shared.req_gen) {
                    rt.shared.res_done = false;
                    if (rt.shared.res_buf) |old| {
                        rt.allocator.free(old);
                        rt.shared.res_buf = null;
                    }
                    rt.shared.res_len = 0;
                    rt.shared.explanation_len = 0;
                    rt.shared.error_len = 0;
                    // Stale responses must also drop a captured
                    // session id — otherwise a later non-stale
                    // response that lacks an init event would leave
                    // the stale id in `response_session_id_buf` and
                    // `captureSessionId` would pick it up on the
                    // next pollShellInput.
                    rt.shared.response_session_id_len = 0;
                    return null;
                }
                res_kind = rt.shared.res_kind;
                n = rt.shared.res_len;
                if (rt.shared.res_buf) |slice| {
                    const copy_n = @min(n, rt.inject_buf.len);
                    @memcpy(rt.inject_buf[0..copy_n], slice[0..copy_n]);
                    rt.inject_len = copy_n;
                    n = copy_n;
                    rt.allocator.free(slice);
                    rt.shared.res_buf = null;
                } else {
                    rt.inject_len = 0;
                    n = 0;
                }

                // Capture the CLI's session id (dialog mode only —
                // single-mode is one-shot and intentionally
                // discards any captured id). Subsequent dialog
                // turns inject it via the configured `--resume
                // <id>`-shaped argv slot.
                if (rt.shared.res_kind == .dialog) {
                    captureSessionId(rt);
                } else {
                    // Drain the slot so a future dialog request
                    // doesn't pick up a stale single-mode id.
                    rt.shared.response_session_id_len = 0;
                }

                // Latch the explanation (single mode only). Dialog
                // responses never populate `explanation_buf` — the
                // worker leaves `explanation_len = 0` for dialog
                // kind because the JSON envelope's `description`
                // field is surfaced later (inside
                // `handleDialogResponse` via `latchHint`). The
                // shared `explanation_buf` is therefore dead weight
                // on the dialog path; kept around so single-mode
                // doesn't have to branch.
                const exp_n = rt.shared.explanation_len;
                if (n > 0 and exp_n > 0) {
                    @memcpy(rt.hint_buf[0..exp_n], rt.shared.explanation_buf[0..exp_n]);
                    rt.hint_len = exp_n;
                    rt.hint_pending = true;
                }

                // Failure path: nothing to inject, but the worker
                // may have latched a diagnostic. Surface it via the
                // *error* slot (not the hint slot) so it renders
                // in muted red with the ⚠ glyph.
                const err_n = rt.shared.error_len;
                if (n == 0 and err_n > 0) {
                    const copy_n = @min(err_n, rt.err_buf.len);
                    @memcpy(rt.err_buf[0..copy_n], rt.shared.error_buf[0..copy_n]);
                    rt.err_len = copy_n;
                    rt.err_pending = true;
                }

                rt.shared.res_done = false;
                rt.shared.res_len = 0;
                rt.shared.explanation_len = 0;
                rt.shared.error_len = 0;
            }
            rt.in_flight = false;

            // Dialog mode: parse the JSON envelope on the main
            // thread (where the runtime + state machine live) and
            // act on the LLM's instruction. Returns the bytes to
            // inject (the suggested command for `action=exec`) or
            // null for done/error/question paths.
            //
            // The `inject_buf` was populated with the raw JSON
            // envelope above by the shared-state copy — that's
            // the wrong thing to expose if any downstream caller
            // reads `rt.inject_buf[0..rt.inject_len]` directly
            // assuming it holds the next-injection bytes. Zero
            // `inject_len` now so any such stale read sees an
            // empty slice instead of JSON; the returned slice
            // from `handleDialogResponse` is the authoritative
            // injection payload for dialog mode.
            if (res_kind == .dialog) {
                rt.inject_len = 0;
                return try handleDialogResponse(rt, ctx, n);
            }

            // Single mode: n == 0 → worker signalled failure
            // (network error, non-2xx, parse failure). Nothing to
            // inject; the statusbar already cleared via
            // `in_flight = false`. The error hint above is what
            // the user will see.
            if (n == 0) return null;
            // Stage the line's author for the next submit() so
            // downstream consumers (atuin's --author tag,
            // guardrail's author-aware rules) see `.llm` instead
            // of the default `.user`. The flag persists in
            // line_state until submit() snapshots it; backspace /
            // killLine / killWord that empty the buffer reset it,
            // so a user who wipes and retypes still commits as
            // `.user`.
            ctx.line.setCommitAuthor(.llm);
            return rt.inject_buf[0..rt.inject_len];
        }

        /// Process a parsed dialog response. Branches by `action`:
        /// `exec` injects the command + transitions to `.suggesting`
        /// (description goes to the hint row, auto-exec arms if
        /// the user picked Alt+Shift+S); `done` clears state and
        /// latches a confirmation; `question` latches the prompt
        /// text and transitions to `.awaiting_question_answer` so
        /// the next typed line becomes the next `.user` turn (see
        /// onInput's `.replace_commit` redirect that keeps bash
        /// from executing the answer). Returns bytes to inject —
        /// for `exec` that's the command; for done/question/error
        /// it's null.
        fn handleDialogResponse(rt: *Runtime, ctx: *m.Context, n: usize) m.Error!?[]const u8 {
            if (n == 0) {
                // Worker reported failure; the error slot already
                // has the diagnostic. End the dialog cleanly.
                dialogReset(rt, ctx.io);
                rt.ai_mode_active = false;
                queueInjection(rt, "\x15");
                return null;
            }

            const raw = rt.inject_buf[0..n];

            var parsed: DialogResponse = .{};
            parseDialogResponse(rt.allocator, raw, &parsed) catch {
                // Self-correction loop — give the model a chance to
                // re-emit a valid JSON envelope. Cap at
                // `cfg.dialog_parse_retry_max` so a model that
                // refuses the format can't trap the loop. The
                // bad reply itself is pushed as the assistant turn
                // (so the model sees its own output), then a user
                // turn explains the parse failure in concrete
                // terms ("you replied X, here's what was wrong,
                // please re-emit JSON exactly like this …").
                if (rt.dialog_parse_retry_count < cfg.dialog_parse_retry_max) {
                    rt.dialog_parse_retry_count += 1;
                    requestParseRetry(rt, ctx, raw, "wasn't valid JSON") catch {
                        latchErr(rt, "LLM reply wasn't valid JSON — cancel and retry");
                        dialogReset(rt, ctx.io);
                        rt.ai_mode_active = false;
                        queueInjection(rt, "\x15");
                    };
                    return null;
                }
                latchErr(rt, "LLM reply wasn't valid JSON (gave up after retries) — cancel and re-prompt");
                dialogReset(rt, ctx.io);
                rt.ai_mode_active = false;
                queueInjection(rt, "\x15");
                return null;
            };
            // Successful parse — reset the retry counter so any
            // future malformed reply within this dialog gets the
            // full retry budget again.
            rt.dialog_parse_retry_count = 0;

            switch (parsed.action) {
                .exec => {
                    if (parsed.command_len == 0) {
                        // Same retry budget as the JSON-parse-fail
                        // path — an action=exec without a `command`
                        // field is a model error of the same shape
                        // (envelope is technically valid JSON but
                        // doesn't satisfy our protocol contract).
                        if (rt.dialog_parse_retry_count < cfg.dialog_parse_retry_max) {
                            rt.dialog_parse_retry_count += 1;
                            requestParseRetry(rt, ctx, raw, "had action=exec but no command field") catch {
                                latchErr(rt, "LLM reply had no command — cancel and retry");
                                dialogReset(rt, ctx.io);
                                rt.ai_mode_active = false;
                                queueInjection(rt, "\x15");
                            };
                            return null;
                        }
                        latchErr(rt, "LLM reply had no command (gave up after retries) — cancel and re-prompt");
                        dialogReset(rt, ctx.io);
                        rt.ai_mode_active = false;
                        queueInjection(rt, "\x15");
                        return null;
                    }
                    // Echo the assistant's JSON back to the model
                    // on the next turn so the conversation stays
                    // coherent.
                    const assistant_copy = rt.allocator.dupe(u8, raw) catch {
                        abortDialog(rt, ctx.io, "out of memory continuing dialog");
                        return null;
                    };
                    pushTurn(rt, ctx, .assistant_exec, assistant_copy) catch {
                        rt.allocator.free(assistant_copy);
                        abortDialog(rt, ctx.io, "out of memory continuing dialog");
                        return null;
                    };

                    // Stage the command for injection. Cap +
                    // copy in case the LLM's command exceeds
                    // `cfg.max_response_bytes` (shouldn't — the
                    // command field is bounded at parse time —
                    // but defensive).
                    const cmd = parsed.command();
                    const cmd_n = @min(cmd.len, rt.pending_command.len);
                    @memcpy(rt.pending_command[0..cmd_n], cmd[0..cmd_n]);
                    rt.pending_command_len = cmd_n;

                    if (parsed.description_len > 0) {
                        const desc = parsed.description();
                        const desc_n = @min(desc.len, rt.pending_description.len);
                        @memcpy(rt.pending_description[0..desc_n], desc[0..desc_n]);
                        rt.pending_description_len = desc_n;
                        latchHint(rt, desc);
                    }

                    rt.dialog_state = .suggesting;
                    // Same author-staging contract as single mode —
                    // see the matching call in `pollShellInput`.
                    ctx.line.setCommitAuthor(.llm);
                    // Stage the LLM's description as the intent so
                    // downstream modules (atuin's `--intent` flag)
                    // can persist "user asked for X" alongside the
                    // command in history. Empty when the LLM didn't
                    // emit a description (already handled by
                    // line_state's len==0 short-circuit on read).
                    if (rt.pending_description_len > 0) {
                        ctx.line.setCommitIntent(rt.pending_description[0..rt.pending_description_len]);
                    }
                    // Arm the auto-submit timer if we're in
                    // auto-exec mode (Alt+Shift+S). onTick fires
                    // the Enter after cfg.auto_delay_ms; any user
                    // keystroke (via onInput) disarms it.
                    if (rt.auto_mode_active) {
                        rt.auto_exec_armed = true;
                        rt.auto_exec_t0_ms = nowMs();
                    } else if (rt.chat_inline_open and cfg.inline_chat_autofocus_on_exec) {
                        // #167 — defocus the inline chat panel so
                        // the next keystroke (Enter) runs the
                        // injected command without an Alt+C toggle
                        // dance. Refocus latches on the next
                        // OSC 133 `;A`/`;D` edge. Skipped in
                        // auto-mode (auto-mode runs the Enter
                        // itself). Arm `chat_inline_paint_pending`
                        // so paintInlineChat re-renders the
                        // dimmed/undimmed panel + cursor
                        // visibility on the next tick.
                        rt.chat_focus_in_panel = false;
                        rt.chat_refocus_pending = true;
                        rt.chat_inline_paint_pending = true;
                    }
                    // Return the command bytes for injection at
                    // the shell prompt — directly from
                    // `pending_command` so the buffer's role stays
                    // obvious (no second purpose-shifted reuse of
                    // `inject_buf`, which the single-mode path
                    // owns with different lifetime semantics).
                    return rt.pending_command[0..rt.pending_command_len];
                },
                .done => {
                    // Chat mode: `done` from the LLM means "I've
                    // said what I want to say." It's a turn, not a
                    // conversation-end. Push the reason as an
                    // assistant turn so the user sees the reply in
                    // the chat scrollback, arm the paint latch, and
                    // leave the surface open — the user closes the
                    // panel themselves via Alt+C / Alt+Shift+C.
                    // Suppresses the inline conclusion banner (the
                    // panel IS the UI) and skips dialogReset (chat
                    // is open-ended; future replies stay coherent).
                    if (rt.chat_inline_open or rt.chat_overlay_open) {
                        const reason = parsed.reason();
                        if (reason.len > 0) {
                            const reason_copy = rt.allocator.dupe(u8, reason) catch {
                                latchErr(rt, "out of memory pushing chat reply");
                                return null;
                            };
                            pushTurn(rt, ctx, .assistant_exec, reason_copy) catch {
                                rt.allocator.free(reason_copy);
                                latchErr(rt, "out of memory pushing chat reply");
                                return null;
                            };
                        }
                        if (rt.chat_inline_open) rt.chat_inline_paint_pending = true;
                        if (rt.chat_overlay_open) rt.chat_overlay_paint_pending = true;
                        // Stay in chat-active state; next user turn
                        // fires another dialog request.
                        rt.dialog_state = .idle;
                        return null;
                    }
                    // Tally the conversation so the user gets a
                    // glance-able summary of what just happened —
                    // useful both for the loop they just exited
                    // AND as a quick sanity check ("did the model
                    // really execute 12 commands or am I
                    // misremembering?"). Counts are pre-reset
                    // since `dialogReset` below clears `turns_len`.
                    var exec_count: usize = 0;
                    var observation_count: usize = 0;
                    var user_count: usize = 0;
                    for (rt.turns[0..rt.turns_len]) |t| switch (t.kind) {
                        .assistant_exec => exec_count += 1,
                        .observation => observation_count += 1,
                        .user => user_count += 1,
                    };
                    // Sized for: "✓ done — " (~12) + reason (≤256) +
                    // " · N execs / N obs / N turns" (~40). 384B
                    // leaves comfortable headroom for the formatted
                    // suffix even at max reason length.
                    var msg_buf: [384]u8 = undefined;
                    const reason = parsed.reason();
                    const msg = if (reason.len > 0)
                        std.fmt.bufPrint(&msg_buf, "✓ done — {s} · {d} execs / {d} obs / {d} turns", .{ reason, exec_count, observation_count, user_count }) catch
                            (std.fmt.bufPrint(&msg_buf, "✓ done — {s}", .{reason}) catch "✓ done")
                    else
                        std.fmt.bufPrint(&msg_buf, "✓ done · {d} execs / {d} obs / {d} turns", .{ exec_count, observation_count, user_count }) catch "✓ done";
                    latchHint(rt, msg);
                    // Capture the conclusion banner BEFORE dialogReset
                    // wipes `turns_len`. Banner is multi-line ANSI
                    // text suitable for inline emission via
                    // `provideTermBytes` — scrolls into the
                    // shell's normal history above the next prompt,
                    // re-emittable via Alt+Shift+C
                    // (`llm_chat_overlay_toggle`). See `captureConclusion`.
                    captureConclusion(rt, reason, exec_count, observation_count, user_count);
                    // Order matters: dialogReset clears the pending
                    // flag (so a cancel between a stale `.done` and
                    // the next term-bytes tick doesn't fire the
                    // banner spuriously). Arm AFTER the reset.
                    dialogReset(rt, ctx.io);
                    rt.conclusion_pending = true;
                    rt.ai_mode_active = false;
                    // LLM signalling done also deactivates the
                    // persistent mode — user can re-enter via
                    // Alt+S / Alt+Shift+S if they want another
                    // session.
                    rt.dialog_persistent_mode = .off;
                    rt.auto_mode_active = false;
                    // `open_chat` advisory flag — model is hinting
                    // that the user would benefit from following up
                    // in the chat overlay. Honoured per
                    // `cfg.overlay_open_policy`:
                    //   .always → auto-open the overlay (paint will
                    //     pick up the just-captured conclusion as
                    //     content via the conclusion-fallback path)
                    //   .notify → latch a hint so the user can
                    //     decide whether to press Alt+Shift+C
                    //   .never → ignore the flag
                    // The conclusion banner still scrolls into
                    // shell history (conclusion_pending stays
                    // armed) regardless of policy — the overlay
                    // open is additive, not replacement.
                    if (parsed.open_chat) {
                        switch (cfg.overlay_open_policy) {
                            .always => {
                                // Refuse `.always` when the overlay
                                // would open empty — `dialogReset`
                                // wiped the turn ring and an empty
                                // reason leaves `conclusion_formatted`
                                // null. Better to surface the notify-
                                // shape hint than open an overlay
                                // saying "no conversation yet".
                                if (rt.conclusion_formatted != null) {
                                    rt.chat_overlay_open = true;
                                    rt.chat_overlay_paint_pending = true;
                                    // Suppress the inline banner
                                    // emission — overlay renders the
                                    // conclusion as content; double-
                                    // emitting would scroll the same
                                    // banner into history under the
                                    // open overlay.
                                    rt.conclusion_pending = false;
                                } else {
                                    latchHint(rt, "✨ LLM done — Alt+Shift+C to open chat");
                                }
                            },
                            .notify => {
                                latchHint(rt, "✨ LLM suggests follow-up — Alt+Shift+C to open chat");
                            },
                            .never => {},
                        }
                    }
                    return null;
                },
                .question => {
                    // Latch the prompt so the user sees what's
                    // being asked, transition to a wait state, and
                    // surface AI mode so the user's free-form reply
                    // becomes the next `.user` turn (via
                    // onLineCommit / fireDialogRequest). Auto-exec
                    // disarms — the answer is the user's, not the
                    // LLM's, so no auto-submit timer.
                    //
                    // ALSO push the assistant turn so the question
                    // appears in chat-mode scrollback (Alt+C / Alt+Shift+C)
                    // — not just as a transient hint at the bottom.
                    // Falling back to "atty asked a question" when
                    // dupe OOMs keeps the chat-scrollback story
                    // intact without abort-on-OOM.
                    if (rt.allocator.dupe(u8, raw)) |copy| {
                        pushTurn(rt, ctx, .assistant_exec, copy) catch rt.allocator.free(copy);
                    } else |_| {}
                    const q = parsed.question();
                    // Multi-choice: copy choices into Runtime-
                    // owned storage so they outlive `parsed`. The
                    // `provideGhostList` hook reads from here when
                    // the state machine is awaiting an answer.
                    rt.question_choices_count = parsed.choices_count;
                    for (0..parsed.choices_count) |i| {
                        const choice = parsed.choice(i);
                        const copy_len = @min(choice.len, rt.question_choices_storage[i].len);
                        @memcpy(rt.question_choices_storage[i][0..copy_len], choice[0..copy_len]);
                        rt.question_choices_lens[i] = copy_len;
                    }
                    // Chat-mode question pick-list (#214): if either
                    // chat surface is open at the time the question
                    // arrives, latch the pick-list UI state. The
                    // paint hook renders an arrow-key-navigable list
                    // of choices + a free-text input row.
                    if ((rt.chat_inline_open or rt.chat_overlay_open) and parsed.choices_count > 0) {
                        rt.chat_question_active = true;
                        rt.chat_question_choice_count = @intCast(parsed.choices_count);
                        rt.chat_question_selected_idx = 0;
                        rt.chat_question_turn_idx = if (rt.turns_len > 0) rt.turns_len - 1 else 0;
                        if (rt.chat_inline_open) rt.chat_inline_paint_pending = true;
                        if (rt.chat_overlay_open) rt.chat_overlay_paint_pending = true;
                    }
                    if (q.len > 0) {
                        // When choices are present, append a
                        // discoverable footer hint so users know
                        // they can use Ctrl+1..9 to pick.
                        if (parsed.choices_count > 0) {
                            var msg_buf: [512]u8 = undefined;
                            const msg = std.fmt.bufPrint(&msg_buf, "{s} — Ctrl+1..{d} to pick, or type", .{ q, parsed.choices_count }) catch q;
                            latchHint(rt, msg);
                        } else {
                            latchHint(rt, q);
                        }
                    } else {
                        latchHint(rt, "LLM asked a question without text — answer or cancel.");
                    }
                    rt.dialog_state = .awaiting_question_answer;
                    rt.auto_exec_armed = false;
                    rt.ai_mode_active = true;
                    // `open_chat` advisory flag on .question: the
                    // overlay's chat input is a better surface for
                    // free-form answers than the shell prompt — same
                    // policy semantics as the .done arm. With
                    // `.always`, auto-open so the user can type the
                    // answer in the overlay (the next Enter there
                    // fires fireDialogRequest with the typed text
                    // as the next .user turn — same path as the
                    // shell prompt's onLineCommit).
                    if (parsed.open_chat) {
                        switch (cfg.overlay_open_policy) {
                            .always => {
                                rt.chat_overlay_open = true;
                                rt.chat_overlay_paint_pending = true;
                            },
                            .notify => {
                                latchHint(rt, "✨ LLM suggests overlay for this answer — Alt+Shift+C to open chat");
                            },
                            .never => {},
                        }
                    }
                    return null;
                },
            }
        }

        /// Latch the OSC-133-gate diagnostic error. Surfaces the
        /// cumulative byte-feed + dispatch counts so the user can
        /// tell at a glance WHY the gate is closed:
        ///
        ///   - `bytes=0` → atty's `onOutput` was never called. The
        ///     LLM module isn't seeing shell output at all (very
        ///     unlikely — would mean a broken dispatcher wiring).
        ///   - `bytes>0 dispatches=0` → shell IS emitting output but
        ///     no OSC 133 markers among it. Either the init snippet
        ///     never ran, the user's .bashrc overwrote
        ///     `PROMPT_COMMAND` after the eval, or the user is in a
        ///     shell other than bash with the bash init.
        ///   - `bytes>0 dispatches>0 but active=false` → impossible
        ///     by construction (dispatchOsc sets active before
        ///     incrementing the counter); kept defensively in case
        ///     the parser ever changes shape.
        /// Copy `rt.session_id` into the worker's `request_session_id`
        /// slot under the assumed-held `rt.shared.mutex`. Caller
        /// must already hold the lock; this just does the buffer
        /// copy + length write.
        /// Map the user's CURRENT runtime state to a dispatch
        /// `Mode`. Used by Alt+M cycle + the help overlay to pick
        /// the right provider entry from `cfg.providers[]`.
        fn currentDispatchMode(rt: *Runtime) types.Mode {
            // Chat surface open → the LLM dispatches as a regular
            // dialog (with `auto` toggling the auto-exec sub-flavour).
            // The standalone `.chat` mode is reserved for non-chat
            // prose-only flows that don't take any LLM action; the
            // chat panel itself is a richer surface that benefits
            // from the full exec/question/done vocabulary.
            if (rt.chat_inline_open or rt.chat_overlay_open) {
                return if (rt.auto_mode_active) .auto else .dialog;
            }
            if (rt.auto_mode_active or rt.dialog_persistent_mode == .auto) return .auto;
            if (rt.dialog_persistent_mode == .dialog or rt.dialog_state != .idle) return .dialog;
            return .single;
        }

        /// Re-export `worker_mod_ns.providerLabel` so the
        /// statusbar / Alt+M code below reads as a local function.
        const providerLabel = worker_mod_ns.providerLabel;

        fn publishSessionId(rt: *Runtime) void {
            if (rt.session_id.len == 0) {
                rt.shared.request_session_id_len = 0;
                return;
            }
            const n = @min(rt.session_id.len, rt.shared.request_session_id_buf.len);
            @memcpy(rt.shared.request_session_id_buf[0..n], rt.session_id[0..n]);
            rt.shared.request_session_id_len = n;
        }

        /// Read the worker's `response_session_id` slot under the
        /// assumed-held `rt.shared.mutex` and copy a fresh id into
        /// `rt.session_id`. Caller holds the lock. Owned allocation
        /// — frees any previous id before replacing. Zeros the
        /// shared slot after consuming so subsequent
        /// no-init-event responses don't re-pull the same id.
        fn captureSessionId(rt: *Runtime) void {
            const len = rt.shared.response_session_id_len;
            if (len == 0) return;
            defer rt.shared.response_session_id_len = 0;
            if (rt.session_id.len == len and std.mem.eql(u8, rt.session_id, rt.shared.response_session_id_buf[0..len])) return;
            const owned = rt.allocator.dupe(u8, rt.shared.response_session_id_buf[0..len]) catch return;
            if (rt.session_id.len > 0) rt.allocator.free(rt.session_id);
            rt.session_id = owned;
        }

        fn latchOsc133Diag(rt: *Runtime) void {
            const fed = rt.osc133_capture.total_bytes_fed;
            const dispatches = rt.osc133_capture.total_dispatches;
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "exec mode needs OSC 133 (bytes={d} dispatches={d}) — run `eval \"$(atty init bash)\"` or use Alt+A",
                .{ fed, dispatches },
            ) catch "exec mode needs OSC 133 — run `eval \"$(atty init bash)\"` or use Alt+A";
            latchErr(rt, msg);
        }

        /// Same effect as `startDialog`, but returns `m.Action` so
        /// the `onInput` Enter branch can wipe the prompt via
        /// `.replace_commit = "\x15"` (the shell never sees the
        /// Enter or the `#: …` text). Returns `.forward` for the
        /// gate-failed cases — the gate failures latch a hint or
        /// error notification, so the user still gets feedback, but
        /// the Enter falls through to bash which treats `#: …` as a
        /// comment (no-op). Mirrors `startDialog` byte-for-byte
        /// except for the replace-via-Enter wiring at the success
        /// site.
        fn startDialogViaEnter(rt: *Runtime, ctx: *m.Context, auto: bool) m.Action {
            if (!rt.ai_mode_active) return .forward;
            const line = ctx.line.current();
            const body = std.mem.trim(u8, line[cfg.prefix.len..], " \t");
            if (body.len == 0) {
                // Both auto and non-auto Enter submission share the
                // same instructional hint — the trigger key is Enter
                // in either mode.
                latchHint(rt, "type your task after `#: ` then press Enter");
                return .forward;
            }
            if (body.len > cfg.max_prompt_bytes) {
                latchHint(rt, "prompt too long — shorten the task and try again");
                return .forward;
            }
            if (rt.inert) {
                latchErr(rt, inert_error_msg);
                return .forward;
            }
            if (!rt.osc133_capture.active) {
                latchOsc133Diag(rt);
                return .forward;
            }
            const initial = rt.allocator.dupe(u8, body) catch {
                latchErr(rt, "out of memory starting dialog");
                return .forward;
            };
            pushTurn(rt, ctx, .user, initial) catch {
                rt.allocator.free(initial);
                latchErr(rt, "out of memory starting dialog");
                return .forward;
            };
            rt.auto_mode_active = auto;
            fireDialogRequest(rt, ctx) catch |err| {
                abortDialog(rt, ctx.io, switch (err) {
                    error.BodyTooLarge => "dialog body too large for buffer — increase Config.body_buf_bytes",
                    error.OutOfMemory => "out of memory firing dialog request",
                    else => "internal error firing dialog request",
                });
                return .forward;
            };
            rt.ai_mode_active = false;
            return .{ .replace_commit = "\x15" };
        }

        /// Toggle persistent dialog/auto mode.
        ///
        ///   - off → target mode: activate. If `ai_mode_active`
        ///     (user typed `#: …`), ALSO fire the initial dialog
        ///     request immediately so the first prompt round-trips.
        ///   - same as target mode: deactivate. Clear mode flag
        ///     and reset any in-flight dialog state.
        ///   - other mode → target mode: switch. Update mode flag
        ///     without disrupting an in-flight cycle (so the user
        ///     can switch from dialog ↔ auto mid-loop without
        ///     losing context — the next `.exec` step will respect
        ///     the new mode's auto-submit setting).
        ///
        /// Returns true always (action consumed — the user will see
        /// the statusbar / cursor indicator flip even if no
        /// request fires).
        fn toggleDialogMode(rt: *Runtime, ctx: *m.Context, target: @TypeOf(rt.dialog_persistent_mode)) bool {
            const current = rt.dialog_persistent_mode;
            if (current == target) {
                // Deactivate: clear mode + reset any in-flight
                // state. Uses the same path as `llm_exec_cancel` so
                // the worker's req_gen bumps + turn cleanup happen
                // consistently.
                rt.dialog_persistent_mode = .off;
                rt.auto_mode_active = false;
                if (rt.dialog_state != .idle or rt.in_flight) {
                    dialogReset(rt, ctx.io);
                    queueInjection(rt, "\x15");
                    ctx.line.reset();
                    rt.ai_mode_active = false;
                }
                latchHint(rt, switch (current) {
                    .off => unreachable,
                    .dialog => "dialog mode OFF",
                    .auto => "auto mode OFF",
                });
                return true;
            }
            // Activate (from .off) or switch (from other mode).
            const switching = current != .off;
            rt.dialog_persistent_mode = target;
            rt.auto_mode_active = (target == .auto);
            // #167 — if user flips into auto AFTER `.exec` armed
            // the refocus latch, disarm: auto-mode will run the
            // Enter itself, focus state is moot, and a stale
            // latch firing on the next `;D` would steal focus
            // from a panel the user might already be back in.
            if (target == .auto) rt.chat_refocus_pending = false;
            if (switching) {
                latchHint(rt, switch (target) {
                    .off => unreachable,
                    .dialog => "→ dialog mode",
                    .auto => "→ auto mode",
                });
                return true;
            }
            // First-time entry into mode: kick off the initial
            // request if the user already typed a `#: …` prompt.
            // Otherwise just announce the mode and wait for the
            // next Enter to fire a request from a free-form line.
            if (rt.ai_mode_active) {
                return startDialog(rt, ctx, target == .auto);
            }
            latchHint(rt, switch (target) {
                .off => unreachable,
                .dialog => "dialog mode ON — type a task and press Enter",
                .auto => "auto mode ON — type a task and press Enter",
            });
            return true;
        }

        fn startDialog(rt: *Runtime, ctx: *m.Context, auto: bool) bool {
            if (!rt.ai_mode_active) return false;
            const line = ctx.line.current();
            const body = std.mem.trim(u8, line[cfg.prefix.len..], " \t");
            if (body.len == 0) {
                latchHint(rt, if (auto)
                    "type your task after `#: ` then press Alt+Shift+S"
                else
                    "type your task after `#: ` then press Alt+S");
                return true;
            }
            if (body.len > cfg.max_prompt_bytes) {
                latchHint(rt, "prompt too long — shorten the task and try again");
                return true;
            }
            if (rt.inert) {
                latchErr(rt, inert_error_msg);
                return true;
            }
            // Dialog mode (both flavours) requires OSC 133 — without
            // `;C` / `;D` we can't tell when the shell finished
            // running each step's command. Single mode (Alt+A)
            // doesn't have this requirement.
            if (!rt.osc133_capture.active) {
                latchOsc133Diag(rt);
                return true;
            }
            const initial = rt.allocator.dupe(u8, body) catch {
                latchErr(rt, "out of memory starting dialog");
                return true;
            };
            pushTurn(rt, ctx, .user, initial) catch {
                rt.allocator.free(initial);
                latchErr(rt, "out of memory starting dialog");
                return true;
            };
            rt.auto_mode_active = auto;
            fireDialogRequest(rt, ctx) catch |err| {
                abortDialog(rt, ctx.io, switch (err) {
                    error.BodyTooLarge => "dialog body too large for buffer — increase Config.body_buf_bytes",
                    error.OutOfMemory => "out of memory firing dialog request",
                    else => "internal error firing dialog request",
                });
                return true;
            };
            queueInjection(rt, "\x15");
            rt.ai_mode_active = false;
            return true;
        }

        /// exceeds `cfg.body_buf_bytes` (the conversation has
        /// outgrown the shared buffer — user needs to cancel).
        /// Resolve a working-directory hint for the sys_context
        /// gatherer. atty's subprocess tracker captures bash's cwd
        /// via OSC 7 + `;C` commits — we surface the topmost
        /// frame's path. Returns empty when nothing has been
        /// tracked yet (sys_context falls back to `getcwd()`).
        fn cwdHint(ctx: *m.Context) []const u8 {
            const tr = ctx.subprocess orelse return "";
            const top = tr.current() orelse return "";
            return top.cwd();
        }

        fn fireDialogRequest(rt: *Runtime, ctx: *m.Context) !void {
            // Resolve which provider will serve this dialog turn so
            // we can pull the model name (HTTP) AND the per-entry
            // history-turns override into the request body. Use the
            // precise dispatch mode so chat/auto-only entries get
            // picked up — `resolveProvider` would otherwise collapse
            // them to plain `.dialog`.
            const resolved_for_body = worker_mod_ns.resolveProviderForMode(
                currentDispatchMode(rt),
                cfg.providers,
                cfg.provider,
                rt.current_provider_idx,
            );
            const model_for_request: []const u8 = switch (resolved_for_body.provider) {
                .http => |h| h.model,
                .subprocess => "",
            };

            // Per-entry history trim. If the active providers[]
            // entry sets `history_turns_max`, send only the last N
            // turns. Look up the override on the resolved entry —
            // not on `cfg.provider` because the resolved provider
            // may have come from `providers[]`.
            const entry_turns_cap: ?usize = blk: {
                if (cfg.providers.len == 0) break :blk null;
                if (rt.current_provider_idx >= cfg.providers.len) break :blk null;
                break :blk cfg.providers[rt.current_provider_idx].history_turns_max;
            };
            const turn_slice: []const dialog.Turn = blk: {
                const cap = entry_turns_cap orelse break :blk rt.turns[0..rt.turns_len];
                if (rt.turns_len <= cap) break :blk rt.turns[0..rt.turns_len];
                break :blk rt.turns[rt.turns_len - cap .. rt.turns_len];
            };

            // Compose the per-request context blob: static OS info
            // (cached at attach) + dynamic pwd/git (rebuilt each call
            // via cheap stat()/read()) + user-listed env vars from
            // `cfg.context_env_vars`. Skipped when:
            //   - `cfg.system_context.enabled = false` (user opted out),
            //   - `ctx.incognito = true` (privacy contract — toggling
            //     Ctrl+Shift+I should suppress environment leakage,
            //     not just history recording. PWD + branch names can
            //     carry project / customer / ticket identifiers).
            // In either case fall back to the legacy `rt.context_blob`
            // (just the user-listed env vars) so the user keeps the
            // context they explicitly opted into.
            const composed_context: []u8 = blk: {
                if (!cfg.system_context.enabled or ctx.incognito) {
                    break :blk rt.allocator.dupe(u8, rt.context_blob) catch break :blk &.{};
                }
                const cwd = if (cfg.system_context.pwd) cwdHint(ctx) else "";
                const dyn = sys_context.gatherDynamic(rt.allocator, cwd, cfg.system_context.git) catch &.{};
                defer rt.allocator.free(dyn);
                break :blk sys_context.compose(rt.allocator, rt.os_info, dyn, rt.context_blob) catch &.{};
            };
            defer rt.allocator.free(composed_context);

            // Build the JSON body OUTSIDE the mutex (allocator work,
            // potentially expensive). In fixture mode the worker
            // discards the body entirely, so skip the serialization
            // altogether.
            // Pick the prompt by the LIVE dispatch mode so an open
            // chat surface (`.chat`), an auto-exec persistent mode
            // (`.auto`), or a regular dialog (`.dialog`) each get
            // the matching atty-owned prompt instead of all routing
            // through `effective_dialog_system_prompt` and missing
            // the auto-mode refusal list / chat-mode prose default.
            const live_mode = currentDispatchMode(rt);
            const live_prompt: []const u8 = switch (live_mode) {
                // `.chat` is reserved for `for_modes` provider
                // masks; `currentDispatchMode` doesn't return it
                // any more. Route to the dialog prompt for
                // defensive completeness.
                .single, .dialog, .chat => effective_dialog_system_prompt,
                .auto => effective_auto_system_prompt,
            };
            const built_body: ?[]u8 = if (cfg.fixture_responses.len > 0) null else blk: {
                const body = try buildDialogRequestBody(
                    rt.allocator,
                    model_for_request,
                    live_prompt,
                    rt.shell,
                    composed_context,
                    turn_slice,
                );
                if (body.len > cfg.body_buf_bytes) {
                    rt.allocator.free(body);
                    return error.BodyTooLarge;
                }
                break :blk body;
            };
            defer if (built_body) |b| rt.allocator.free(b);

            const idx_to_send: usize = if (cfg.providers.len == 0)
                std.math.maxInt(usize)
            else if (rt.current_provider_idx < cfg.providers.len)
                rt.current_provider_idx
            else
                0;

            // SINGLE critical section: body copy + metadata stamp
            // happen under one lock so the worker never sees a half-
            // written request (e.g. fresh body bytes with stale
            // `body_len`). Mirrors the single-mode trigger path's
            // copy-and-stamp-together shape.
            rt.shared.mutex.lockUncancelable(ctx.io);
            defer rt.shared.mutex.unlock(ctx.io);
            if (built_body) |b| {
                @memcpy(rt.shared.body_buf[0..b.len], b);
                rt.shared.body_len = b.len;
            } else {
                rt.shared.body_len = 0;
            }
            rt.shared.current_provider_idx = idx_to_send;
            rt.shared.dispatch_mode = currentDispatchMode(rt);
            rt.shared.req_kind = .dialog;
            rt.shared.req_pending = true;
            rt.shared.req_gen +%= 1;
            rt.shared.res_done = false;
            if (rt.shared.res_buf) |old| {
                rt.allocator.free(old);
                rt.shared.res_buf = null;
            }
            rt.shared.res_len = 0;
            publishSessionId(rt);
            rt.shared.cv.signal(ctx.io);
            rt.in_flight = true;
            rt.dialog_state = .generating;
        }

        /// Echo the LLM's malformed reply back as an `assistant_exec`
        /// turn AND push a corrective user turn explaining what was
        /// wrong, then fire the dialog request again. Used by the
        /// parse-fail and missing-field branches of
        /// `handleDialogResponse` to give the model a chance to
        /// self-correct.
        ///
        /// `reason` is a short human-readable description of the
        /// failure ("wasn't valid JSON", "had action=exec but no
        /// command field", …) that gets formatted into the
        /// corrective prompt. Caller's responsibility to gate on
        /// retry budget; this function unconditionally fires the
        /// retry.
        fn requestParseRetry(rt: *Runtime, ctx: *m.Context, raw: []const u8, reason: []const u8) !void {
            // Echo the malformed reply back as an assistant turn so
            // the model sees its own output in context. Without
            // this the corrective user turn would seem to come
            // from nowhere.
            const assistant_copy = try rt.allocator.dupe(u8, raw);
            errdefer rt.allocator.free(assistant_copy);
            try pushTurn(rt, ctx, .assistant_exec, assistant_copy);

            // Detect specific drift patterns we've seen in practice
            // so the corrective turn can be CONCRETE about the fix
            // instead of generic "use valid JSON." Concrete examples
            // help small models converge faster than abstract specs.
            //   • trailing `{...}` after the main object — the
            //     `{"open_chat": true}` second-object drift the user
            //     hit in image #5. Model treats the advisory flag as
            //     a separate envelope.
            //   • markdown fences (```json …``` wrappers).
            //   • prose preamble ("Sure! Here you go:") before the JSON.
            const concrete_hint: []const u8 = blk: {
                if (std.mem.indexOf(u8, raw, "} {") != null or
                    std.mem.indexOf(u8, raw, "}\n{") != null or
                    std.mem.indexOf(u8, raw, "}\r\n{") != null)
                {
                    break :blk " You emitted TWO JSON objects. The `open_chat` field must be INSIDE the same object as `action`, e.g. {\"action\":\"question\",\"question\":\"…\",\"open_chat\":true} — NOT a separate {\"open_chat\":true} appended after.";
                }
                if (std.mem.indexOf(u8, raw, "```") != null) {
                    break :blk " Drop the ```json fence — emit the raw object.";
                }
                // Heuristic for prose preamble: first non-whitespace
                // char isn't `{`.
                var i: usize = 0;
                while (i < raw.len and (raw[i] == ' ' or raw[i] == '\n' or raw[i] == '\r' or raw[i] == '\t')) : (i += 1) {}
                if (i < raw.len and raw[i] != '{') {
                    break :blk " Drop any prose before the `{` — the FIRST non-whitespace character must be `{`.";
                }
                break :blk "";
            };

            // Build the corrective user turn. Includes the exact
            // reason + (when we detected it) a concrete example fix.
            const corrective = try std.fmt.allocPrint(
                rt.allocator,
                "Your previous reply {s}.{s} Reply STRICTLY with JSON ON ONE LINE: " ++
                    "{{\"action\":\"exec\",\"command\":\"…\",\"description\":\"…\"}} " ++
                    "or {{\"action\":\"done\",\"reason\":\"…\"}} " ++
                    "or {{\"action\":\"question\",\"question\":\"…\"}}. " ++
                    "No prose. No markdown fences. No code blocks. ONE object only.",
                .{ reason, concrete_hint },
            );
            errdefer rt.allocator.free(corrective);
            try pushTurn(rt, ctx, .user, corrective);

            // Fire the retry. fireDialogRequest builds the request
            // body from the full turn list (including our newly
            // appended assistant + corrective turns), bumps
            // req_gen, signals the worker. Dialog state transitions
            // through .generating → .suggesting on the next response.
            try fireDialogRequest(rt, ctx);

            // Surface the retry visibly so the user knows
            // something's happening (the loop isn't silent).
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "LLM reply {s} — retrying ({d}/{d})",
                .{ reason, rt.dialog_parse_retry_count, cfg.dialog_parse_retry_max },
            ) catch "LLM reply malformed — retrying";
            latchHint(rt, msg);
        }
    };
}
