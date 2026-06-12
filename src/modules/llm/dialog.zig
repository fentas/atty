//! Dialog-mode types + Runtime-touching helpers extracted from `llm.zig`.
//!
//! Two layers in this file:
//!
//! Layer 1 (top of file): pure types + pure helpers, no Runtime
//! dependency — `State`, `Action`, `TurnKind`, `Turn`,
//! `Response(max_bytes)` factory, `parseResponse`, `buildRequestBody`.
//!
//! Layer 2 (`Module(cfg, Runtime)` factory near the bottom): the
//! small Runtime-touching helpers that compose the turn ring, the
//! captured-output buffer, and the conclusion banner. They take
//! `*Runtime` by reference and don't try to model the full state
//! machine — that still lives in `llm.zig`. The factory takes
//! `Runtime` as a comptime arg so it can stay defined in `llm.zig`
//! (Runtime closes over `cfg` in ways that make a sibling
//! definition awkward), while the helpers move out to keep llm.zig
//! lean.

const std = @import("std");

/// Where the dialog state machine currently is. Transitions happen
/// at fixed points: Alt+S → `.generating`; worker response →
/// `.suggesting`; user Enter → `.executing`; OSC 133 `;C` →
/// `.capturing_output`; `;D` → `.observation_ready`; next request
/// fire → `.generating`. `.idle` is the terminal state on done /
/// cancel.
pub const State = enum {
    /// Not in a dialog. Either user hasn't entered AI mode or a
    /// previous dialog has been completed/cancelled.
    idle,
    /// Request is in flight (initial Alt+S, or a follow-up after
    /// an observation arrived). Worker is POSTing.
    generating,
    /// LLM has replied with `action=exec`; the suggested command
    /// is injected at the prompt and waiting for the user to
    /// press Enter (or cancel).
    suggesting,
    /// User hit Enter. Command bytes are on their way to the
    /// shell; we're waiting for OSC 133 `;C` to fire so we know
    /// the command actually started.
    executing,
    /// Between OSC 133 `;C` and `;D` — `onOutput` is appending
    /// bytes to `captured_output`.
    capturing_output,
    /// `;D` fired; observation is ready. Next `onTick` will push
    /// the observation as a turn and re-enter `.generating` with
    /// the follow-up request.
    observation_ready,
    /// LLM replied with `action=question`. The prompt is latched
    /// in the hint row; the user types their answer at the shell
    /// prompt and Enter sends it as the next `.user` turn. AI
    /// mode stays on while we wait.
    awaiting_question_answer,
};

/// One of three top-level actions the model can pick in a dialog
/// step: continue executing (`exec`), pause for clarification
/// (`question`), or stop (`done`). Selected by the markdown lang
/// tag in the fenced-action protocol — see `prompts.zig` for the
/// system prompts that train the model on this contract.
pub const Action = enum { exec, question, done };

/// Conversation-turn taxonomy. The full conversation is a `[]Turn`
/// flattened into the request body's `messages` array by
/// `buildRequestBody` — `user`/`observation` map to OpenAI's
/// `user` role; `assistant_exec` maps to `assistant`.
pub const TurnKind = enum {
    /// Initial user task (`#: <task>` body).
    user,
    /// LLM's raw JSON reply for an exec step. Echoed back to the
    /// model verbatim on the next turn so the conversation stays
    /// self-consistent.
    assistant_exec,
    /// OSC 133 `;C` → `;D` captured output for the prior exec
    /// turn. Prefixed with `OBSERVATION:\n` when rendered into
    /// the request body.
    observation,
};

/// Conversation turn — heap-owned by the runtime (freed in
/// `detach` and on cancel). Content length is bounded at
/// `cfg.max_turn_bytes` by the runtime's `pushTurn` site so a
/// runaway model can't bloat process memory.
pub const Turn = struct {
    kind: TurnKind,
    content: []u8,
};

/// Max number of multi-choice options atty parses from an
/// `action=question` reply. Capped at 9 because `ghost_pick`'s
/// Ctrl+1..9 / Esc+1..9 bindings address up to 9 entries — a
/// 10th option would be unreachable from the keyboard.
pub const max_choices = 9;
/// Per-choice text cap. Anything longer gets truncated. 256 bytes
/// is roughly one terminal line at typical widths; longer
/// choices would wrap and confuse the pick-list rendering.
pub const choice_max_len = 256;

/// Parsed-reply struct factory. The buffer sizes come from
/// `cfg.max_response_bytes` (for `command_buf` and `question_buf`,
/// which can be long shell-command-shaped strings) and a fixed
/// 256-byte budget for the two short prose fields (`description`
/// and `reason`). Returning a `type` (rather than passing buffer
/// sizes through as runtime params) keeps callers stack-friendly:
/// they can `var parsed: Response = .{}` inline without an
/// allocator.
pub fn Response(comptime max_response_bytes: comptime_int) type {
    return struct {
        const Self = @This();

        action: Action = .done,
        command_buf: [max_response_bytes]u8 = undefined,
        command_len: usize = 0,
        description_buf: [256]u8 = undefined,
        description_len: usize = 0,
        /// Sized like `command_buf` because a `done`-action reason
        /// is the LLM's actual answer text — often multi-paragraph
        /// prose (essays, code generations, long explanations) that
        /// has the same upper bound as the body of an `exec`
        /// command. The previous 256-byte cap was inherited from
        /// `description_buf` where it makes sense (description is
        /// a short accompanying note) but is wrong here. Realistic
        /// LLM replies > 256 bytes were silently truncated at
        /// parse time with no marker.
        reason_buf: [max_response_bytes]u8 = undefined,
        reason_len: usize = 0,
        /// `action=question` payload — the prompt text. Surfaced
        /// in the hint row; the user's free-form answer at the
        /// shell prompt becomes the next `.user` turn (free-text
        /// path), OR the picked choice text (multi-choice path).
        question_buf: [max_response_bytes]u8 = undefined,
        question_len: usize = 0,
        /// Multi-choice answer options for `action=question`.
        /// Optional — when omitted the user replies free-text.
        /// When present, atty renders them as a pick-list and
        /// `ghost_pick` (Ctrl+1..9 / Esc+1..9) selects an option
        /// as the answer.
        choices_storage: [max_choices][choice_max_len]u8 = undefined,
        choices_lens: [max_choices]usize = [_]usize{0} ** max_choices,
        choices_count: usize = 0,
        /// Advisory flag — the LLM is asking atty to open the chat
        /// overlay carrying this response as context. Honoured per
        /// `Config.overlay_open_policy`:
        ///   - `.always` → auto-open
        ///   - `.notify` → latch a hint, user decides
        ///   - `.never` → ignored
        /// Defaults to false; the LLM has to explicitly opt in by
        /// emitting `"open_chat": true` in the JSON envelope.
        open_chat: bool = false,

        pub fn command(self: *const Self) []const u8 {
            return self.command_buf[0..self.command_len];
        }
        pub fn description(self: *const Self) []const u8 {
            return self.description_buf[0..self.description_len];
        }
        pub fn reason(self: *const Self) []const u8 {
            return self.reason_buf[0..self.reason_len];
        }
        pub fn question(self: *const Self) []const u8 {
            return self.question_buf[0..self.question_len];
        }
        /// Read one choice by index. Out-of-range returns empty.
        pub fn choice(self: *const Self, idx: usize) []const u8 {
            if (idx >= self.choices_count) return &.{};
            return self.choices_storage[idx][0..self.choices_lens[idx]];
        }
    };
}

