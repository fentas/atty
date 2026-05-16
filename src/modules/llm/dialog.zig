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
/// (`question`), or stop (`done`). Matches the JSON envelope's
/// `action` field.
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
        reason_buf: [256]u8 = undefined,
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
        const n = @min(c.len, out.command_buf.len);
        @memcpy(out.command_buf[0..n], c[0..n]);
        out.command_len = n;
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
    try testing.expectEqual(@as(usize, 256), r.reason_buf.len);
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
        }

        /// Free every turn's content + reset the count. Called on
        /// `detach` and on cancel so a follow-up dialog starts
        /// clean. Safe to call when `turns_len == 0`.
        pub fn freeTurns(rt: *Runtime) void {
            for (rt.turns[0..rt.turns_len]) |turn| {
                rt.allocator.free(turn.content);
            }
            rt.turns_len = 0;
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
        /// banner stored in `conclusion_buf`. Re-emittable via Alt+C
        /// (`llm_chat_overlay_toggle`). Surfaced via
        /// `provideTermBytes`; the banner scrolls into the shell's
        /// normal history above the next prompt — no DECSTBM resize
        /// needed.
        ///
        /// Format (statusbar-style palette: mauve brand + cyan
        /// accent + dim chrome). Leading `\n\n` so the banner never
        /// glues to the prompt line above it:
        ///
        ///     <blank>
        ///     ╭─ ✨ atty · LLM session complete ─────────────
        ///     │ ✓ <reason>
        ///     │ <N> execs / <N> obs / <N> turns
        ///     ╰──────────────────────────────────────────────
        ///
        /// Reason truncates to fit within `conclusion_buf` (1024
        /// bytes); realistic reasons are 100-200 bytes.
        pub fn captureConclusion(rt: *Runtime, reason: []const u8, execs: usize, obs: usize, turns: usize) void {
            var w: std.Io.Writer = .fixed(&rt.conclusion_buf);
            // Two leading newlines so the banner sits in its own
            // visual block — without them it glues to the previous
            // prompt's command output / cursor position.
            //
            // Palette (matches statusbar.zig icon + shortcut
            // styling from PR #53):
            //   - fg 141 (mauve): brand glyph + "atty" word
            //   - fg 14 + bold (cyan): success ✓ + the numeric
            //     counts so they jump out of the dim chrome
            //   - dim: border characters, prose
            //
            // Combined CSI form throughout (`\x1B[22;38;5;141m`)
            // — saves bytes vs separated escapes, matches the
            // statusbar's compression pattern.
            //
            // Top line: dim corner + dim dash + space + MAUVE
            // "✨ atty" + dim "· LLM session complete " + dim
            // dashes. 28 trailing dashes for symmetry with the
            // 58-dash bottom border (31 visible cols of brand +
            // ~28 dashes ≈ 60 col visible width).
            w.writeAll("\n\n\x1B[2m\u{256D}\u{2500} \x1B[22;38;5;141m\u{2728} atty\x1B[39;2m \u{00B7} LLM session complete ") catch {};
            w.writeAll(conclusion_border_dashes[0..(28 * 3)]) catch {};
            w.writeAll("\x1B[0m\r\n") catch {};

            if (reason.len > 0) {
                w.print("\x1B[2m\u{2502}\x1B[0m \x1B[22;1;38;5;14m\u{2713}\x1B[0m {s}\r\n", .{reason}) catch {};
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
            rt.conclusion_len = w.end;
        }

        /// Reset all dialog state — used by both `abortDialog` and
        /// the `llm_exec_cancel` action. Bumps `req_gen` so any
        /// in-flight worker response is discarded as stale; clears
        /// `req_pending` so a queued-but-not-yet-picked-up request
        /// doesn't fire AFTER the cancel (which would otherwise
        /// burn a wasted API call AND advance `shared.fixture_idx`,
        /// desynchronising the fixture cursor across cancel-aware
        /// e2e scenarios).
        pub fn dialogReset(rt: *Runtime, io: std.Io) void {
            rt.shared.mutex.lockUncancelable(io);
            rt.shared.req_gen +%= 1;
            rt.shared.req_pending = false;
            rt.shared.res_done = false;
            rt.shared.res_len = 0;
            rt.shared.mutex.unlock(io);

            freeTurns(rt);
            rt.dialog_state = .idle;
            rt.captured_output_len = 0;
            rt.captured_truncated = false;
            rt.pending_command_len = 0;
            rt.pending_description_len = 0;
            rt.last_assistant_json_len = 0;
            rt.dialog_parse_retry_count = 0;
            rt.question_choices_count = 0;
            // Disarm the conclusion auto-emit latch — but keep the
            // captured `conclusion_buf` so `Alt+C` can still recall
            // the LAST completed session even if this reset was a
            // cancel. The `.done` path explicitly RE-arms the latch
            // AFTER calling dialogReset (see the captureConclusion
            // site).
            rt.conclusion_pending = false;
            rt.in_flight = false;
            rt.auto_mode_active = false;
            rt.auto_exec_armed = false;
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
        conclusion_buf: [1024]u8 = undefined,
        conclusion_len: usize = 0,
    };
    const M = Module(types.Config{}, FakeRuntime);

    var rt: FakeRuntime = .{};
    M.captureConclusion(&rt, "stopped at user request", 3, 2, 7);
    const out = rt.conclusion_buf[0..rt.conclusion_len];

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
    // Two leading newlines so the banner stays separated from the
    // prompt line above it.
    try testing.expect(std.mem.startsWith(u8, out, "\n\n"));
}

test "Module.captureConclusion falls back to 'done' when reason is empty" {
    const FakeRuntime = struct {
        conclusion_buf: [1024]u8 = undefined,
        conclusion_len: usize = 0,
    };
    const M = Module(types.Config{}, FakeRuntime);

    var rt: FakeRuntime = .{};
    M.captureConclusion(&rt, "", 1, 0, 2);
    const out = rt.conclusion_buf[0..rt.conclusion_len];

    // ✓ glyph + "done" appear separately because cyan-accent SGR
    // wraps the glyph only.
    try testing.expect(std.mem.indexOf(u8, out, "\u{2713}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "done") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "execs") != null);
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
