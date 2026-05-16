//! Dialog-mode types + pure helpers extracted from `llm.zig`.
//!
//! The dialog-mode state machine (Alt+S / Alt+Shift+S) lives in
//! `llm.zig` because its phase transitions reference the full
//! `Runtime` struct (osc133_capture, captured_output, dialog_state,
//! …). What CAN move out cleanly is the leaf surface:
//!
//!   - Pure enums (`State`, `Action`, `TurnKind`) — no cfg or
//!     Runtime dependency.
//!   - `Turn` — a `{kind, content}` pair owned by the runtime; no
//!     cfg dependency either.
//!   - `Response(max_bytes)` — the parsed-reply struct factory.
//!     Buffer sizes come from `cfg.max_response_bytes`, so the
//!     factory takes that as a comptime parameter.
//!   - `parseResponse` — JSON → `Response` decoder. Pure modulo the
//!     allocator (used by `std.json.parseFromSlice`).
//!   - `buildRequestBody` — composes the OpenAI chat-completion
//!     JSON envelope from a turn slice + the static system/shell/
//!     context preamble. Pure modulo the allocator.
//!
//! Everything else (Runtime-touching functions: `pushTurn`,
//! `handleResponse`, `dialogReset`, `abortDialog`, …) stays in
//! `llm.zig` for now. Lifting those out cleanly requires either a
//! Runtime factory (Runtime closes over cfg too) or threading the
//! Runtime type through as a comptime parameter — both increase
//! diff size + review burden without a corresponding readability
//! win at this slice. Tracked in `docs/llm-exec-mode-followups.md`.

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

/// Parsed-reply struct factory. The buffer sizes come from
/// `cfg.max_response_bytes` (for `command_buf` and `question_buf`,
/// which can be long shell-command-shaped strings) and a fixed
/// 256-byte budget for the two short prose fields (`description`
/// and `reason`). Returning a `type` (rather than passing buffer
/// sizes through as runtime params) keeps callers stack-friendly:
/// they can `var parsed: Response = .{}` inline without an
/// allocator.
/// Max number of multi-choice options atty parses from an
/// `action=question` reply. Capped at 9 because `ghost_pick`'s
/// Ctrl+1..9 / Esc+1..9 bindings address up to 9 entries — a
/// 10th option would be unreachable from the keyboard.
pub const max_choices = 9;
/// Per-choice text cap. Anything longer gets truncated. 256 bytes
/// is roughly one terminal line at typical widths; longer
/// choices would wrap and confuse the pick-list rendering.
pub const choice_max_len = 256;

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