/// Parse the raw assistant content (already extracted from the
/// OpenAI envelope by `extractRawContent`) as a dialog JSON
/// payload. Fills `out`'s fixed-size buffers with the decoded
/// fields and sets `out.action`. Unknown fields are silently
/// ignored so a model emitting extra keys (or tool-call wrappers)
/// doesn't error the loop.
///
/// `std.json.parseFromSlice` returns a `Parsed(T)` whose
/// `.deinit()` releases an INTERNAL arena allocated through the
/// passed allocator. Wrapping our own arena AROUND that and
/// calling both `arena.deinit()` and `parsed.deinit()` would be
/// redundant at best and dangerous at worst (double free of
/// arena-owned storage on some Zig versions). Use
/// `parsed.deinit()` alone — it owns everything `parsed.value`
/// references. We copy each field out into `out`'s buffers
/// BEFORE the defer fires, so the returned slices point at the
/// caller's `out` storage, not at arena-owned memory.
pub fn parseResponse(
    comptime ResponseT: type,
    allocator: std.mem.Allocator,
    raw: []const u8,
    out: *ResponseT,
) !void {
    const Parsed = struct {
        action: []const u8,
        command: ?[]const u8 = null,
        description: ?[]const u8 = null,
        reason: ?[]const u8 = null,
        question: ?[]const u8 = null,
        /// Multi-choice options for `action=question`. Capped at
        /// `max_choices` items; the rest are silently dropped (no
        /// way to address >9 entries from the keyboard anyway).
        choices: ?[]const []const u8 = null,
        /// Advisory flag — model is asking atty to open the chat
        /// overlay so the user can follow up. Honoured per
        /// `Config.overlay_open_policy`. Defaults to false / absent.
        open_chat: ?bool = null,
    };

    const parsed = std.json.parseFromSlice(
        Parsed,
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return error.MalformedJson;
    defer parsed.deinit();

    const action_enum = std.meta.stringToEnum(Action, parsed.value.action) orelse return error.UnknownAction;
    out.* = .{ .action = action_enum };

    if (parsed.value.command) |c| {
        // Strip control bytes (keep `\n` for multi-line) so a `\r`
        // or ESC in the model's command can't fire Enter / inject an
        // escape sequence when it reaches readline. See
        // `parseFencedResponse` exec arm for the sibling path.
        out.command_len = parse.stripControlBytesKeepNewlines(c, &out.command_buf);
    }
    if (parsed.value.description) |d| {
        const n = @min(d.len, out.description_buf.len);
        @memcpy(out.description_buf[0..n], d[0..n]);
        out.description_len = n;
    }
    if (parsed.value.reason) |r| {
        const n = @min(r.len, out.reason_buf.len);
        @memcpy(out.reason_buf[0..n], r[0..n]);
        out.reason_len = n;
    }
    if (parsed.value.question) |q| {
        const n = @min(q.len, out.question_buf.len);
        @memcpy(out.question_buf[0..n], q[0..n]);
        out.question_len = n;
    }
    if (parsed.value.choices) |choices| {
        const take = @min(choices.len, max_choices);
        for (choices[0..take], 0..) |choice_str, i| {
            const n = @min(choice_str.len, choice_max_len);
            @memcpy(out.choices_storage[i][0..n], choice_str[0..n]);
            out.choices_lens[i] = n;
        }
        out.choices_count = take;
    }
    if (parsed.value.open_chat) |flag| {
        out.open_chat = flag;
    }
}

/// Parser for the fenced-action protocol. Never errors — pure prose
/// degrades to `.done` + reason = raw text so a chat surface can
/// render it as a turn and keep the conversation open instead of
/// rejecting with a "STRICTLY JSON" retry that hostile small models
/// can't escape. See `prompts.zig` for the contract the LLM is
/// trained to honour.
pub fn parseFencedResponse(comptime ResponseT: type, raw: []const u8, out: *ResponseT) void {
    out.* = .{ .action = .done };

    const fence = findLastActionFence(raw) orelse {
        // No recognized action fence — treat entire response as a
        // `done`/reason. Chat-mode callers can render this as a
        // plain prose turn and continue the conversation.
        copyInto(&out.reason_buf, &out.reason_len, trim(raw));
        return;
    };

    const prose = trim(raw[0..fence.fence_start]);
    const body = trim(raw[fence.body_start..fence.body_end]);

    switch (fence.action) {
        .exec => {
            out.action = .exec;
            // Keep `\n` (bracketed paste makes it literal) but drop
            // `\r`/ESC/other controls that would fire Enter or inject
            // an escape sequence at the prompt.
            out.command_len = parse.stripControlBytesKeepNewlines(body, &out.command_buf);
            if (prose.len > 0) {
                copyInto(&out.description_buf, &out.description_len, prose);
            }
        },
        .question => {
            out.action = .question;
            // Lines BEFORE the first bullet are the prompt (single-
            // or multi-paragraph); bullet lines and everything after
            // are choices.
            var prompt_end: usize = body.len;
            var line_start: usize = 0;
            while (line_start < body.len) {
                var line_end = line_start;
                while (line_end < body.len and body[line_end] != '\n') : (line_end += 1) {}
                if (isBulletLine(trimStart(body[line_start..line_end]))) {
                    prompt_end = line_start;
                    break;
                }
                line_start = line_end + 1;
            }
            copyInto(&out.question_buf, &out.question_len, trim(body[0..prompt_end]));
            var idx: usize = prompt_end;
            while (idx < body.len and out.choices_count < max_choices) {
                var line_end = idx;
                while (line_end < body.len and body[line_end] != '\n') : (line_end += 1) {}
                const line = trimStart(body[idx..line_end]);
                if (isBulletLine(line)) {
                    const choice_text = trim(stripBullet(line));
                    if (choice_text.len > 0) {
                        const n = @min(choice_text.len, choice_max_len);
                        @memcpy(out.choices_storage[out.choices_count][0..n], choice_text[0..n]);
                        out.choices_lens[out.choices_count] = n;
                        out.choices_count += 1;
                    }
                }
                idx = line_end + 1;
            }
        },
        .done => {
            out.action = .done;
            copyInto(&out.reason_buf, &out.reason_len, body);
        },
    }
}

const ActionFenceMatch = struct {
    fence_start: usize, // index of the opening ``` (before the lang tag)
    body_start: usize, // index of the first byte of the body
    body_end: usize, // index just past the last body byte (excludes closing fence)
    action: Action,
};

/// Whether `raw` contains a recognised action fence.
pub fn hasActionFence(raw: []const u8) bool {
    return findLastActionFence(raw) != null;
}

/// Wrap the LLM's `command` payload in xterm bracketed-paste
/// markers (`\x1B[200~ … \x1B[201~`) so readline accepts a
/// multi-line command as a single paste: newlines stay literal in
/// the input buffer rather than firing as Enter. The user sees the
/// multi-line command at the prompt, can edit it, and submits with
/// one Enter — exactly the UX of pasting a multi-line script into
/// a terminal manually.
///
/// Previously this function chained lines with ` && `. That
/// preserved short-circuit semantics but flattened user-visible
/// structure, silently dropped lines with inline `#` comments, and
/// bailed verbatim on heredocs (re-introducing the `\n`-as-Enter
/// bug for the exact shapes the chain was meant to fix). Bracketed
/// paste handles all of these uniformly: heredocs, continuations,
/// comments, and chain operators stay verbatim in the input buffer.
///
/// Single-line input (no `\n`) skips the markers — no point paying
/// the 12-byte wrap for a single command, and terminals that don't
/// honor `?2004` would echo the markers as literal `[200~…[201~`
/// text.
///
/// Returns the count of bytes written into `dest`. `dest` must
/// hold at least `src.len + 12` bytes (the open + close marker).
/// Buffer overflow stages NOTHING (returns 0) — a half-wrapped or
/// truncated paste would leave the terminal mid-`?2004` paste or
/// drop the closing marker, so it's safer to inject nothing than a
/// runaway paste. Callers must check for a 0 return (no command
/// staged). Note `dest` is sized `max_response_bytes + 12` and `src`
/// can be at most `max_response_bytes`, so overflow is a defensive
/// guard, not an expected path.
///
/// Adversarial input: a literal `\x1B[201~` byte sequence inside
/// `src` will terminate the paste early on the receiving terminal
/// — the bytes after that point land at the next prompt as a
/// separate command. Not defended against here (rare in real LLM
/// output + would be ambiguous to escape); same trade-off as the
/// chat-panel paste path documented in llm.zig. Control bytes other
/// than `\n` are stripped upstream at parse time
/// (`stripControlBytesKeepNewlines`), so a raw `\r`/ESC never
/// reaches this function.
pub fn wrapForBracketedPaste(src: []const u8, dest: []u8) usize {
    if (src.len == 0) return 0;
    if (std.mem.indexOfScalar(u8, src, '\n') == null) {
        if (src.len > dest.len) return 0;
        @memcpy(dest[0..src.len], src);
        return src.len;
    }
    const open = "\x1B[200~";
    const close = "\x1B[201~";
    // Worst-case sizing assumes no CRLF stripping; actual output is
    // smaller when CRLF→LF normalization fires.
    const worst_case = open.len + src.len + close.len;
    if (worst_case > dest.len) return 0;
    @memcpy(dest[0..open.len], open);
    var out_len: usize = open.len;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        // CRLF → LF: many bracketed-paste consumers (readline, vte-
        // family terminals) treat both `\r` and `\n` as newline, so
        // a `\r\n` pair lands as a blank line in the input buffer.
        // Strip the `\r` to keep the wrapped body 1:1 with what
        // readline sees on a manual paste.
        if (src[i] == '\r' and i + 1 < src.len and src[i + 1] == '\n') continue;
        dest[out_len] = src[i];
        out_len += 1;
    }
    @memcpy(dest[out_len..(out_len + close.len)], close);
    out_len += close.len;
    return out_len;
}

/// Walk `raw` backward looking for the last ` ```<action> ... ``` `
/// block. Returns null if no recognized lang tag is found.
fn findLastActionFence(raw: []const u8) ?ActionFenceMatch {
    // Strategy: find every ``` (3+ backticks at start of line or
    // after whitespace), pair them up, take the last pair whose
    // opening fence has a recognized lang tag.
    var search_from: usize = raw.len;
    while (search_from > 0) {
        const close_idx = findFenceBefore(raw, search_from) orelse return null;
        // Try to find an opening fence BEFORE this one. If none —
        // including when `close_idx` itself sits at byte 0 — fall
        // through to the unpaired-fence branch which treats the
        // single fence as an UNCLOSED opener (body runs to EOF).
        const open_idx = findFenceBefore(raw, close_idx) orelse {
            // Unpaired closing fence — treat the unclosed body as
            // running to end-of-input (i.e. the LLM forgot to
            // close). Re-examine with `close_idx` as a potential
            // opening fence.
            const lang_from = lineEndAfterFence(raw, close_idx);
            const lang_line = raw[close_idx..lang_from];
            const action = parseLangTag(lang_line) orelse {
                search_from = close_idx;
                continue;
            };
            return .{
                .fence_start = close_idx,
                .body_start = lang_from,
                .body_end = raw.len,
                .action = action,
            };
        };
        // Lang tag lives on the same line as the opening fence.
        const lang_from = lineEndAfterFence(raw, open_idx);
        const lang_line = raw[open_idx..lang_from];
        const action = parseLangTag(lang_line) orelse {
            // Not an action fence — keep walking back.
            search_from = open_idx;
            continue;
        };
        return .{
            .fence_start = open_idx,
            .body_start = lang_from,
            .body_end = close_idx,
            .action = action,
        };
    }
    return null;
}

/// Locate the last `^[ \t]*```` occurrence STRICTLY before `before`.
/// Returns the index of the first backtick in that fence run, or
/// null. Treats 3+ contiguous backticks as a fence; tolerates
/// leading indentation (the model occasionally adds it).
fn findFenceBefore(raw: []const u8, before: usize) ?usize {
    if (before == 0) return null;
    var i: usize = before;
    while (i > 0) {
        i -= 1;
        if (raw[i] != '`') continue;
        // Walk left collecting consecutive backticks.
        var start = i;
        while (start > 0 and raw[start - 1] == '`') : (start -= 1) {}
        const run_len = i - start + 1;
        if (run_len < 3) continue;
        // Ensure backticks are at line start (allowing leading
        // whitespace) — guards against backticks INSIDE prose.
        var bol = start;
        while (bol > 0 and raw[bol - 1] != '\n') : (bol -= 1) {
            if (raw[bol - 1] != ' ' and raw[bol - 1] != '\t') {
                // Backticks have non-whitespace before them on the
                // same line → not a fence. Skip past this run.
                i = start;
                if (i == 0) return null;
                break;
            }
        } else {
            return start;
        }
        // Loop continues to look further back.
        if (i == 0) break;
    }
    return null;
}

/// Returns the byte index of the newline that ends the line `fence`
/// is on (or `raw.len` if the fence is on the last line).
fn lineEndAfterFence(raw: []const u8, fence: usize) usize {
    var i: usize = fence;
    // Skip past the backtick run + the lang tag (up to newline).
    while (i < raw.len and raw[i] == '`') : (i += 1) {}
    while (i < raw.len and raw[i] != '\n') : (i += 1) {}
    if (i < raw.len) i += 1; // step past the newline
    return i;
}

