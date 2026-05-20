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
const keymap = @import("../../keymap.zig");
const nowMs = @import("../_lib.zig").nowMs;

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
        const dialogReset = dialog_helpers.dialogReset;
        const abortDialog = dialog_helpers.abortDialog;
        const pushTurn = dialog_helpers.pushTurn;

        const Turn = dialog.Turn;
        const DialogResponse = dialog.Response(cfg.max_response_bytes);
        const Model = types.Model;

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
            return dialog.parseResponse(DialogResponse, allocator, raw, out);
        }
        pub const buildDialogRequestBody = dialog.buildRequestBody;

        // Shared comptime strings (inert-mode notice + dialog system
        // prompt) live in `consts.zig` so this file and llm.zig
        // both import them without a circular dependency.
        const llm_consts = @import("consts.zig").Module(cfg);
        const inert_error_msg = llm_consts.inert_error_msg;
        const effective_dialog_system_prompt = llm_consts.effective_dialog_system_prompt;

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
            move_home,
            move_end,
            kill_to_start,
            kill_to_end,
            kill_word_back,
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
        fn parseChatKey(input: []const u8, i: *usize) ChatKey {
            const b = input[i.*];
            // Incomplete escape tail (chunk ends with `ESC`, `ESC [`,
            // or `ESC O`). Drain to chunk end so the partial bytes
            // don't get reparsed as printables on the next pass.
            if (b == 0x1B and i.* + 1 >= input.len) {
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
                        'D' => .move_left,
                        'C' => .move_right,
                        'H' => .move_home,
                        'F' => .move_end,
                        else => .none,
                    };
                }
                // VT-style `ESC [ <num> ~` (Delete = 3~, Home = 1~/7~,
                // End = 4~/8~). Need a fourth byte to know which.
                if (c >= '0' and c <= '9') {
                    // Incomplete VT-style CSI (chunk ended mid-
                    // sequence, e.g. `ESC [ 3` waiting for `~`).
                    // Drain to chunk end so the caller's
                    // `while (i < input.len)` loop terminates —
                    // returning .none without advancing would spin.
                    if (i.* + 3 >= input.len) {
                        i.* = input.len;
                        return .none;
                    }
                    const final = input[i.* + 3];
                    if (final == '~') {
                        i.* += 4;
                        return switch (c) {
                            '1', '7' => .move_home,
                            '3' => .delete_forward,
                            '4', '8' => .move_end,
                            else => .none,
                        };
                    }
                    // fall through to the param-scan recovery below
                }
                // Param/intermediate byte (0x20-0x3F) — including
                // `?`/`>` private markers, `;` separator, and
                // numeric params. Walk forward to the first byte
                // in 0x40..0x7E (the CSI final) so everything past
                // the sequence is left for the next loop iteration.
                // Without this, sequences like `ESC [ ? 2 5 l` or
                // `ESC [ ; 5 D` would only have `ESC [ <byte>`
                // consumed and the rest leak as printables.
                i.* += 3;
                while (i.* < input.len) : (i.* += 1) {
                    const x = input[i.*];
                    if (x >= 0x40 and x <= 0x7E) {
                        i.* += 1;
                        break;
                    }
                }
                return .none;
            }
            i.* += 1;
            return switch (b) {
                0x01 => .move_home, // Ctrl+A
                0x05 => .move_end, // Ctrl+E
                0x02 => .move_left, // Ctrl+B
                0x06 => .move_right, // Ctrl+F
                0x08, 0x7F => .backspace, // Ctrl+H / DEL
                0x04 => .close, // Ctrl+D
                0x0B => .kill_to_end, // Ctrl+K
                0x15 => .kill_to_start, // Ctrl+U
                0x17 => .kill_word_back, // Ctrl+W
                0x0D, 0x0A => .enter,
                0x20...0x7E => .{ .insert = b },
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
                    const key = parseChatKey(input, &i);
                    switch (key) {
                        .close => {
                            // Ctrl+D — close the panel. Stop
                            // processing the rest of THIS chunk so
                            // post-Ctrl+D bytes don't land in the
                            // now-closed panel's buffer.
                            rt.chat_inline_open = false;
                            rt.chat_inline_paint_pending = true;
                            return .swallow;
                        },
                        .enter => {
                            // Trim trailing whitespace before checking
                            // empty — matches onLineCommit's semantics.
                            var trimmed_len = rt.chat_inline_input_len;
                            while (trimmed_len > 0 and (rt.chat_inline_input_buf[trimmed_len - 1] == ' ' or rt.chat_inline_input_buf[trimmed_len - 1] == '\t')) : (trimmed_len -= 1) {}
                            if (trimmed_len == 0) {
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
                            pushTurn(rt, .user, copy) catch {
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
                                rt.chat_inline_paint_pending = true;
                            }
                        },
                    }
                }
                return .swallow;
            }

            if (rt.chat_overlay_open) {
                var i: usize = 0;
                while (i < input.len) {
                    const key = parseChatKey(input, &i);
                    switch (key) {
                        .close => {
                            // Ctrl+D closes the overlay. Stop the
                            // chunk so post-Ctrl+D bytes don't land
                            // in the now-closed overlay's buffer.
                            rt.chat_overlay_open = false;
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
                            pushTurn(rt, .user, copy) catch {
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
                        pushTurn(rt, .user, initial) catch {
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
        ///   through `cfg.models[]`; no-op + hint when there's
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
                    if (!rt.ai_mode_active) return false;
                    if (cfg.models.len == 0) {
                        // Single-model config — nothing to cycle.
                        // Honest feedback so users know why
                        // Alt+M didn't do anything.
                        latchHint(rt, "single-model config — set `models = &.{ ... }` to cycle");
                        return true;
                    }
                    rt.current_model_idx = (rt.current_model_idx + 1) % cfg.models.len;
                    // Latch a one-line hint with the new pick so
                    // the user sees confirmation. Statusbar AI
                    // hint will also reflect the new model on the
                    // next tick (statusText appends the current
                    // pick when models.len > 0).
                    const new_model = cfg.models[rt.current_model_idx].name;
                    var msg_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "model: {s}", .{new_model}) catch new_model;
                    latchHint(rt, msg);
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
                    const current: []const u8 = if (cfg.models.len > 0)
                        cfg.models[rt.current_model_idx].name
                    else
                        cfg.model;
                    // Cycle info lives in the first 32 bytes of buf.
                    const cycle_info: []const u8 = if (cfg.models.len > 1)
                        std.fmt.bufPrint(buf[0..32], " ({d}/{d})", .{ rt.current_model_idx + 1, cfg.models.len }) catch ""
                    else
                        "";
                    const endpoint: []const u8 = if (rt.inert)
                        "(inert — no endpoint)"
                    else switch (comptime cfg.provider) {
                        .http => rt.api_base,
                        .subprocess => |sub| if (sub.argv.len > 0) sub.argv[0] else "(subprocess)",
                    };
                    // Message goes into the remaining bytes. cycle_info
                    // is referenced before its underlying storage is
                    // overwritten — bufPrint copies the formatted
                    // string verbatim, so this read-then-write order
                    // is safe.
                    const msg = std.fmt.bufPrint(buf[32..], "model: {s}{s} · endpoint: {s} · Esc cancel · Ctrl+Shift+I incognito", .{ current, cycle_info, endpoint }) catch {
                        // Truncated; render at least the model name.
                        latchHint(rt, current);
                        return true;
                    };
                    latchHint(rt, msg);
                    return true;
                },
                .llm_chat_overlay_toggle => {
                    // Phase 2a: toggle a persistent alt-screen
                    // overlay rendering the conversation history.
                    // Open shows turns + conclusion in a chrome-free
                    // text view; close exits the alt screen and
                    // restores the underlying shell.
                    if (!rt.chat_overlay_open) {
                        const has_content = rt.turns_len > 0 or rt.conclusion_len > 0;
                        if (!has_content) {
                            // Nothing to show yet — refuse to open
                            // (avoids an empty alt-screen that the
                            // user has to dismiss). Hint surface
                            // tells them how to populate it.
                            latchHint(rt, "no LLM session to recall — run a dialog (Alt+S) first");
                            return true;
                        }
                        // Mutual exclusion — if the inline panel is
                        // open, close it first so cursor focus is
                        // unambiguous and `extraReserveRows` returns
                        // to zero. Mirror of the inline-toggle arm.
                        if (rt.chat_inline_open) {
                            rt.chat_inline_open = false;
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
                        rt.chat_overlay_paint_pending = true;
                    }
                    rt.chat_inline_open = !rt.chat_inline_open;
                    rt.chat_inline_paint_pending = true;
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

                    const max_offset: usize = rt.turns_len - 1;
                    const offset_ptr: *usize = if (target_overlay) &rt.chat_view_offset else &rt.chat_inline_view_offset;
                    // Page size — large enough that PageUp meaningfully
                    // walks history. Overlay shows ~all turns up to 24
                    // rows so use 8; inline panel's scrollback is
                    // `inline_chat_rows - 2`, mirror it.
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

            // Resolve the model INDEX to stage. Worker reads
            // `cfg.models[idx]` directly when idx is in-range, else
            // falls back to `cfg.model`. Out-of-range
            // `current_model_idx` (shouldn't happen — Alt+M wraps —
            // but defensive) clamps to 0.
            const idx_to_send: usize = if (cfg.models.len == 0)
                std.math.maxInt(usize) // sentinel: "no list, use cfg.model"
            else if (rt.current_model_idx < cfg.models.len)
                rt.current_model_idx
            else
                0;

            // Hand the prompt to the worker. Same locking + req-gen
            // bump as before — see the original onInput comment for
            // the stale-response guard rationale.
            rt.shared.mutex.lockUncancelable(ctx.io);
            defer rt.shared.mutex.unlock(ctx.io);
            @memcpy(rt.shared.req_buf[0..body.len], body);
            rt.shared.req_len = body.len;
            rt.shared.model_idx = idx_to_send;
            rt.shared.req_kind = .single;
            rt.shared.req_pending = true;
            rt.shared.req_gen +%= 1;
            rt.shared.res_done = false;
            rt.shared.res_len = 0;
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

            pushTurn(rt, .observation, observation_slice) catch {
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
                pushTurn(rt, .user, answer) catch {
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
                    rt.shared.res_len = 0;
                    rt.shared.explanation_len = 0;
                    rt.shared.error_len = 0;
                    return null;
                }
                res_kind = rt.shared.res_kind;
                n = rt.shared.res_len;
                @memcpy(rt.inject_buf[0..n], rt.shared.res_buf[0..n]);
                rt.inject_len = n;

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

            // Stash the raw response so it becomes the next
            // assistant_exec turn. Done before parsing so we have
            // it whether or not the JSON parses cleanly.
            const stash_n = @min(raw.len, rt.last_assistant_json.len);
            @memcpy(rt.last_assistant_json[0..stash_n], raw[0..stash_n]);
            rt.last_assistant_json_len = stash_n;

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
                    requestParseRetry(rt, ctx, "wasn't valid JSON") catch {
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
                            requestParseRetry(rt, ctx, "had action=exec but no command field") catch {
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
                    const assistant_copy = rt.allocator.dupe(u8, rt.last_assistant_json[0..rt.last_assistant_json_len]) catch {
                        abortDialog(rt, ctx.io, "out of memory continuing dialog");
                        return null;
                    };
                    pushTurn(rt, .assistant_exec, assistant_copy) catch {
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
                                // reason leaves `conclusion_len` at
                                // zero. Better to surface the notify-
                                // shape hint than open an overlay
                                // saying "no conversation yet".
                                if (rt.conclusion_len > 0) {
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
                    if (rt.last_assistant_json_len > 0) {
                        const assistant_copy = rt.allocator.dupe(u8, rt.last_assistant_json[0..rt.last_assistant_json_len]) catch null;
                        if (assistant_copy) |copy| {
                            pushTurn(rt, .assistant_exec, copy) catch rt.allocator.free(copy);
                        }
                    }
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
            pushTurn(rt, .user, initial) catch {
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
            pushTurn(rt, .user, initial) catch {
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
            // Selected model (entry in `cfg.models`, else the
            // single-fallback `cfg.model`). `current_model_idx >=
            // cfg.models.len` is defensive — Alt+M wraps so it
            // shouldn't happen, but if it does fall back to the
            // legacy single name rather than indexing OOB.
            const sel: ?Model = if (rt.current_model_idx < cfg.models.len)
                cfg.models[rt.current_model_idx]
            else
                null;
            const model_for_request: []const u8 = if (sel) |s| s.name else cfg.model;

            // Per-model context trim. When the selected `Model` sets
            // `history_turns_max`, send only the LAST N turns —
            // useful for small-context models that can't fit the
            // full ring. No-op when null or no models[] configured.
            const turn_slice: []const dialog.Turn = blk: {
                const cap = (sel orelse break :blk rt.turns[0..rt.turns_len]).history_turns_max orelse break :blk rt.turns[0..rt.turns_len];
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
            const built_body: ?[]u8 = if (cfg.fixture_responses.len > 0) null else blk: {
                const body = try buildDialogRequestBody(
                    rt.allocator,
                    model_for_request,
                    effective_dialog_system_prompt,
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

            const idx_to_send: usize = if (cfg.models.len == 0)
                std.math.maxInt(usize)
            else if (rt.current_model_idx < cfg.models.len)
                rt.current_model_idx
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
            rt.shared.model_idx = idx_to_send;
            rt.shared.req_kind = .dialog;
            rt.shared.req_pending = true;
            rt.shared.req_gen +%= 1;
            rt.shared.res_done = false;
            rt.shared.res_len = 0;
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
        fn requestParseRetry(rt: *Runtime, ctx: *m.Context, reason: []const u8) !void {
            // Echo the malformed reply back as an assistant turn so
            // the model sees its own output in context. Without
            // this the corrective user turn would seem to come
            // from nowhere.
            const bad_reply = rt.last_assistant_json[0..rt.last_assistant_json_len];
            const assistant_copy = try rt.allocator.dupe(u8, bad_reply);
            errdefer rt.allocator.free(assistant_copy);
            try pushTurn(rt, .assistant_exec, assistant_copy);

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
                if (std.mem.indexOf(u8, bad_reply, "} {") != null or
                    std.mem.indexOf(u8, bad_reply, "}\n{") != null or
                    std.mem.indexOf(u8, bad_reply, "}\r\n{") != null)
                {
                    break :blk " You emitted TWO JSON objects. The `open_chat` field must be INSIDE the same object as `action`, e.g. {\"action\":\"question\",\"question\":\"…\",\"open_chat\":true} — NOT a separate {\"open_chat\":true} appended after.";
                }
                if (std.mem.indexOf(u8, bad_reply, "```") != null) {
                    break :blk " Drop the ```json fence — emit the raw object.";
                }
                // Heuristic for prose preamble: first non-whitespace
                // char isn't `{`.
                var i: usize = 0;
                while (i < bad_reply.len and (bad_reply[i] == ' ' or bad_reply[i] == '\n' or bad_reply[i] == '\r' or bad_reply[i] == '\t')) : (i += 1) {}
                if (i < bad_reply.len and bad_reply[i] != '{') {
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
            try pushTurn(rt, .user, corrective);

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
