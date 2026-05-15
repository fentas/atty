//! HTTP worker thread + request/response plumbing for the LLM
//! module. Extracted from `llm.zig` per the file-split plan in
//! `docs/llm-exec-mode-followups.md`.
//!
//! Returns a comptime `Module(cfg)` factory — every type in here
//! closes over `cfg` (buffer sizes for the request/response state
//! come from `cfg.max_prompt_bytes`, `cfg.body_buf_bytes`,
//! `cfg.max_response_bytes`; the system prompt resolves from
//! `cfg.system_prompt` / `cfg.with_explanation`; the worker's
//! fixture-replay path consults `cfg.fixture_responses`).
//!
//! What's exposed:
//!
//!   - `Shared` — mutex-guarded request/response buffers + signal
//!     condvar shared between the proxy main thread and the
//!     worker thread.
//!   - `RequestKind` (single vs dialog discriminator).
//!   - `RequestResult` — output struct from `doRequest` /
//!     `doDialogRequest`.
//!   - `ExtractedResponse` — output struct from `extractResponse`
//!     (paired with `extractCommand` for the legacy single-mode
//!     payload shape).
//!   - `effective_system_prompt` — comptime-resolved system text.
//!   - `buildRequestBody` — single-mode JSON envelope composer.
//!   - `extractCommand`, `extractResponse`, `extractRawContent` —
//!     response-side parsers.
//!   - `writeStatic` — helper for stable error messages.
//!   - `doRequest`, `doDialogRequest` — HTTP round-trips
//!     (one per mode).
//!   - `worker` — the thread function (lock-and-wait loop, fixture
//!     bypass, HTTP dispatch, result publish).
//!
//! Runtime-touching code (the proxy hooks: `onInput`, `onOutput`,
//! `onTick`, `onLineCommit`, `pollShellInput`; the dialog state
//! machine functions: `handleDialogResponse`, `dialogReset`,
//! `abortDialog`, `fireDialogRequest`, `startDialog`,
//! `startDialogViaEnter`, `pushTurn`, `freeTurns`,
//! `triggerSinglePrompt`; lifecycle: `attach`, `detach`) stays in
//! `llm.zig`. Those reference the `Runtime` struct directly, which
//! also closes over `cfg` — extracting them cleanly requires
//! either co-moving `Runtime` here or threading it as a comptime
//! type parameter, both higher-risk changes that don't fit a
//! single PR.

const std = @import("std");

const parse = @import("parse.zig");
const dialog = @import("dialog.zig");
const Config = @import("types.zig").Config;