/// Map a fence's `<backticks><lang><eol>` prefix line to an Action.
/// Aliases: exec/sh/bash/shell → exec, question/ask/q → question,
/// done/finish/end → done. Whitespace-tolerant; case-insensitive.
fn parseLangTag(line: []const u8) ?Action {
    // Strip leading backticks.
    var i: usize = 0;
    while (i < line.len and line[i] == '`') : (i += 1) {}
    // Trim whitespace.
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    var end: usize = i;
    while (end < line.len and line[end] != '\n' and line[end] != ' ' and line[end] != '\t') : (end += 1) {}
    const tag = line[i..end];
    if (tag.len == 0) return null;
    if (eqIgnoreCase(tag, "exec") or eqIgnoreCase(tag, "sh") or eqIgnoreCase(tag, "bash") or eqIgnoreCase(tag, "zsh") or eqIgnoreCase(tag, "shell")) return .exec;
    if (eqIgnoreCase(tag, "question") or eqIgnoreCase(tag, "ask") or eqIgnoreCase(tag, "q")) return .question;
    if (eqIgnoreCase(tag, "done") or eqIgnoreCase(tag, "finish") or eqIgnoreCase(tag, "end")) return .done;
    return null;
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t' or s[start] == '\n' or s[start] == '\r')) : (start += 1) {}
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\n' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[start..end];
}

fn trimStart(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    return s[start..];
}

fn isBulletLine(line: []const u8) bool {
    if (line.len < 2) return false;
    // `- foo` / `* foo` / `• foo` / `N. foo` / `N) foo`.
    if ((line[0] == '-' or line[0] == '*') and line[1] == ' ') return true;
    // `•` (U+2022) = 0xE2 0x80 0xA2 (3 bytes) — bullet glyph the
    // LLM sometimes emits when rendering a list visually.
    if (line.len >= 4 and line[0] == 0xE2 and line[1] == 0x80 and line[2] == 0xA2 and line[3] == ' ') return true;
    // Numbered: digits, then `.` or `)`, then space.
    var i: usize = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i > 0 and i < line.len and (line[i] == '.' or line[i] == ')') and i + 1 < line.len and line[i + 1] == ' ') return true;
    return false;
}

fn stripBullet(line: []const u8) []const u8 {
    if (line.len < 2) return line;
    if ((line[0] == '-' or line[0] == '*') and line[1] == ' ') return line[2..];
    if (line.len >= 4 and line[0] == 0xE2 and line[1] == 0x80 and line[2] == 0xA2 and line[3] == ' ') return line[4..];
    var i: usize = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i > 0 and i < line.len and (line[i] == '.' or line[i] == ')') and i + 1 < line.len and line[i + 1] == ' ') return line[i + 2 ..];
    return line;
}

fn copyInto(buf: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    len.* = n;
}

/// Compose the OpenAI chat-completion request body for a dialog
/// turn. The system message bakes in the configured prompt PLUS a
/// stable shell-name / context-blob preamble — putting those on
/// the SYSTEM message (rather than wrapping the first user turn)
/// means they survive FIFO eviction. Once history fills past
/// `history_turns_max` and the original user task ages out,
/// future requests would otherwise lose every trace of shell
/// context. The system message is rebuilt per request, so there's
/// no historical-rewrite concern either.
///
/// Returns an owned slice — caller frees via the same allocator.
pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    system_prompt: []const u8,
    shell_name: []const u8,
    context_blob: []const u8,
    turns: []const Turn,
) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();
    const writer = &allocating.writer;

    const composed_system = if (context_blob.len > 0)
        try std.fmt.allocPrint(
            allocator,
            "{s}\n\nShell: {s}\nContext: {s}",
            .{ system_prompt, shell_name, context_blob },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{s}\n\nShell: {s}",
            .{ system_prompt, shell_name },
        );
    defer allocator.free(composed_system);

    try writer.writeAll("{\"model\":");
    try std.json.Stringify.encodeJsonString(model, .{}, writer);
    try writer.writeAll(",\"messages\":[{\"role\":\"system\",\"content\":");
    try std.json.Stringify.encodeJsonString(composed_system, .{}, writer);
    try writer.writeAll("}");

    for (turns) |turn| {
        const role: []const u8 = switch (turn.kind) {
            .assistant_exec => "assistant",
            .user, .observation => "user",
        };
        try writer.writeAll(",{\"role\":\"");
        try writer.writeAll(role);
        try writer.writeAll("\",\"content\":");

        if (turn.kind == .observation) {
            const wrapped = try std.fmt.allocPrint(
                allocator,
                "OBSERVATION:\n{s}",
                .{turn.content},
            );
            defer allocator.free(wrapped);
            try std.json.Stringify.encodeJsonString(wrapped, .{}, writer);
        } else {
            try std.json.Stringify.encodeJsonString(turn.content, .{}, writer);
        }
        try writer.writeAll("}");
    }

    try writer.writeAll("],\"stream\":false}");
    return allocating.toOwnedSlice();
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "Response factory: sizes follow the comptime param" {
    const R = Response(4096);
    const r: R = .{};
    try testing.expectEqual(@as(usize, 4096), r.command_buf.len);
    try testing.expectEqual(@as(usize, 4096), r.question_buf.len);
    try testing.expectEqual(@as(usize, 256), r.description_buf.len);
    // reason_buf follows the comptime param — the LLM's done-
    // action answer can be multi-paragraph prose, sized like
    // command_buf rather than the short description_buf.
    try testing.expectEqual(@as(usize, 4096), r.reason_buf.len);
    // Default action — `done` is the safe default (stops the
    // dialog loop) if a caller forgets to overwrite.
    try testing.expectEqual(Action.done, r.action);
}

test "parseResponse: exec action with command + description" {
    const R = Response(4096);
    var r: R = .{};
    try parseResponse(R, testing.allocator, "{\"action\":\"exec\",\"command\":\"ls -la\",\"description\":\"list files in detail\"}", &r);
    try testing.expectEqual(Action.exec, r.action);
    try testing.expectEqualStrings("ls -la", r.command());
    try testing.expectEqualStrings("list files in detail", r.description());
    try testing.expectEqualStrings("", r.reason());
    try testing.expectEqualStrings("", r.question());
}

test "parseResponse: done action with reason" {
    const R = Response(4096);
    var r: R = .{};
    try parseResponse(R, testing.allocator, "{\"action\":\"done\",\"reason\":\"task complete\"}", &r);
    try testing.expectEqual(Action.done, r.action);
    try testing.expectEqualStrings("task complete", r.reason());
}

test "parseResponse: question action with choices array (multi-choice)" {
    const R = Response(4096);
    var r: R = .{};
    try parseResponse(R, testing.allocator, "{\"action\":\"question\",\"question\":\"Which approach?\",\"choices\":[\"approach A\",\"approach B\",\"approach C\"]}", &r);
    try testing.expectEqual(Action.question, r.action);
    try testing.expectEqualStrings("Which approach?", r.question());
    try testing.expectEqual(@as(usize, 3), r.choices_count);
    try testing.expectEqualStrings("approach A", r.choice(0));
    try testing.expectEqualStrings("approach B", r.choice(1));
    try testing.expectEqualStrings("approach C", r.choice(2));
    try testing.expectEqualStrings("", r.choice(3)); // out-of-range → empty
}

test "parseResponse: choices beyond max_choices get silently dropped" {
    // 10 choices but max_choices is 9 — keyboard can only address
    // 9 anyway (Ctrl+1..9), so we cap rather than error.
    const R = Response(4096);
    var r: R = .{};
    try parseResponse(R, testing.allocator, "{\"action\":\"question\",\"question\":\"?\",\"choices\":[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\",\"h\",\"i\",\"j\"]}", &r);
    try testing.expectEqual(@as(usize, max_choices), r.choices_count);
    try testing.expectEqualStrings("a", r.choice(0));
    try testing.expectEqualStrings("i", r.choice(8));
}

test "parseResponse: oversized choice text gets truncated to choice_max_len" {
    const R = Response(4096);
    var r: R = .{};
    const long_choice = "a" ** (choice_max_len + 50);
    var json_buf: [4096]u8 = undefined;
    const json = try std.fmt.bufPrint(&json_buf, "{{\"action\":\"question\",\"question\":\"?\",\"choices\":[\"{s}\"]}}", .{long_choice});
    try parseResponse(R, testing.allocator, json, &r);
    try testing.expectEqual(@as(usize, choice_max_len), r.choices_lens[0]);
}

test "parseResponse: question action with question text" {
    const R = Response(4096);
    var r: R = .{};
    try parseResponse(R, testing.allocator, "{\"action\":\"question\",\"question\":\"Which directory?\"}", &r);
    try testing.expectEqual(Action.question, r.action);
    try testing.expectEqualStrings("Which directory?", r.question());
}

test "parseResponse: unknown action errors UnknownAction" {
    const R = Response(4096);
    var r: R = .{};
    const err = parseResponse(R, testing.allocator, "{\"action\":\"banana\"}", &r);
    try testing.expectError(error.UnknownAction, err);
}

test "parseResponse: malformed JSON errors MalformedJson" {
    const R = Response(4096);
    var r: R = .{};
    const err = parseResponse(R, testing.allocator, "{not valid json", &r);
    try testing.expectError(error.MalformedJson, err);
}

test "parseResponse: ignore_unknown_fields swallows extra keys" {
    const R = Response(4096);
    var r: R = .{};
    try parseResponse(R, testing.allocator, "{\"action\":\"exec\",\"command\":\"ls\",\"future_field\":[1,2,3]}", &r);
    try testing.expectEqual(Action.exec, r.action);
    try testing.expectEqualStrings("ls", r.command());
}

test "parseResponse: oversized command field gets truncated to buffer size" {
    const R = Response(8); // tiny on purpose
    var r: R = .{};
    try parseResponse(R, testing.allocator, "{\"action\":\"exec\",\"command\":\"abcdefghijklmnop\"}", &r);
    try testing.expectEqual(@as(usize, 8), r.command_len);
    try testing.expectEqualStrings("abcdefgh", r.command());
}

test "parseResponse: exec command strips CR/ESC, keeps LF (injection defense)" {
    const R = Response(4096);
    var r: R = .{};
    // \r would fire Enter at the prompt; \x1b injects an escape
    // sequence; \n must survive (bracketed paste makes it literal).
    try parseResponse(R, testing.allocator, "{\"action\":\"exec\",\"command\":\"echo a\\rrm -rf /\\nls\\u001b[31m\"}", &r);
    try testing.expectEqual(Action.exec, r.action);
    try testing.expectEqualStrings("echo arm -rf /\nls[31m", r.command());
}