pub fn Module(comptime cfg: Config) type {
    return struct {
        /// Discriminator for the worker. `.single` uses the legacy
        /// `req_buf` + the template-based `buildRequestBody`;
        /// `.dialog` POSTs `body_buf[0..body_len]` verbatim (the
        /// dialog state machine on the main thread pre-built it
        /// via `dialog.buildRequestBody`). Trigger sites set this
        /// under the same mutex as `req_pending`.
        pub const RequestKind = enum { single, dialog };

        /// One HTTP round-trip's outcome. On success `cmd_len > 0`
        /// and (when the model emitted one) `exp_len > 0`. On any
        /// failure `cmd_len == 0` and `err_len > 0` with a
        /// human-readable diagnostic in `error_out`.
        pub const RequestResult = struct {
            cmd_len: usize,
            exp_len: usize,
            err_len: usize = 0,
        };

        /// `extractResponse` output — both halves of the model's
        /// reply when configured to emit an explanation + command.
        pub const ExtractedResponse = struct {
            cmd_len: usize,
            explanation_len: usize,
        };

        /// Comptime-resolved system prompt. Honours an explicit
        /// `Config.system_prompt` override; otherwise picks the
        /// canned prompt for the `with_explanation` flag. Same
        /// value used at every request-fire site so the model sees
        /// stable framing across the session.
        pub const effective_system_prompt: []const u8 = if (cfg.system_prompt.len > 0)
            cfg.system_prompt
        else if (cfg.with_explanation)
            "You are an expert shell user. Given a natural-language description, reply with: (1) a SINGLE short sentence explaining what the command does, then a newline, then (2) a fenced block (```) containing EXACTLY ONE shell command on one line. Nothing else. No language tag on the fence. No prose after the closing fence."
        else
            "You are an expert shell user. Given a natural-language description, return EXACTLY ONE shell command that performs the task. Output ONLY the command on a single line. No markdown code fences. No explanation. No prefix or suffix text.";

        /// Mutex-guarded handshake between the proxy main thread
        /// (writer side) and the worker thread (reader side). All
        /// fields are protected by `mutex`. `cv` signals the
        /// worker that a new request landed; the worker also
        /// signals proxy-side via setting `res_done = true` (the
        /// proxy polls in `pollShellInput`, not via cv — keeps the
        /// proxy free to do other work while waiting on the HTTP
        /// response). On shutdown the proxy sets `shutdown = true`
        /// and `cv.signal`s; the worker observes the flag inside
        /// its `cv.wait` predicate loop and returns.
        pub const Shared = struct {
            mutex: std.Io.Mutex = .init,
            cv: std.Io.Condition = .init,
            /// Pending prompt set by trigger sites (onInput Enter
            /// path, onAction Alt+A).
            req_buf: [cfg.max_prompt_bytes]u8 = undefined,
            req_len: usize = 0,
            req_pending: bool = false,
            /// Selected model INDEX for the pending request.
            /// Stored as an index (not a copy of the string) so we
            /// can't truncate long model names AND there's no
            /// length-zero sentinel confusion with an empty
            /// `cfg.models[i]` (which would be a user-config bug
            /// anyway). Filled by request-trigger sites
            /// (onInput / onAction) under the same mutex that sets
            /// `req_pending`.
            ///
            /// Out-of-range sentinel: `model_idx == usize.max`
            /// means "no models[] — fall back to cfg.model".
            /// Worker resolves the slice from `cfg.models` at
            /// read time. `cfg.*` strings are comptime/static so
            /// the resolved slice's backing storage lives forever
            /// — safe to use across the worker thread boundary
            /// without a copy.
            model_idx: usize = std.math.maxInt(usize),
            /// Monotonic counter — bumped on every prompt the proxy
            /// hands to the worker. The worker stamps each response
            /// with the generation it was serving; the proxy drops
            /// responses whose generation doesn't match the current
            /// `req_gen` (stale-response guard for the "user typed
            /// a new prompt while the previous one was still in
            /// flight" case).
            req_gen: u64 = 0,
            /// Latest LLM response. Worker writes both on success
            /// (`res_len > 0`) AND on failure (`res_len = 0` with
            /// `res_done = true`) so `pollShellInput` can clear
            /// `in_flight` in both cases.
            res_buf: [cfg.max_response_bytes]u8 = undefined,
            res_len: usize = 0,
            /// Explanation text parsed from the response when
            /// `with_explanation` is set. Surfaced via
            /// `provideHintText` after `pollShellInput` consumes
            /// the command. `explanation_len == 0` means "no
            /// explanation parsed" (model didn't follow the format
            /// or `with_explanation` is off).
            explanation_buf: [512]u8 = undefined,
            explanation_len: usize = 0,
            /// Diagnostic message written by the worker when the
            /// request fails (connect error, HTTP non-2xx,
            /// unparseable response, or sanitiser stripped
            /// everything). Surfaced via `provideErrorText` (the
            /// muted-red + ⚠ notification slot, distinct from the
            /// hint slot used for explanations) so the user sees
            /// *why* the prompt produced no command.
            /// `error_len == 0` means "no error to report".
            error_buf: [256]u8 = undefined,
            error_len: usize = 0,
            /// Generation of the prompt this response is for.
            res_gen: u64 = 0,
            /// True when the worker has finished serving the
            /// current request — success OR failure. Proxy
            /// consumes via `pollShellInput` and clears.
            res_done: bool = false,
            shutdown: bool = false,

            /// Discriminator for the worker — `.single` uses
            /// `req_buf` + the legacy template builder; `.dialog`
            /// POSTs `body_buf[0..body_len]` verbatim. Trigger
            /// sites set this under the same mutex as `req_pending`.
            req_kind: RequestKind = .single,
            /// The `req_kind` that was active when the worker
            /// started serving the current response. Stamped onto
            /// the response so `pollShellInput` knows whether to
            /// run the single-mode injection path or the dialog
            /// JSON-parse path — `req_kind` itself can be mutated
            /// by a fresh trigger between the worker writing
            /// `res_done = true` and the proxy reading it.
            res_kind: RequestKind = .single,
            /// Pre-built JSON request body for dialog mode. The
            /// trigger site (main thread) serializes the full
            /// conversation here so the worker doesn't need to
            /// know about turns / system prompts / history bounds.
            body_buf: [cfg.body_buf_bytes]u8 = undefined,
            body_len: usize = 0,
            /// Fixture-stub cursor. Used when
            /// `cfg.fixture_responses.len > 0` to deterministically
            /// replay canned responses without HTTP. Indexed under
            /// the shared mutex by the worker; wraps around modulo
            /// list length.
            fixture_idx: usize = 0,
        };

        /// Write a static string into `dst` and return how many
        /// bytes were written (truncated to fit). Used to populate
        /// error messages with stable literals.
        pub fn writeStatic(dst: []u8, src: []const u8) usize {
            const n = @min(src.len, dst.len);
            @memcpy(dst[0..n], src[0..n]);
            return n;
        }

        /// Build the single-mode OpenAI chat-completion JSON
        /// envelope. Pure — no I/O, no cfg reads. Caller owns the
        /// returned slice (free via the same allocator).
        pub fn buildRequestBody(
            allocator: std.mem.Allocator,
            model: []const u8,
            system_prompt: []const u8,
            shell_name: []const u8,
            context_blob: []const u8,
            prompt: []const u8,
        ) ![]u8 {
            var allocating: std.Io.Writer.Allocating = .init(allocator);
            errdefer allocating.deinit();
            const writer = &allocating.writer;

            try writer.writeAll("{\"model\":");
            try std.json.Stringify.encodeJsonString(model, .{}, writer);
            try writer.writeAll(",\"messages\":[{\"role\":\"system\",\"content\":");
            try std.json.Stringify.encodeJsonString(system_prompt, .{}, writer);
            try writer.writeAll("},{\"role\":\"user\",\"content\":");

            // allocPrint instead of a fixed buffer — `shell_name`
            // and `context_blob` come from $SHELL / env config and
            // are not length-bounded. A pathological override (or
            // an unusually long env value) would overflow a fixed
            // buffer. Heap is fine — this is a one-shot build per
            // request, off the hot path.
            const user_msg = if (context_blob.len > 0)
                try std.fmt.allocPrint(
                    allocator,
                    "Generate a {s} command to: {s}\n\nContext: {s}",
                    .{ shell_name, prompt, context_blob },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "Generate a {s} command to: {s}",
                    .{ shell_name, prompt },
                );
            defer allocator.free(user_msg);
            try std.json.Stringify.encodeJsonString(user_msg, .{}, writer);
            try writer.writeAll("}],\"stream\":false}");
            return allocating.toOwnedSlice();
        }

        /// Extract the assistant's command text from an OpenAI-style
        /// chat-completion JSON response. Strips surrounding
        /// markdown fences + leading/trailing whitespace, takes the
        /// first non-empty line. Returns bytes written to `out`, or
        /// 0 on parse failure / empty result.
        pub fn extractCommand(body: []const u8, out: []u8) usize {
            var decoded_buf: [cfg.max_response_bytes]u8 = undefined;
            const decoded_len = parse.decodeContent(body, &decoded_buf);
            if (decoded_len == 0) return 0;
            return parse.sanitizeCommand(decoded_buf[0..decoded_len], out);
        }

        /// Extract both the explanation (prose before the fence) and
        /// the command (inside the fence) from a model reply that
        /// uses the with-explanation format:
        ///
        ///     <one-line explanation>
        ///     ```
        ///     <command>
        ///     ```
        ///
        /// When the model didn't follow the format (no fence), the
        /// whole content is treated as the command and explanation
        /// is empty. When the JSON content field is missing, both
        /// lengths come back 0.
        pub fn extractResponse(body: []const u8, cmd_out: []u8, explanation_out: []u8) ExtractedResponse {
            var decoded_buf: [cfg.max_response_bytes]u8 = undefined;
            const decoded_len = parse.decodeContent(body, &decoded_buf);
            if (decoded_len == 0) return .{ .cmd_len = 0, .explanation_len = 0 };
            const decoded = decoded_buf[0..decoded_len];

            // Look for an opening fence. The model may or may not
            // prefix prose; if there's no fence we keep the old
            // single-string behaviour.
            const fence_open_idx = std.mem.indexOf(u8, decoded, "```") orelse {
                return .{
                    .cmd_len = parse.sanitizeCommand(decoded, cmd_out),
                    .explanation_len = 0,
                };
            };

            // Inner content of the fence — skip the optional
            // language tag (everything up to the first newline
            // after the opening backticks). Bail to legacy mode
            // if the fence isn't terminated.
            const after_open = fence_open_idx + 3;
            const inner_start = if (std.mem.indexOfScalar(u8, decoded[after_open..], '\n')) |nl|
                after_open + nl + 1
            else
                after_open;
            const fence_close_idx = std.mem.indexOfPos(u8, decoded, inner_start, "```") orelse {
                return .{
                    .cmd_len = parse.sanitizeCommand(decoded, cmd_out),
                    .explanation_len = 0,
                };
            };

            const explanation_raw = std.mem.trim(u8, decoded[0..fence_open_idx], " \t\r\n");
            const fence_body = decoded[inner_start..fence_close_idx];
            return .{
                .cmd_len = parse.sanitizeCommand(fence_body, cmd_out),
                .explanation_len = parse.sanitizeExplanation(explanation_raw, explanation_out),
            };
        }

        /// Dialog-mode response extraction. Returns the raw content
        /// field VERBATIM (after JSON-unescape) so the main thread
        /// can parse the inner JSON envelope. Strips markdown
        /// ```json fences if the model wrapped its reply despite
        /// the system prompt forbidding it — common with smaller
        /// models that "helpfully" format JSON.
        pub fn extractRawContent(body: []const u8, out: []u8) usize {
            const decoded_len = parse.decodeContent(body, out);
            if (decoded_len == 0) return 0;
            const decoded = out[0..decoded_len];
            const trimmed = std.mem.trim(u8, decoded, " \t\r\n");

            // Strip an outer ```json …``` fence if present. We DO
            // this even though the system prompt says "no fences"
            // because the alternative is a fragile dialog loop —
            // a single fence-wrapped reply would tank the whole
            // session for users running locally-quantized models.
            //
            // Fence parsing is best-effort: if the boundaries
            // can't be located cleanly (no newline after the
            // opening fence, no closing fence, close before open),
            // we FALL THROUGH to returning the trimmed input
            // untouched. Better the JSON parser sees the wrapped
            // text and complains specifically than silently
            // dropping an otherwise-parseable reply.
            //
            // Closing fence is located by FORWARD search from
            // after_open (`indexOfPos`), not by `lastIndexOf`.
            // The latter would match the trailing fence even when
            // a nested triple-backtick appears earlier in the
            // content (e.g. a description string containing literal
            // fences) — but if an interior fence preceded the real
            // closer, lastIndexOf would silently truncate. Forward
            // search picks the FIRST closing fence after the
            // opener, which is the conventional shape.
            fence_strip: {
                if (!std.mem.startsWith(u8, trimmed, "```")) break :fence_strip;
                const nl = std.mem.indexOfScalar(u8, trimmed[3..], '\n') orelse break :fence_strip;
                const after_open = 3 + nl + 1;
                const close_at = std.mem.indexOfPos(u8, trimmed, after_open, "```") orelse break :fence_strip;
                if (close_at <= after_open) break :fence_strip;
                const inner = std.mem.trim(u8, trimmed[after_open..close_at], " \t\r\n");
                @memmove(out[0..inner.len], inner);
                return inner.len;
            }

            if (trimmed.ptr != decoded.ptr) {
                @memmove(out[0..trimmed.len], trimmed);
            }
            return trimmed.len;
        }

        /// One single-mode HTTP round-trip. On success returns
        /// `cmd_len > 0` and (when the model emitted one)
        /// `exp_len > 0`. On any failure `cmd_len == 0` and
        /// `err_len > 0` with a human-readable explanation written
        /// into `error_out` (network error, HTTP non-2xx with
        /// status code, unparseable response, sanitiser stripped
        /// everything).
        pub fn doRequest(
            gpa: std.mem.Allocator,
            io: std.Io,
            api_base: []const u8,
            api_key: []const u8,
            shell_name: []const u8,
            context_blob: []const u8,
            prompt: []const u8,
            model: []const u8,
            out: []u8,
            explanation_out: []u8,
            error_out: []u8,
        ) !RequestResult {
            const url = try std.fmt.allocPrint(gpa, "{s}/chat/completions", .{api_base});
            defer gpa.free(url);

            const body = try buildRequestBody(gpa, model, effective_system_prompt, shell_name, context_blob, prompt);
            defer gpa.free(body);

            var auth_buf: [256]u8 = undefined;
            const auth_header: ?[]const u8 = blk: {
                if (api_key.len == 0) break :blk null;
                if (api_key.len + 7 > auth_buf.len) break :blk null;
                break :blk std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch null;
            };

            var headers_buf: [2]std.http.Header = undefined;
            var headers_len: usize = 0;
            headers_buf[headers_len] = .{ .name = "Content-Type", .value = "application/json" };
            headers_len += 1;
            if (auth_header) |h| {
                headers_buf[headers_len] = .{ .name = "Authorization", .value = h };
                headers_len += 1;
            }

            var client: std.http.Client = .{ .allocator = gpa, .io = io };
            defer client.deinit();

            // Cap the response body at `max_response_bytes * 16`.
            // The JSON envelope around the message content is
            // larger than the content itself; 16× is a comfortable
            // ceiling for typical chat-completion shapes. A
            // misbehaving endpoint streaming gigabytes can no
            // longer OOM the worker — `client.fetch` errors when
            // the fixed writer overflows; we catch it and return 0
            // (no partial parse — a truncated JSON envelope is
            // useless anyway).
            const response_cap = cfg.max_response_bytes * 16;
            var response_buf: [response_cap]u8 = undefined;
            var response_writer: std.Io.Writer = .fixed(&response_buf);

            const fetched = client.fetch(.{
                .location = .{ .url = url },
                .method = .POST,
                .payload = body,
                .extra_headers = headers_buf[0..headers_len],
                .response_writer = &response_writer,
            }) catch return RequestResult{
                .cmd_len = 0,
                .exp_len = 0,
                .err_len = writeStatic(error_out, "request failed (endpoint unreachable?)"),
            };

            const status = @intFromEnum(fetched.status);
            if (status < 200 or status >= 300) {
                const err_msg = std.fmt.bufPrint(error_out, "HTTP {d}", .{status}) catch
                    error_out[0..writeStatic(error_out, "HTTP error")];
                return RequestResult{ .cmd_len = 0, .exp_len = 0, .err_len = err_msg.len };
            }

            const extracted = extractResponse(response_buf[0..response_writer.end], out, explanation_out);
            if (extracted.cmd_len == 0) {
                return RequestResult{
                    .cmd_len = 0,
                    .exp_len = 0,
                    .err_len = writeStatic(error_out, "couldn't extract a command from the response"),
                };
            }
            return RequestResult{ .cmd_len = extracted.cmd_len, .exp_len = extracted.explanation_len };
        }

        /// Dialog-mode HTTP round-trip. The request body is already
        /// built (by `dialog.buildRequestBody` on the main thread)
        /// because it depends on conversation history that lives in
        /// `Runtime`; the worker just POSTs it and extracts the
        /// raw assistant `content` field. Differs from `doRequest`
        /// in that the result `out` slice holds the JSON envelope
        /// (`{"action":...,"command":...}`) — the dialog state
        /// machine on the main thread does the second-stage parse
        /// via `dialog.parseResponse`.
        pub fn doDialogRequest(
            gpa: std.mem.Allocator,
            io: std.Io,
            api_base: []const u8,
            api_key: []const u8,
            body: []const u8,
            out: []u8,
            error_out: []u8,
        ) !RequestResult {
            const url = try std.fmt.allocPrint(gpa, "{s}/chat/completions", .{api_base});
            defer gpa.free(url);

            var auth_buf: [256]u8 = undefined;
            const auth_header: ?[]const u8 = blk: {
                if (api_key.len == 0) break :blk null;
                if (api_key.len + 7 > auth_buf.len) break :blk null;
                break :blk std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch null;
            };

            var headers_buf: [2]std.http.Header = undefined;
            var headers_len: usize = 0;
            headers_buf[headers_len] = .{ .name = "Content-Type", .value = "application/json" };
            headers_len += 1;
            if (auth_header) |h| {
                headers_buf[headers_len] = .{ .name = "Authorization", .value = h };
                headers_len += 1;
            }

            var client: std.http.Client = .{ .allocator = gpa, .io = io };
            defer client.deinit();

            // Heap-allocate the response buffer — at the default
            // cfg.max_response_bytes=4KiB this is 64 KiB which is
            // a substantial stack frame inside the worker thread.
            // Scales with the comptime knob, so a user raising
            // max_response_bytes shouldn't silently push the worker
            // thread close to its stack limit.
            const response_cap = cfg.max_response_bytes * 16;
            const response_buf = gpa.alloc(u8, response_cap) catch return RequestResult{
                .cmd_len = 0,
                .exp_len = 0,
                .err_len = writeStatic(error_out, "out of memory allocating response buffer"),
            };
            defer gpa.free(response_buf);
            var response_writer: std.Io.Writer = .fixed(response_buf);

            const fetched = client.fetch(.{
                .location = .{ .url = url },
                .method = .POST,
                .payload = body,
                .extra_headers = headers_buf[0..headers_len],
                .response_writer = &response_writer,
            }) catch return RequestResult{
                .cmd_len = 0,
                .exp_len = 0,
                .err_len = writeStatic(error_out, "request failed (endpoint unreachable?)"),
            };

            const status = @intFromEnum(fetched.status);
            if (status < 200 or status >= 300) {
                const err_msg = std.fmt.bufPrint(error_out, "HTTP {d}", .{status}) catch
                    error_out[0..writeStatic(error_out, "HTTP error")];
                return RequestResult{ .cmd_len = 0, .exp_len = 0, .err_len = err_msg.len };
            }

            const n = extractRawContent(response_buf[0..response_writer.end], out);
            if (n == 0) {
                return RequestResult{
                    .cmd_len = 0,
                    .exp_len = 0,
                    .err_len = writeStatic(error_out, "empty response from model"),
                };
            }
            return RequestResult{ .cmd_len = n, .exp_len = 0 };
        }

        /// Worker thread function. Owns the lock-and-wait loop:
        /// waits on `shared.cv` until either `shared.shutdown` or
        /// `shared.req_pending` is set, then dispatches based on
        /// `shared.req_kind`. Either fires the configured HTTP
        /// endpoint (`doRequest` / `doDialogRequest`) or — when
        /// `cfg.fixture_responses` is non-empty — replays the next
        /// canned response from the cursor (test path). Always
        /// signals completion via `res_done = true` so the proxy
        /// can clear `in_flight` regardless of outcome.
        pub fn worker(
            shared: *Shared,
            io: std.Io,
            gpa: std.mem.Allocator,
            api_base: []const u8,
            api_key: []const u8,
            shell_name: []const u8,
            context_blob: []const u8,
        ) void {
            var prompt_local: [cfg.max_prompt_bytes]u8 = undefined;
            var body_local: [cfg.body_buf_bytes]u8 = undefined;
            var prompt_len: usize = 0;
            var body_len: usize = 0;
            var serving_gen: u64 = 0;
            while (true) {
                shared.mutex.lockUncancelable(io);
                while (!shared.shutdown and !shared.req_pending) {
                    shared.cv.waitUncancelable(io, &shared.mutex);
                }
                if (shared.shutdown) {
                    shared.mutex.unlock(io);
                    return;
                }
                const req_kind = shared.req_kind;
                serving_gen = shared.req_gen;
                shared.req_pending = false;

                // Fixture mode — bypass HTTP entirely. Pop the next
                // canned response from the shared cursor (wrapping
                // modulo list length). Branch FIRST so we skip the
                // req_buf / body_buf copy below: fixture responses
                // don't depend on the request body at all, copying
                // it would be dead work.
                //
                // **Stamping contract**: even in fixture mode we
                // stamp `res_kind` and `res_gen` exactly like the
                // HTTP path so `pollShellInput`'s stale-response
                // guard and dialog/single discriminator work
                // identically. The `shared.model_idx` read is the
                // ONLY field intentionally skipped here (fixture
                // responses are model-agnostic).
                if (cfg.fixture_responses.len > 0) {
                    const fixture_n = cfg.fixture_responses.len;
                    const fi = shared.fixture_idx % fixture_n;
                    shared.fixture_idx = (fi + 1) % fixture_n;
                    const canned = cfg.fixture_responses[fi];
                    const copy_n = @min(canned.len, shared.res_buf.len);
                    @memcpy(shared.res_buf[0..copy_n], canned[0..copy_n]);
                    shared.res_len = copy_n;
                    shared.explanation_len = 0;
                    shared.error_len = 0;
                    shared.res_gen = serving_gen;
                    shared.res_kind = req_kind;
                    shared.res_done = true;
                    shared.mutex.unlock(io);
                    continue;
                }

                if (req_kind == .single) {
                    prompt_len = shared.req_len;
                    @memcpy(prompt_local[0..prompt_len], shared.req_buf[0..prompt_len]);
                } else {
                    body_len = shared.body_len;
                    @memcpy(body_local[0..body_len], shared.body_buf[0..body_len]);
                }
                // Read the request-time model INDEX under the same
                // lock. Trigger sites set `model_idx` to either a
                // valid `cfg.models[]` index, or `usize.max` as the
                // "no list, use cfg.model" sentinel. We resolve the
                // slice AFTER releasing the lock — `cfg.models` is
                // comptime-static, the resolved slice's storage
                // outlives the worker thread.
                const idx = shared.model_idx;
                shared.mutex.unlock(io);

                const model_for_request: []const u8 = if (idx < cfg.models.len)
                    cfg.models[idx]
                else
                    cfg.model;

                // Fire the HTTP request OUTSIDE the lock — it may
                // block for many seconds.
                var response_buf: [cfg.max_response_bytes]u8 = undefined;
                var explanation_local: [512]u8 = undefined;
                var error_local: [256]u8 = undefined;
                const result = if (req_kind == .single)
                    doRequest(
                        gpa,
                        io,
                        api_base,
                        api_key,
                        shell_name,
                        context_blob,
                        prompt_local[0..prompt_len],
                        model_for_request,
                        &response_buf,
                        &explanation_local,
                        &error_local,
                    ) catch RequestResult{
                        .cmd_len = 0,
                        .exp_len = 0,
                        .err_len = writeStatic(&error_local, "internal error in worker"),
                    }
                else
                    doDialogRequest(
                        gpa,
                        io,
                        api_base,
                        api_key,
                        body_local[0..body_len],
                        &response_buf,
                        &error_local,
                    ) catch RequestResult{
                        .cmd_len = 0,
                        .exp_len = 0,
                        .err_len = writeStatic(&error_local, "internal error in worker"),
                    };

                // Signal completion regardless of outcome — proxy
                // needs to clear `in_flight` so the 🧠 thinking…
                // statusbar doesn't stick when a request fails.
                // The proxy filters stale-generation responses
                // separately.
                shared.mutex.lockUncancelable(io);
                if (result.cmd_len > 0) {
                    @memcpy(shared.res_buf[0..result.cmd_len], response_buf[0..result.cmd_len]);
                    shared.res_len = result.cmd_len;
                    if (result.exp_len > 0) {
                        @memcpy(shared.explanation_buf[0..result.exp_len], explanation_local[0..result.exp_len]);
                        shared.explanation_len = result.exp_len;
                    } else {
                        shared.explanation_len = 0;
                    }
                    shared.error_len = 0;
                } else {
                    shared.res_len = 0;
                    shared.explanation_len = 0;
                    if (result.err_len > 0) {
                        const en = @min(result.err_len, shared.error_buf.len);
                        @memcpy(shared.error_buf[0..en], error_local[0..en]);
                        shared.error_len = en;
                    } else {
                        shared.error_len = 0;
                    }
                }
                shared.res_gen = serving_gen;
                shared.res_kind = req_kind;
                shared.res_done = true;
                shared.mutex.unlock(io);
            }
        }
    };
}