test "parseFencedResponse: exec command strips CR/ESC, keeps LF (injection defense)" {
    const R = Response(4096);
    var r: R = .{};
    const raw = "```exec\nline1\rmalicious\nline2\x1b]0;evil\x07\n```";
    parseFencedResponse(R, raw, &r);
    try testing.expectEqual(Action.exec, r.action);
    // \r and the OSC escape bytes (\x1b, \x07) are gone; the two
    // legitimate newlines survive for the multi-line paste.
    try testing.expectEqualStrings("line1malicious\nline2]0;evil", r.command());
}

test "wrapForBracketedPaste: overflow stages nothing (no runaway paste)" {
    var dest: [10]u8 = undefined;
    // Multi-line src that can't fit with markers → return 0.
    try testing.expectEqual(@as(usize, 0), wrapForBracketedPaste("a\nbbbbbbbbbb", &dest));
    // Single-line src larger than dest → return 0 (no truncation).
    try testing.expectEqual(@as(usize, 0), wrapForBracketedPaste("0123456789abc", &dest));
}

test "wrapForBracketedPaste: multi-line wraps with markers, single-line bare" {
    var dest: [64]u8 = undefined;
    const single = wrapForBracketedPaste("ls -la", &dest);
    try testing.expectEqualStrings("ls -la", dest[0..single]);
    const multi = wrapForBracketedPaste("a\nb", &dest);
    try testing.expectEqualStrings("\x1b[200~a\nb\x1b[201~", dest[0..multi]);
}

test "buildRequestBody: minimal — model + system + one user turn" {
    var content_buf = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const turns = [_]Turn{.{ .kind = .user, .content = &content_buf }};
    const body = try buildRequestBody(
        testing.allocator,
        "test-model",
        "you are helpful",
        "bash",
        "",
        &turns,
    );
    defer testing.allocator.free(body);
    // Loose contract checks — exact JSON shape isn't an
    // interface here, so don't pin it; just spot the must-haves.
    try testing.expect(std.mem.indexOf(u8, body, "\"test-model\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"system\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "you are helpful") != null);
    try testing.expect(std.mem.indexOf(u8, body, "Shell: bash") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "hello") != null);
}

test "buildRequestBody: context blob appended after Shell preamble" {
    const body = try buildRequestBody(
        testing.allocator,
        "m",
        "sys",
        "bash",
        "PATH_BASE=/home/me/repo",
        &.{},
    );
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "Shell: bash") != null);
    try testing.expect(std.mem.indexOf(u8, body, "Context: PATH_BASE=/home/me/repo") != null);
}

test "buildRequestBody: observation turn gets OBSERVATION prefix" {
    var content_buf = [_]u8{ 'o', 'u', 't', 'p', 'u', 't' };
    const turns = [_]Turn{.{ .kind = .observation, .content = &content_buf }};
    const body = try buildRequestBody(testing.allocator, "m", "s", "bash", "", &turns);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "OBSERVATION:\\noutput") != null);
}

test "buildRequestBody: assistant_exec turn uses assistant role" {
    var content_buf = [_]u8{ '{', '"', 'a', '"', ':', '1', '}' };
    const turns = [_]Turn{.{ .kind = .assistant_exec, .content = &content_buf }};
    const body = try buildRequestBody(testing.allocator, "m", "s", "bash", "", &turns);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"assistant\"") != null);
}

// ============================================================================
// Module(cfg, Runtime) — Runtime-touching helpers
// ============================================================================
//
// Small, focused helpers that touch `*Runtime` fields directly.
// Five conceptual groups:
//   - turn ring: `pushTurn`, `freeTurns`
//   - captured-output buffer: `appendCaptured`, `advancePastMarker`
//   - status latches: `latchHint`, `latchErr`, `queueInjection`
//   - conclusion banner: `captureConclusion`
//   - dialog teardown: `dialogReset`, `abortDialog`
//
// Larger state-machine functions (`handleResponse`,
// `fireDialogRequest`, …) stay in `llm.zig` — they touch worker
// channels and the dialog state machine in ways that aren't
// purely buffer-shaped.

const types = @import("types.zig");
const paint_width = @import("paint_width.zig");
const parse = @import("parse.zig");

pub fn Module(comptime cfg: types.Config, comptime Runtime: type) type {
    return struct {
        /// 58 box-drawing dashes — used twice by `captureConclusion`
        /// to render symmetric top/bottom borders. Comptime so the
        /// banner width stays a single source of truth.
        const conclusion_border_dashes: []const u8 = "\u{2500}" ** 58;

        /// Push a turn onto the conversation history. `content` must
        /// be heap-allocated by the caller and is OWNED by the
        /// runtime after this call (freed in `freeTurns`). At
        /// `cfg.history_turns_max` capacity, drops the OLDEST turn
        /// first (FIFO eviction) so a long dialog can't grow
        /// unbounded across the runtime's lifetime.
        ///
        /// Ownership contract:
        ///   - SUCCESS path: runtime now owns `content` (or its
        ///     truncated replacement). Caller MUST NOT free.
        ///   - FAILURE path: caller still owns `content`. The only
        ///     failure mode is the truncation `dupe` — error
        ///     propagates BEFORE we'd `free(content)`.
        pub fn pushTurn(rt: *Runtime, kind: TurnKind, content: []u8) !void {
            const final_content: []u8 = if (content.len > cfg.max_turn_bytes) blk: {
                const trimmed = try rt.allocator.dupe(u8, content[0..cfg.max_turn_bytes]);
                rt.allocator.free(content);
                break :blk trimmed;
            } else content;

            if (rt.turns_len == cfg.history_turns_max) {
                rt.allocator.free(rt.turns[0].content);
                for (1..rt.turns_len) |i| {
                    rt.turns[i - 1] = rt.turns[i];
                }
                rt.turns_len -= 1;
            }
            rt.turns[rt.turns_len] = .{ .kind = kind, .content = final_content };
            rt.turns_len += 1;

            // Re-arm whichever chat surface is open so the new turn
            // renders on the next term-bytes tick. Without this an
            // LLM response that lands while the panel is open sits
            // stale until the next keystroke (or polling tick).
            // Mutual exclusion means only one of these flips at a
            // time in practice. `@hasField` makes pushTurn reusable
            // by test fixtures with minimal Runtime shapes.
            if (comptime @hasField(Runtime, "chat_inline_open")) {
                if (rt.chat_inline_open) rt.chat_inline_paint_pending = true;
            }
            if (comptime @hasField(Runtime, "chat_overlay_open")) {
                if (rt.chat_overlay_open) rt.chat_overlay_paint_pending = true;
            }
            // Pin both surfaces back to the live tail. Otherwise a
            // new assistant reply lands invisibly off-screen for any
            // user who had scrolled up.
            if (comptime @hasField(Runtime, "chat_view_offset")) {
                rt.chat_view_offset = 0;
            }
            if (comptime @hasField(Runtime, "chat_inline_view_offset")) {
                rt.chat_inline_view_offset = 0;
            }
        }

        /// Free every turn's content + reset the count. Called on
        /// `detach` and on cancel so a follow-up dialog starts
        /// clean. Safe to call when `turns_len == 0`.
        pub fn freeTurns(rt: *Runtime) void {
            for (rt.turns[0..rt.turns_len]) |turn| {
                rt.allocator.free(turn.content);
            }
            rt.turns_len = 0;
            // Keep the "offset implies turns" invariant — a stale
            // view_offset would otherwise survive a cancel/reset and
            // dangle until the next pushTurn rescues it.
            if (comptime @hasField(Runtime, "chat_view_offset")) {
                rt.chat_view_offset = 0;
            }
            if (comptime @hasField(Runtime, "chat_inline_view_offset")) {
                rt.chat_inline_view_offset = 0;
            }
        }

        /// Append bytes to `captured_output`, respecting the cap.
        /// On overflow, set `captured_truncated = true` so the
        /// observation turn surfaces a `[truncated]` suffix. Bytes
        /// silently drop when the buffer is full — the caller
        /// doesn't need to track room.
        pub fn appendCaptured(rt: *Runtime, bytes: []const u8) void {
            const room = rt.captured_output.len - rt.captured_output_len;
            if (bytes.len > room) {
                rt.captured_truncated = true;
                if (room == 0) return;
                @memcpy(rt.captured_output[rt.captured_output_len..][0..room], bytes[0..room]);
                rt.captured_output_len += room;
                return;
            }
            @memcpy(rt.captured_output[rt.captured_output_len..][0..bytes.len], bytes);
            rt.captured_output_len += bytes.len;
        }

        /// Given a slice and the index of the LEADING ESC of an OSC
        /// marker at `start`, return the index one past the marker's
        /// terminator (BEL or ST `ESC \`). Bounded by `slice.len`.
        /// `onOutput` uses this to resume capture after the marker
        /// without re-parsing it.
        ///
        /// When the terminator doesn't arrive in the current feed
        /// (rare; OSC sequences flush atomically in practice),
        /// resumes at end-of-slice so the next feed doesn't
        /// double-capture marker bytes.
        pub fn advancePastMarker(slice: []const u8, start: u32) u32 {
            const len: u32 = @intCast(slice.len);
            if (start >= len) return len;
            var i: usize = start;
            while (i < slice.len) : (i += 1) {
                if (slice[i] == 0x07) return @intCast(@min(i + 1, slice.len));
                if (slice[i] == 0x1B and i + 1 < slice.len and slice[i + 1] == '\\') {
                    return @intCast(@min(i + 2, slice.len));
                }
            }
            return len;
        }

        /// Synchronously latch a hint string on the Runtime so the
        /// next `provideHintText` tick surfaces it. For
        /// informational content (LLM explanation of the injected
        /// command).
        pub fn latchHint(rt: *Runtime, msg: []const u8) void {
            const n = @min(msg.len, rt.hint_buf.len);
            @memcpy(rt.hint_buf[0..n], msg[0..n]);
            rt.hint_len = n;
            rt.hint_pending = true;
        }

        /// Synchronously latch an error string on the Runtime so
        /// the next `provideErrorText` tick surfaces it (muted red
        /// + ⚠ in the statusbar). Used by the onInput inert path
        /// (no worker involved) and by the test scaffolding.
        pub fn latchErr(rt: *Runtime, msg: []const u8) void {
            const n = @min(msg.len, rt.err_buf.len);
            @memcpy(rt.err_buf[0..n], msg[0..n]);
            rt.err_len = n;
            rt.err_pending = true;
        }

        /// Queue bytes for `pollShellInput` to drain on the next
        /// tick. Used to route `\x15` (Ctrl+U) to the pty after
        /// `onAction` triggers a worker call — `onAction` can't
        /// synchronously modify the stdin path, so it queues the
        /// kill-line byte here and the next poll tick drains it
        /// AHEAD of the response. The compile-time assert pins the
        /// 16-byte invariant: `pending_injection` is fixed for the
        /// Ctrl+U / short-CSI use case; longer sequences need to
        /// grow the buffer at the Runtime declaration first.
        pub fn queueInjection(rt: *Runtime, bytes: []const u8) void {
            std.debug.assert(bytes.len <= rt.pending_injection.len);
            @memcpy(rt.pending_injection[0..bytes.len], bytes);
            rt.pending_injection_len = bytes.len;
        }

        /// Format the LLM session conclusion into a multi-line
        /// banner stored in `conclusion_formatted`. Re-emittable
        /// via Alt+Shift+C (`llm_chat_overlay_toggle`). Surfaced
        /// via `provideTermBytes` in a single-shot emission — the
        /// proxy's `writeAll(STDOUT, ...)` handles arbitrary slice
        /// sizes via posix-level looping, so the banner scrolls
        /// into the shell's normal history above the next prompt
        /// in one terminal frame.
        ///
        /// Format (statusbar-style palette: mauve brand + cyan
        /// accent + dim chrome). Leading `\r\n` so the banner never
        /// glues to the prompt line above it:
        ///
        ///     <blank>
        ///     ╭─ ✨ atty · LLM session complete ─────────────
        ///     │ ✓ <reason>
        ///     │ <N> execs / <N> obs / <N> turns
        ///     ╰──────────────────────────────────────────────
        ///
        /// Allocates a heap buffer sized to the full formatted
        /// content — no fixed cap, no truncation. Frees any
        /// previous capture first (re-capture / new dialog).
        /// Allocation failure is logged to stderr and leaves
        /// `conclusion_formatted = null`. The caller (action=done
        /// handler in hooks.zig) unconditionally arms
        /// `conclusion_pending = true` after this returns; the
        /// paint hook (provideTermBytes) clears the latch when
        /// it sees `formatted == null`, so a banner-skip on alloc
        /// failure recovers cleanly without polling.
        pub fn captureConclusion(rt: *Runtime, reason: []const u8, execs: usize, obs: usize, turns: usize) void {
            // Free any prior capture (re-capture path: same session,
            // second LLM dialog). Lives across `dialogReset` for
            // Alt+Shift+C re-emit, so the only frees are here on
            // overwrite + on detach.
            if (rt.conclusion_formatted) |old| {
                rt.allocator.free(old);
                rt.conclusion_formatted = null;
            }

            // Worst-case sizing: every byte of reason ends up as a
            // separate single-byte line, each taking ~22 bytes of
            // continuation chrome (`│   <byte>\r\n` + dim ANSI), or
            // ~37 bytes for the first row. Plus a fixed ~250 bytes
            // of header chrome, ~110 bytes of counts row, ~190
            // bytes of bottom border + reset. A linear `reason.len
            // * 23 + 1024` is a comfortable upper bound; realistic
            // multi-paragraph reasons stay well under it because
            // the per-line chrome cost is amortised across the
            // line's content.
            const cap = reason.len * 23 + 1024;
            const buf = rt.allocator.alloc(u8, cap) catch {
                const msg = "atty: captureConclusion alloc failed — banner skipped\n";
                _ = std.c.write(2, msg, msg.len);
                return;
            };
            var w: std.Io.Writer = .fixed(buf);

            // Single `\r\n` so the banner starts at column 1 on the
            // row immediately under the shell's prompt redraw — no
            // visible blank rows between the prompt and the banner.
            // The `\r` is critical: bare `\n` only moves down (cursor
            // keeps its column from the prompt), which produced an
            // indented banner that read as broken.
            //
            // Palette (matches statusbar.zig icon + shortcut
            // styling from PR #53):
            //   - fg 141 (mauve): brand glyph + "atty" word
            //   - fg 14 + bold (cyan): success ✓ + the numeric
            //     counts so they jump out of the dim chrome
            //   - dim: border characters, prose
            //
            // Column accounting (for symmetric framing with the
            // bottom border):
            //   ╭(1) + ─(1) + " "(1) = 3 cols of leading chrome
            //   ✨(2 in most fonts) + " atty"(5) = 7 cols of brand
            //   " · LLM session complete "(24) = 24 cols of prose
            //   --- subtotal: 34 cols of fixed prefix ---
            //   25 trailing dashes → 59 cols total
            //   Bottom: ╰(1) + 58 dashes = 59 cols. Matches.
            w.writeAll("\r\n\x1B[2m\u{256D}\u{2500} \x1B[22;38;5;141m\u{2728} atty\x1B[39;2m \u{00B7} LLM session complete ") catch {};
            w.writeAll(conclusion_border_dashes[0..(25 * 3)]) catch {};
            w.writeAll("\x1B[0m\r\n") catch {};

            if (reason.len > 0) {
                // Multi-line reason: each line gets its own `│ `
                // prefix so an LLM prose reply with embedded `\n`
                // renders as proper banner rows. A bare `{s}`
                // print would emit raw LF — terminal advances the
                // row but keeps the column, so the next character
                // (a subsequent banner row OR the closing border)
                // lands wherever the reason left off, with the
                // visible right-drift that motivated this fix.
                var it = std.mem.splitScalar(u8, reason, '\n');
                var first = true;
                while (it.next()) |raw_line| {
                    // Trim trailing `\r` so a CRLF doesn't double-
                    // count, and trim trailing whitespace so a
                    // stray space at the EOL doesn't pad the row.
                    var line = raw_line;
                    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
                    while (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) line = line[0 .. line.len - 1];
                    // Skip empty lines entirely — including any
                    // leading blank lines so the `✓` marker doesn't
                    // land on a `│ ✓ <empty>` row when the reason
                    // starts with `\n`. `first` stays true until a
                    // non-empty line claims the checkmark.
                    if (line.len == 0) continue;
                    if (first) {
                        w.writeAll("\x1B[2m\u{2502}\x1B[0m \x1B[22;1;38;5;14m\u{2713}\x1B[0m ") catch {};
                        // Sanitize: the reason is LLM-controlled,
                        // can contain ESC/C0 bytes from JSON `ESC`
                        // escapes. Without filtering, the model could
                        // emit `ESC[31m` and recolour the user's
                        // prompt or `ESC[2J` and wipe the screen.
                        // writeSanitized strips C0/C1 + collapses
                        // CR/LF (the splitScalar above already split
                        // on `\n`, so any residual control chars are
                        // attacker injection).
                        paint_width.writeSanitized(&w, line) catch {};
                        w.writeAll("\r\n") catch {};
                        first = false;
                    } else {
                        // Continuation rows: `│` + 3 spaces aligns
                        // the prose at col 5, matching the first
                        // row's text position (col 1 vbar + space +
                        // `✓` glyph + space → text starts col 5).
                        w.writeAll("\x1B[2m\u{2502}\x1B[0m   ") catch {};
                        paint_width.writeSanitized(&w, line) catch {};
                        w.writeAll("\r\n") catch {};
                    }
                }
                // All-whitespace reason → no row emitted above. Fall
                // through to the empty-reason `done` row so the
                // banner still has a `│ ✓` line.
                if (first) {
                    w.writeAll("\x1B[2m\u{2502}\x1B[0m \x1B[22;1;38;5;14m\u{2713}\x1B[0m done\r\n") catch {};
                }
            } else {
                w.writeAll("\x1B[2m\u{2502}\x1B[0m \x1B[22;1;38;5;14m\u{2713}\x1B[0m done\r\n") catch {};
            }
            // Counts row: numeric values in bold cyan; word labels in
            // dim prose; separators dim. Reads like a structured
            // metric line rather than free text.
            w.print(
                "\x1B[2m\u{2502}\x1B[0m \x1B[22;1;38;5;14m{d}\x1B[0;2m execs / \x1B[22;1;38;5;14m{d}\x1B[0;2m obs / \x1B[22;1;38;5;14m{d}\x1B[0;2m turns\x1B[0m\r\n",
                .{ execs, obs, turns },
            ) catch {};
            w.writeAll("\x1B[2m\u{2570}") catch {};
            w.writeAll(conclusion_border_dashes[0..(58 * 3)]) catch {};
            w.writeAll("\x1B[0m\r\n") catch {};
            // Shrink the allocation down to the used size. realloc
            // guarantees the returned slice's length matches `used`
            // (either in-place shrink, or a fresh smaller allocation
            // + free of the old) — that's what we need so the
            // matching `allocator.free` in freeConclusion sees the
            // right size. The over-allocation cap is a conservative
            // upper bound; realistic banners shrink by 10-50x.
            //
            // Shrink can theoretically fail (testing allocator with
            // a tight memory regime); on failure we free the
            // original allocation and skip the banner rather than
            // hold an over-sized slice that would mis-match on
            // free(). Banner skipped is preferable to a heap-canary
            // panic.
            const used = w.end;
            if (rt.allocator.realloc(buf, used)) |shrunk| {
                rt.conclusion_formatted = shrunk;
                // Mark the banner as needs-persisting so the
                // dialogReset wrapper appendConclusion-s it exactly
                // once. Without this, a retained banner from a
                // PREVIOUS dialog could leak into the current
                // dialog's session file on cancel/abort.
                if (comptime @hasField(Runtime, "chat_persist_conclusion_pending")) {
                    rt.chat_persist_conclusion_pending = true;
                }
            } else |_| {
                rt.allocator.free(buf);
                const msg = "atty: captureConclusion realloc failed — banner skipped\n";
                _ = std.c.write(2, msg, msg.len);
                return;
            }
        }

        /// Free the heap-owned conclusion buffer. Called from
        /// `detach`. Idempotent — null-buffer is fine.
        pub fn freeConclusion(rt: *Runtime) void {
            if (rt.conclusion_formatted) |buf| {
                rt.allocator.free(buf);
                rt.conclusion_formatted = null;
            }
            rt.conclusion_pending = false;
        }

        /// Reset all dialog state — used by both `abortDialog` and
        /// the `llm_exec_cancel` action. Bumps `req_gen` so any
        /// in-flight worker response is discarded as stale; clears
        /// `req_pending` so a queued-but-not-yet-picked-up request
        /// doesn't fire AFTER the cancel (which would otherwise
        /// burn a wasted API call AND advance `shared.fixture_idx`,
        /// desynchronising the fixture cursor across cancel-aware
        /// e2e scenarios).
        ///
        /// What this does NOT touch: `rt.osc133_capture` is runtime-
        /// scoped (one capture window per shell, not per dialog) and
        /// owned by hooks.zig's OSC 133 stream handler. Its lifecycle
        /// is `attach` → `detach`. Resetting it here would lose the
        /// active prompt-mark window mid-cancel.
        pub fn dialogReset(rt: *Runtime, io: std.Io) void {
            rt.shared.mutex.lockUncancelable(io);
            rt.shared.req_gen +%= 1;
            rt.shared.req_pending = false;
            rt.shared.res_done = false;
            if (rt.shared.res_buf) |old| {
                rt.allocator.free(old);
                rt.shared.res_buf = null;
            }
            rt.shared.res_len = 0;
            rt.shared.request_session_id_len = 0;
            rt.shared.response_session_id_len = 0;
            rt.shared.mutex.unlock(io);

            freeTurns(rt);
            // The CLI-side session id is a per-dialog handle —
            // cancelling or completing the dialog means the next
            // turn should start a fresh CLI session, not resume the
            // dead one.
            if (rt.session_id.len > 0) {
                rt.allocator.free(rt.session_id);
                rt.session_id = &.{};
            }
            rt.dialog_state = .idle;
            rt.captured_output_len = 0;
            rt.captured_truncated = false;
            rt.pending_command_len = 0;
            rt.pending_description_len = 0;
            rt.dialog_parse_retry_count = 0;
            rt.question_choices_count = 0;
            // Chat-mode question pick-list state (#214) clears too —
            // a fresh dialog supersedes any pending question UI.
            rt.chat_question_active = false;
            rt.chat_question_choice_count = 0;
            rt.chat_question_selected_idx = 0;
            // Disarm the conclusion auto-emit latch — but keep the
            // captured `conclusion_formatted` so `Alt+Shift+C` can
            // still recall the LAST completed session even if this
            // reset was a cancel. The `.done` path explicitly RE-arms
            // the latch AFTER calling dialogReset (see captureConclusion
            // site).
            rt.conclusion_pending = false;
            rt.in_flight = false;
            rt.auto_mode_active = false;
            rt.auto_exec_armed = false;
            // Cancel / done shouldn't snap focus back to chat —
            // #167's refocus latch is only valid on the
            // command-runs-cleanly path. Clearing keeps focus
            // wherever the user last had it.
            rt.chat_refocus_pending = false;
            // Hard reset wipes turns; the retry banner has nothing
            // to resend after this so drop it. (The soft variant
            // deliberately preserves it.)
            rt.chat_retry_pending = false;
        }

        /// Soft reset for retry-eligible failures (worker timeout,
        /// transport hiccup, dialog n==0). Clears the shared
        /// req/res slots + in-flight flag so the next request can
        /// fire cleanly, but PRESERVES `rt.turns` and `rt.session_id`
        /// so the user can press the retry binding and the LLM
        /// continues the same conversation from where it stalled.
        /// `dialogReset` (the full variant) wipes both — appropriate
        /// for user-initiated cancels and unrecoverable parse
        /// failures, NOT for transient network failures where the
        /// user's last typed turn is still on screen and the
        /// expected UX is "press a key, try again."
        pub fn dialogResetSoft(rt: *Runtime, io: std.Io) void {
            rt.shared.mutex.lockUncancelable(io);
            rt.shared.req_gen +%= 1;
            rt.shared.req_pending = false;
            rt.shared.res_done = false;
            if (rt.shared.res_buf) |old| {
                rt.allocator.free(old);
                rt.shared.res_buf = null;
            }
            rt.shared.res_len = 0;
            rt.shared.request_session_id_len = 0;
            rt.shared.response_session_id_len = 0;
            rt.shared.mutex.unlock(io);

            rt.dialog_state = .idle;
            rt.captured_output_len = 0;
            rt.captured_truncated = false;
            rt.pending_command_len = 0;
            rt.pending_description_len = 0;
            rt.dialog_parse_retry_count = 0;
            // Both question state stripes — the storage count
            // (`question_choices_count`) AND the chat-mode pick-list
            // UI count (`chat_question_choice_count`). Must mirror
            // `dialogReset`'s coverage at lines 1151-1156 — if a new
            // question-related field gets added to that list, mirror
            // here too. Drift between the two reset paths leaks
            // stale UI state into the next dialog.
            rt.question_choices_count = 0;
            rt.chat_question_active = false;
            rt.chat_question_choice_count = 0;
            rt.chat_question_selected_idx = 0;
            rt.conclusion_pending = false;
            rt.in_flight = false;
            rt.auto_exec_armed = false;
            rt.chat_refocus_pending = false;
            // DELIBERATELY NOT touched:
            //   - rt.turns      → user's last prompt stays visible.
            //   - rt.session_id → retry resumes the same CLI session.
            //   - rt.auto_mode_active → user's auto/dialog choice persists.
            //   - rt.chat_retry_pending → set/cleared by the caller
            //     (handleDialogResponse arms it after this reset;
            //     the Alt+r action handler clears it after firing).
        }

        /// Abort the dialog with an error notification. Surfaces in
        /// the ⚠ row and resets to idle. Used for unrecoverable
        /// states mid-loop (OOM, body too large, malformed JSON
        /// from the model on second attempt).
        pub fn abortDialog(rt: *Runtime, io: std.Io, msg: []const u8) void {
            latchErr(rt, msg);
            dialogReset(rt, io);
            rt.ai_mode_active = false;
            queueInjection(rt, "\x15");
        }
    };
}

test "Module.captureConclusion writes reason + counts into the buffer" {
    // Minimal Runtime stand-in — captureConclusion only touches
    // these two fields, so we don't need to spin up the full
    // module Runtime for a snapshot test.
    const FakeRuntime = struct {
        allocator: std.mem.Allocator,
        conclusion_formatted: ?[]u8 = null,
        conclusion_pending: bool = false,
    };
    const M = Module(types.Config{}, FakeRuntime);

    var rt: FakeRuntime = .{ .allocator = testing.allocator };
    defer M.freeConclusion(&rt);
    M.captureConclusion(&rt, "stopped at user request", 3, 2, 7);
    const out = rt.conclusion_formatted.?;

    try testing.expect(std.mem.indexOf(u8, out, "atty") != null);
    try testing.expect(std.mem.indexOf(u8, out, "LLM session complete") != null);
    try testing.expect(std.mem.indexOf(u8, out, "stopped at user request") != null);
    // Counts row interleaves SGR escapes between the numbers and
    // their word labels (styled palette pass) — assert individual
    // tokens rather than the joined string.
    try testing.expect(std.mem.indexOf(u8, out, "3") != null);
    try testing.expect(std.mem.indexOf(u8, out, "execs") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "obs") != null);
    try testing.expect(std.mem.indexOf(u8, out, "7") != null);
    try testing.expect(std.mem.indexOf(u8, out, "turns") != null);
    // Box-drawing corners + dim SGR for the chrome.
    try testing.expect(std.mem.indexOf(u8, out, "\u{256D}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\u{2570}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[2m") != null);
    // Styled palette: mauve brand glyph + cyan success accent.
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[22;38;5;141m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[22;1;38;5;14m") != null);
    // Single `\r\n` so the banner attaches directly to the next row
    // at column 1 (no blank gap, no carry-over indent from the
    // prompt's cursor column).
    try testing.expect(std.mem.startsWith(u8, out, "\r\n"));
    try testing.expect(!std.mem.startsWith(u8, out, "\n\n"));
}

test "Module.captureConclusion wraps multi-line reason — every row keeps the `│ ` prefix" {
    // Regression for the right-drift bug: when `reason` contains
    // embedded `\n`, a bare `{s}` print emitted raw LF — the
    // terminal moved cursor down without resetting column, so
    // subsequent banner rows drifted right and the closing border
    // landed mid-text. Now each line gets its own `│ ` prefix +
    // `\r\n`.
    const FakeRuntime = struct {
        allocator: std.mem.Allocator,
        conclusion_formatted: ?[]u8 = null,
        conclusion_pending: bool = false,
    };
    const M = Module(types.Config{}, FakeRuntime);

    var rt: FakeRuntime = .{ .allocator = testing.allocator };
    defer M.freeConclusion(&rt);
    const multiline =
        \\Here's what I can see:
        \\- Shell: bash
        \\- PWD: /home/user
    ;
    M.captureConclusion(&rt, multiline, 0, 0, 1);
    const out = rt.conclusion_formatted.?;

    // No raw LF inside the banner (every newline must be `\r\n`).
    // The opening `\r\n` IS preceded by `\r`, so a pure LF would
    // appear only inside the content section if the bug regressed.
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        if (out[i] == '\n') {
            try testing.expect(i > 0);
            try testing.expectEqual(@as(u8, '\r'), out[i - 1]);
        }
    }

    // Each prose line appears in the output. First line carries the
    // ✓ marker; continuations indent under it.
    try testing.expect(std.mem.indexOf(u8, out, "Here's what I can see:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- Shell: bash") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- PWD: /home/user") != null);

    // Exactly four `│` rows in the buffer: three reason lines
    // (split on `\n`) + one counts line. A loose lower bound
    // would let regressions (stray empty `│` row from a trailing
    // newline) slip through.
    var vbar_count: usize = 0;
    var j: usize = 0;
    while (j + 2 < out.len) : (j += 1) {
        if (out[j] == 0xE2 and out[j + 1] == 0x94 and out[j + 2] == 0x82) vbar_count += 1;
    }
    try testing.expectEqual(@as(usize, 4), vbar_count);
}

test "Module.captureConclusion two-line reason with trailing newline → 2 reason rows" {
    // `splitScalar("first\nsecond\n", '\n')` yields
    // `["first", "second", ""]`. The empty trailing element gets
    // skipped — no stray blank `│` row inside the banner.
    const FakeRuntime = struct {
        allocator: std.mem.Allocator,
        conclusion_formatted: ?[]u8 = null,
        conclusion_pending: bool = false,
    };
    const M = Module(types.Config{}, FakeRuntime);

    var rt: FakeRuntime = .{ .allocator = testing.allocator };
    defer M.freeConclusion(&rt);
    M.captureConclusion(&rt, "first\nsecond\n", 0, 0, 1);
    const out = rt.conclusion_formatted.?;

    // 2 reason rows + 1 counts row = exactly 3 `│` glyphs.
    var vbar_count: usize = 0;
    var j: usize = 0;
    while (j + 2 < out.len) : (j += 1) {
        if (out[j] == 0xE2 and out[j + 1] == 0x94 and out[j + 2] == 0x82) vbar_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), vbar_count);
}

test "Module.captureConclusion all-whitespace reason → falls back to bare ✓ done row" {
    // Edge case: a reason of pure `\n`s would leave `first` true
    // after the loop. The fall-through emits the empty-reason
    // `│ ✓ done` row so the banner still has its required
    // checkmark line.
    const FakeRuntime = struct {
        allocator: std.mem.Allocator,
        conclusion_formatted: ?[]u8 = null,
        conclusion_pending: bool = false,
    };
    const M = Module(types.Config{}, FakeRuntime);

    var rt: FakeRuntime = .{ .allocator = testing.allocator };
    defer M.freeConclusion(&rt);
    M.captureConclusion(&rt, "\n\n\n", 0, 0, 0);
    const out = rt.conclusion_formatted.?;

    // Exactly two `│` rows (✓ done + counts) — no stray blanks.
    var vbar_count: usize = 0;
    var j: usize = 0;
    while (j + 2 < out.len) : (j += 1) {
        if (out[j] == 0xE2 and out[j + 1] == 0x94 and out[j + 2] == 0x82) vbar_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), vbar_count);
    try testing.expect(std.mem.indexOf(u8, out, "done") != null);
}

test "Module.captureConclusion falls back to 'done' when reason is empty" {
    const FakeRuntime = struct {
        allocator: std.mem.Allocator,
        conclusion_formatted: ?[]u8 = null,
        conclusion_pending: bool = false,
    };
    const M = Module(types.Config{}, FakeRuntime);

    var rt: FakeRuntime = .{ .allocator = testing.allocator };
    defer M.freeConclusion(&rt);
    M.captureConclusion(&rt, "", 1, 0, 2);
    const out = rt.conclusion_formatted.?;

    // ✓ glyph + "done" appear separately because cyan-accent SGR
    // wraps the glyph only.
    try testing.expect(std.mem.indexOf(u8, out, "\u{2713}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "done") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "execs") != null);
}

test "Module.captureConclusion: 32 KiB reason allocates the full content (no truncation)" {
    // Locks in the heap-allocated `conclusion_formatted` buffer
    // semantics: there is NO cap on the reason size; the proxy's
    // writeAll handles arbitrary slice sizes via posix-level
    // looping, so a single `provideTermBytes` return is correct.
    // Earlier shapes used a fixed-size array that silently
    // truncated realistic LLM replies; this regression test
    // ensures we never re-introduce one.
    const FakeRuntime = struct {
        allocator: std.mem.Allocator,
        conclusion_formatted: ?[]u8 = null,
        conclusion_pending: bool = false,
    };
    const M = Module(types.Config{}, FakeRuntime);

    var rt: FakeRuntime = .{ .allocator = testing.allocator };
    defer M.freeConclusion(&rt);

    var reason_buf: [32 * 1024]u8 = undefined;
    @memset(&reason_buf, 'x');
    M.captureConclusion(&rt, reason_buf[0..], 2, 1, 3);

    // The whole reason landed in conclusion_formatted contiguously.
    const formatted = rt.conclusion_formatted.?;
    try testing.expect(formatted.len > reason_buf.len); // chrome adds bytes
    try testing.expect(std.mem.indexOf(u8, formatted, reason_buf[0..]) != null);

    // Footer still emits — counts + bottom border are in the
    // formatted slice regardless of reason size.
    try testing.expect(std.mem.indexOf(u8, formatted, "execs") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "turns") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "\u{2570}") != null); // ╰
}

test "Module.captureConclusion replaces previous capture (re-capture)" {
    // Two consecutive LLM dialogs in the same session — second
    // captureConclusion must free the previous buffer (no leak,
    // testing.allocator catches double-frees and leaks).
    const FakeRuntime = struct {
        allocator: std.mem.Allocator,
        conclusion_formatted: ?[]u8 = null,
        conclusion_pending: bool = false,
    };
    const M = Module(types.Config{}, FakeRuntime);

    var rt: FakeRuntime = .{ .allocator = testing.allocator };
    defer M.freeConclusion(&rt);

    M.captureConclusion(&rt, "first dialog", 1, 0, 1);
    M.captureConclusion(&rt, "second dialog with longer reason for fun", 2, 1, 2);
    // Second capture wins; first dialog text is gone from buffer.
    // `testing.allocator` catches a missing free of the first
    // buffer (the leak detector flags it at test teardown); the
    // assertion below catches the data-replacement bug (where we
    // freed the first but didn't write the second). Pointer
    // identity isn't a useful assertion — GPA may reuse the
    // same address for the realloc of equivalent sizes.
    const formatted = rt.conclusion_formatted.?;
    try testing.expect(std.mem.indexOf(u8, formatted, "second dialog") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "first dialog") == null);
}

test "Module.freeConclusion is idempotent and safe on null capture" {
    const FakeRuntime = struct {
        allocator: std.mem.Allocator,
        conclusion_formatted: ?[]u8 = null,
        conclusion_pending: bool = false,
    };
    const M = Module(types.Config{}, FakeRuntime);

    var rt: FakeRuntime = .{ .allocator = testing.allocator };
    // No capture — freeConclusion must be a no-op (no panic, no
    // double-free).
    M.freeConclusion(&rt);
    M.freeConclusion(&rt);
    try testing.expect(rt.conclusion_formatted == null);

    // After a capture, freeConclusion clears + frees; second call
    // is still safe.
    M.captureConclusion(&rt, "x", 0, 0, 0);
    try testing.expect(rt.conclusion_formatted != null);
    M.freeConclusion(&rt);
    try testing.expect(rt.conclusion_formatted == null);
    try testing.expect(!rt.conclusion_pending);
    // Idempotent.
    M.freeConclusion(&rt);
}

// Tiny config + FakeRuntime fixture for pushTurn / freeTurns tests.
// `history_turns_max=3` so we can exercise FIFO eviction with a
// reasonable byte budget; `max_turn_bytes=8` so we can exercise
// truncation with short, readable test strings.
fn TurnTestFixture(comptime hmax: comptime_int, comptime tmax: comptime_int) type {
    const Cfg: types.Config = .{ .history_turns_max = hmax, .max_turn_bytes = tmax };
    return struct {
        pub const FakeRuntime = struct {
            allocator: std.mem.Allocator,
            turns: [hmax]Turn = undefined,
            turns_len: usize = 0,
        };
        pub const M = Module(Cfg, FakeRuntime);
    };
}

test "Module.pushTurn truncates content longer than cfg.max_turn_bytes" {
    const F = TurnTestFixture(3, 8);
    var rt: F.FakeRuntime = .{ .allocator = testing.allocator };
    defer F.M.freeTurns(&rt);

    const long = try testing.allocator.dupe(u8, "1234567890");
    try F.M.pushTurn(&rt, .user, long);

    try testing.expectEqual(@as(usize, 1), rt.turns_len);
    try testing.expectEqual(@as(usize, 8), rt.turns[0].content.len);
    try testing.expectEqualStrings("12345678", rt.turns[0].content);
}

test "Module.pushTurn keeps content shorter than cap untouched" {
    const F = TurnTestFixture(3, 8);
    var rt: F.FakeRuntime = .{ .allocator = testing.allocator };
    defer F.M.freeTurns(&rt);

    const short = try testing.allocator.dupe(u8, "hi");
    try F.M.pushTurn(&rt, .user, short);

    try testing.expectEqual(@as(usize, 1), rt.turns_len);
    try testing.expectEqualStrings("hi", rt.turns[0].content);
}

test "Module.pushTurn at exactly max_turn_bytes takes the no-copy branch" {
    // Boundary: the truncation branch uses strict `>`, so content
    // exactly at the cap should pass through untouched. Locks in
    // the `>` vs `>=` distinction the ownership contract relies on.
    const F = TurnTestFixture(3, 8);
    var rt: F.FakeRuntime = .{ .allocator = testing.allocator };
    defer F.M.freeTurns(&rt);

    const at_cap = try testing.allocator.dupe(u8, "12345678");
    try F.M.pushTurn(&rt, .user, at_cap);

    try testing.expectEqual(@as(usize, 1), rt.turns_len);
    try testing.expectEqual(@as(usize, 8), rt.turns[0].content.len);
    try testing.expectEqualStrings("12345678", rt.turns[0].content);
    // The runtime now owns the exact same allocation we passed in
    // (no truncation `dupe + free` round-trip).
    try testing.expectEqual(at_cap.ptr, rt.turns[0].content.ptr);
}

test "Module.pushTurn FIFO-evicts the oldest turn at capacity" {
    const F = TurnTestFixture(3, 32);
    var rt: F.FakeRuntime = .{ .allocator = testing.allocator };
    defer F.M.freeTurns(&rt);

    try F.M.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "first"));
    try F.M.pushTurn(&rt, .assistant_exec, try testing.allocator.dupe(u8, "second"));
    try F.M.pushTurn(&rt, .observation, try testing.allocator.dupe(u8, "third"));
    try testing.expectEqual(@as(usize, 3), rt.turns_len);

    try F.M.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "fourth"));

    // "first" was evicted; the ring is now [second, third, fourth].
    try testing.expectEqual(@as(usize, 3), rt.turns_len);
    try testing.expectEqualStrings("second", rt.turns[0].content);
    try testing.expectEqualStrings("third", rt.turns[1].content);
    try testing.expectEqualStrings("fourth", rt.turns[2].content);
    // Kind tags shifted with the contents.
    try testing.expectEqual(TurnKind.assistant_exec, rt.turns[0].kind);
    try testing.expectEqual(TurnKind.observation, rt.turns[1].kind);
    try testing.expectEqual(TurnKind.user, rt.turns[2].kind);
}

test "Module.freeTurns frees every entry and resets the count" {
    const F = TurnTestFixture(3, 32);
    var rt: F.FakeRuntime = .{ .allocator = testing.allocator };

    try F.M.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "a"));
    try F.M.pushTurn(&rt, .user, try testing.allocator.dupe(u8, "b"));
    try testing.expectEqual(@as(usize, 2), rt.turns_len);

    F.M.freeTurns(&rt);
    try testing.expectEqual(@as(usize, 0), rt.turns_len);
    // Safe to call on an empty ring.
    F.M.freeTurns(&rt);
}

test "parseFencedResponse: exec with multi-line body + prose description" {
    const R = Response(4096);
    var r: R = .{};
    const raw =
        \\I'll snapshot the env and the last three commits.
        \\
        \\```exec
        \\echo "PWD=$PWD"
        \\echo "SHELL=$SHELL"
        \\git log --oneline -3
        \\```
    ;
    parseFencedResponse(R, raw, &r);
    try testing.expectEqual(Action.exec, r.action);
    try testing.expectEqualStrings(
        \\echo "PWD=$PWD"
        \\echo "SHELL=$SHELL"
        \\git log --oneline -3
    , r.command());
    try testing.expectEqualStrings("I'll snapshot the env and the last three commits.", r.description());
}

test "parseFencedResponse: done with reason" {
    const R = Response(4096);
    var r: R = .{};
    const raw =
        \\All tests pass.
        \\
        \\```done
        \\test suite green on this branch
        \\```
    ;
    parseFencedResponse(R, raw, &r);
    try testing.expectEqual(Action.done, r.action);
    try testing.expectEqualStrings("test suite green on this branch", r.reason());
}

test "parseFencedResponse: question with choices" {
    const R = Response(4096);
    var r: R = .{};
    const raw =
        \\```question
        \\How should we handle the broken commit?
        \\- Revert it
        \\- Amend and force-push
        \\- Roll back the branch
        \\```
    ;
    parseFencedResponse(R, raw, &r);
    try testing.expectEqual(Action.question, r.action);
    try testing.expectEqualStrings("How should we handle the broken commit?", r.question());
    try testing.expectEqual(@as(usize, 3), r.choices_count);
    try testing.expectEqualStrings("Revert it", r.choice(0));
    try testing.expectEqualStrings("Amend and force-push", r.choice(1));
    try testing.expectEqualStrings("Roll back the branch", r.choice(2));
}

test "parseFencedResponse: no fence → done with full text as reason" {
    const R = Response(4096);
    var r: R = .{};
    const raw = "Just chatting about how the test suite looks today. No action needed.";
    parseFencedResponse(R, raw, &r);
    try testing.expectEqual(Action.done, r.action);
    try testing.expectEqualStrings(raw, r.reason());
}

test "parseFencedResponse: lang aliases bash/sh/shell → exec" {
    const R = Response(4096);
    inline for (.{ "bash", "sh", "shell", "EXEC" }) |lang| {
        var r: R = .{};
        const raw = "```" ++ lang ++ "\nls -la\n```";
        parseFencedResponse(R, raw, &r);
        try testing.expectEqual(Action.exec, r.action);
        try testing.expectEqualStrings("ls -la", r.command());
    }
}

test "parseFencedResponse: last fence wins when multiple are present" {
    const R = Response(4096);
    var r: R = .{};
    const raw =
        \\For example you'd write:
        \\
        \\```exec
        \\echo example
        \\```
        \\
        \\But what I actually want to run is:
        \\
        \\```exec
        \\echo real
        \\```
    ;
    parseFencedResponse(R, raw, &r);
    try testing.expectEqual(Action.exec, r.action);
    try testing.expectEqualStrings("echo real", r.command());
}

test "parseFencedResponse: missing closing fence — body extends to EOF" {
    const R = Response(4096);
    var r: R = .{};
    const raw = "```exec\nzig build test 2>&1 | tail -5";
    parseFencedResponse(R, raw, &r);
    try testing.expectEqual(Action.exec, r.action);
    try testing.expectEqualStrings("zig build test 2>&1 | tail -5", r.command());
}

test "parseFencedResponse: numbered + asterisk choices both parse" {
    const R = Response(4096);
    var r: R = .{};
    const raw =
        \\```question
        \\Pick one:
        \\1. first option
        \\* second option
        \\- third option
        \\```
    ;
    parseFencedResponse(R, raw, &r);
    try testing.expectEqual(Action.question, r.action);
    try testing.expectEqual(@as(usize, 3), r.choices_count);
    try testing.expectEqualStrings("first option", r.choice(0));
    try testing.expectEqualStrings("second option", r.choice(1));
    try testing.expectEqualStrings("third option", r.choice(2));
}

test "parseFencedResponse: zsh lang alias maps to exec" {
    const R = Response(4096);
    var r: R = .{};
    parseFencedResponse(R, "```zsh\nls -la\n```", &r);
    try testing.expectEqual(Action.exec, r.action);
    try testing.expectEqualStrings("ls -la", r.command());
}

test "parseFencedResponse: multi-paragraph question prompt before bullets" {
    const R = Response(4096);
    var r: R = .{};
    const raw =
        \\```question
        \\We need to decide how to handle this rebase.
        \\
        \\The branch has 12 commits and master has moved 30 commits forward.
        \\
        \\- Rebase interactively (long but clean)
        \\- Squash everything into one commit then rebase
        \\- Cherry-pick the changes onto master directly
        \\```
    ;
    parseFencedResponse(R, raw, &r);
    try testing.expectEqual(Action.question, r.action);
    // Question prompt keeps the multi-paragraph shape (both
    // sentences before the first bullet).
    try testing.expect(std.mem.indexOf(u8, r.question(), "12 commits and master") != null);
    try testing.expectEqual(@as(usize, 3), r.choices_count);
}

test "wrapForBracketedPaste: single line passes through unchanged (no markers)" {
    var buf: [256]u8 = undefined;
    const n = wrapForBracketedPaste("ls -la", &buf);
    try testing.expectEqualStrings("ls -la", buf[0..n]);
}

test "wrapForBracketedPaste: empty input returns 0" {
    var buf: [16]u8 = undefined;
    const n = wrapForBracketedPaste("", &buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "wrapForBracketedPaste: multi-line wraps with [200~ … [201~ markers" {
    var buf: [256]u8 = undefined;
    const src = "echo a\necho b\necho c";
    const n = wrapForBracketedPaste(src, &buf);
    try testing.expectEqualStrings(
        "\x1B[200~echo a\necho b\necho c\x1B[201~",
        buf[0..n],
    );
}

test "wrapForBracketedPaste: heredoc stays verbatim inside the wrap" {
    var buf: [256]u8 = undefined;
    const src = "cat <<EOF\nhello\nEOF\necho done";
    const n = wrapForBracketedPaste(src, &buf);
    // Newlines preserved → heredoc body lands literally in
    // readline's input; user sees the full script and runs with
    // one Enter.
    const got = buf[0..n];
    try testing.expect(std.mem.startsWith(u8, got, "\x1B[200~"));
    try testing.expect(std.mem.endsWith(u8, got, "\x1B[201~"));
    try testing.expect(std.mem.indexOf(u8, got, "cat <<EOF\nhello\nEOF\necho done") != null);
}

test "wrapForBracketedPaste: inline `#` comment + multi-line stays intact" {
    var buf: [256]u8 = undefined;
    // The wrap is transparent to comments — readline reads the
    // newline as literal so the second line lands as the next
    // line of the input buffer, not as an Enter that the bash
    // comment would have swallowed.
    const src = "echo a # tag\necho b";
    const n = wrapForBracketedPaste(src, &buf);
    try testing.expectEqualStrings(
        "\x1B[200~echo a # tag\necho b\x1B[201~",
        buf[0..n],
    );
}

test "wrapForBracketedPaste: CRLF input normalizes to LF inside the wrap" {
    var buf: [256]u8 = undefined;
    // Many bracketed-paste consumers treat both `\r` and `\n` as
    // newline, so a CRLF-emitting LLM would land each pair as a
    // BLANK line in readline. Strip the `\r` before write.
    const src = "echo a\r\necho b\r\necho c";
    const n = wrapForBracketedPaste(src, &buf);
    try testing.expectEqualStrings(
        "\x1B[200~echo a\necho b\necho c\x1B[201~",
        buf[0..n],
    );
    // Belt-and-braces — no stray `\r` survived.
    try testing.expect(std.mem.indexOfScalar(u8, buf[0..n], '\r') == null);
}

test "wrapForBracketedPaste: a lone `\\r` (not followed by \\n) stays intact" {
    var buf: [256]u8 = undefined;
    // `\r` mid-content (e.g. `printf` argument) is NOT a line break;
    // only the `\r\n` pair is normalized.
    const src = "echo a\r\nprintf '\\rfoo'\n";
    const n = wrapForBracketedPaste(src, &buf);
    const got = buf[0..n];
    try testing.expect(std.mem.startsWith(u8, got, "\x1B[200~"));
    try testing.expect(std.mem.endsWith(u8, got, "\x1B[201~"));
    // CRLF stripped...
    try testing.expect(std.mem.indexOf(u8, got, "echo a\necho") == null); // not chained
    try testing.expect(std.mem.indexOf(u8, got, "echo a\nprintf") != null);
    // ...but the lone `\r` in printf's argument survives.
    try testing.expect(std.mem.indexOf(u8, got, "'\\rfoo'") != null);
}

test "wrapForBracketedPaste: dest exactly src.len + 12 fits the wrap" {
    var buf: [25]u8 = undefined;
    const src = "echo a\necho b";
    try testing.expectEqual(@as(usize, 25), src.len + 12);
    const n = wrapForBracketedPaste(src, &buf);
    try testing.expectEqual(@as(usize, 25), n);
    try testing.expectEqualStrings("\x1B[200~echo a\necho b\x1B[201~", buf[0..n]);
}

test "wrapForBracketedPaste: buffer overflow falls back to verbatim" {
    var buf: [10]u8 = undefined;
    // 12-byte wrap + 13-byte src = 25 bytes; buf is 10. Fallback
    // truncates the multi-line content but doesn't emit a half-wrap
    // (which would leave the terminal in paste-mode forever).
    const src = "echo a\necho b";
    const n = wrapForBracketedPaste(src, &buf);
    try testing.expect(n <= buf.len);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1B[200~") == null);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1B[201~") == null);
}

test "wrapForBracketedPaste: realistic batch from user bug report" {
    var buf: [1024]u8 = undefined;
    const src =
        "echo \"=== process check ===\" && pgrep -af vpn-border.sh\n" ++
        "echo \"=== nmcli active connections ===\" && nmcli -t -f NAME,TYPE,STATE connection show --active\n" ++
        "echo \"=== current border color ===\" && hyprctl getoption general:col.active_border | head -5";
    const n = wrapForBracketedPaste(src, &buf);
    const got = buf[0..n];
    // Every line shows up with its newline preserved — readline
    // gets all three rows as one paste, runs them as a single
    // pending command on Enter.
    try testing.expect(std.mem.startsWith(u8, got, "\x1B[200~"));
    try testing.expect(std.mem.endsWith(u8, got, "\x1B[201~"));
    try testing.expect(std.mem.indexOf(u8, got, "pgrep -af vpn-border.sh\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "show --active\n") != null);
    try testing.expect(std.mem.endsWith(u8, got, "head -5\x1B[201~"));
}
