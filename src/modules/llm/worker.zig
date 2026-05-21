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
//! `onTick`, `onLineCommit`, `pollShellInput`; the remaining
//! dialog state machine functions: `handleDialogResponse`,
//! `fireDialogRequest`, `startDialog`, `startDialogViaEnter`,
//! `triggerSinglePrompt`; lifecycle: `attach`, `detach`) stays in
//! `llm.zig`. Those reference the `Runtime` struct directly, which
//! also closes over `cfg` — extracting them cleanly requires
//! either co-moving `Runtime` here or threading it as a comptime
//! type parameter, both higher-risk changes that don't fit a
//! single PR.

const std = @import("std");

const parse = @import("parse.zig");
const dialog = @import("dialog.zig");
const env_mod_ns = @import("env.zig");
const prompts_ns = @import("prompts.zig");
const types = @import("types.zig");
const Config = types.Config;
const Provider = types.Provider;
const HttpProvider = types.HttpProvider;
const SubprocessProvider = types.SubprocessProvider;
const ProviderEntry = types.ProviderEntry;
const Mode = types.Mode;
const nowMs = @import("../_lib.zig").nowMs;

// Resolver types + helpers live in types.zig now (paint.zig
// surfaces them without dragging in the HTTP worker). Re-exports
// keep existing call sites + tests on this module's namespace
// stable.
pub const ResolvedProvider = types.ResolvedProvider;
pub const providerLabel = types.providerLabel;
pub const resolveProviderForMode = types.resolveProviderForMode;
pub const resolveProvider = types.resolveProvider;

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

        /// Single-shot system prompt — atty's fenced-action protocol
        /// (`prompts.prompt_single`) is ALWAYS prepended so the
        /// parser contract holds. User's `cfg.system_prompt`, when
        /// set, appends after a blank line as additional domain
        /// context (style guides, project rules, etc.) — never
        /// replaces the action protocol.
        pub const effective_system_prompt: []const u8 = if (cfg.system_prompt.len > 0)
            prompts_ns.prompt_single ++ "\n\n" ++ cfg.system_prompt
        else
            prompts_ns.prompt_single;

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
            /// Selected `cfg.providers[]` INDEX for the pending
            /// request. Filled by request-trigger sites
            /// (onInput / onAction) under the same mutex that
            /// sets `req_pending`. Worker resolves the slice via
            /// `resolveProvider(req_kind, cfg.providers, cfg.provider, idx)`
            /// at read time. `cfg.*` strings are comptime/static
            /// so the resolved slice's backing storage lives
            /// forever — safe to use across the worker thread
            /// boundary without a copy.
            ///
            /// `usize.max` is the "use cfg.provider shorthand"
            /// sentinel — set when `cfg.providers` is empty.
            current_provider_idx: usize = std.math.maxInt(usize),
            /// Dispatch mode for the pending request — set by
            /// trigger sites alongside `req_kind`. Used by the
            /// worker to call `resolveProviderForMode` with the
            /// precise mode (`.auto` / `.chat` instead of
            /// collapsing to `.dialog`) so chat-only or
            /// auto-only `ProviderEntry.for_modes` masks are
            /// reachable. Default `.single` is a safe identity
            /// for the legacy onInput Enter path.
            dispatch_mode: types.Mode = .single,
            /// Monotonic counter — bumped on every prompt the proxy
            /// hands to the worker. The worker stamps each response
            /// with the generation it was serving; the proxy drops
            /// responses whose generation doesn't match the current
            /// `req_gen` (stale-response guard for the "user typed
            /// a new prompt while the previous one was still in
            /// flight" case).
            req_gen: u64 = 0,
            /// Latest LLM response. Heap-allocated per-response so a
            /// small reply (the common case) doesn't reserve
            /// `cfg.max_response_bytes` of inline buffer space.
            /// `cfg.max_response_bytes` bounds `cmd_len` via the
            /// decoder's stack buffer — `storeResponse` only sees
            /// already-capped slices. `null` when no response is
            /// staged; `storeResponse` frees the previous slice
            /// before allocating the new one, and the proxy frees
            /// it again after copying into `inject_buf` — so the
            /// slice never outlives one consume cycle. Proxy reads
            /// under `mutex`.
            res_buf: ?[]u8 = null,
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

            /// Session id for native CLI-side continuation
            /// (`cfg.provider.subprocess.session = .continuation`).
            /// `request_session_id_*` is written by trigger sites
            /// when a session is in flight — the worker injects
            /// `[flag, id]` into the subprocess argv. `response_
            /// session_id_*` is written by the worker when the
            /// stream parses out a fresh id from the CLI's response;
            /// the main thread consumes it via `pollShellInput`.
            /// 256 bytes is comfortably wider than any session id
            /// any CLI is likely to emit (claude's are 36-char
            /// UUIDs).
            request_session_id_buf: [256]u8 = undefined,
            request_session_id_len: usize = 0,
            response_session_id_buf: [256]u8 = undefined,
            response_session_id_len: usize = 0,
        };

        /// Write a static string into `dst` and return how many
        /// bytes were written (truncated to fit). Used to populate
        /// error messages with stable literals.
        pub fn writeStatic(dst: []u8, src: []const u8) usize {
            const n = @min(src.len, dst.len);
            @memcpy(dst[0..n], src[0..n]);
            return n;
        }

        /// Replace the staged response slice atomically. Frees any
        /// previous heap slice before allocating the new one so the
        /// buffer never outlives one consume cycle. Caller must hold
        /// `shared.mutex`.
        pub fn storeResponse(gpa: std.mem.Allocator, shared: *Shared, bytes: []const u8) !void {
            if (shared.res_buf) |old| gpa.free(old);
            shared.res_buf = null;
            shared.res_len = 0;
            const buf = try gpa.alloc(u8, bytes.len);
            @memcpy(buf, bytes);
            shared.res_buf = buf;
            shared.res_len = bytes.len;
        }

        /// Free the staged response slice if any. Caller must hold
        /// `shared.mutex`.
        pub fn clearResBuf(gpa: std.mem.Allocator, shared: *Shared) void {
            if (shared.res_buf) |old| gpa.free(old);
            shared.res_buf = null;
            shared.res_len = 0;
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

        /// Outcome of `runHttpFetchWithDeadline`. Owns the
        /// response bytes (`response_buf[0..response_len]`) until
        /// the caller frees the slice via `gpa.free(response_buf)`
        /// in the success path, OR until the abandoning sub-thread
        /// frees it on the timeout path. Two terminal kinds:
        ///   - `ok`: `response_buf` + `status` are valid and the
        ///     caller is responsible for consuming + freeing.
        ///   - `err`: `response_buf` already freed (or never owned
        ///     in the spawn-failed case); caller just reports the
        ///     error and moves on.
        pub const FetchKind = enum { ok, fetch_failed, timed_out, spawn_failed, oom };
        pub const FetchOutcome = struct {
            kind: FetchKind,
            status: u16 = 0,
            response_buf: ?[]u8 = null,
            response_len: usize = 0,
        };

        /// Shared state between the fetch sub-thread and the
        /// worker thread. Heap-allocated so the abandoning path
        /// can hand ownership cleanly to the sub-thread without
        /// the worker's frame being involved. Sub-thread frees
        /// itself when it finishes AFTER being abandoned.
        const HttpFetchTask = struct {
            // Inputs — task-owned heap copies so the worker can
            // return without keeping ANY caller storage alive.
            gpa: std.mem.Allocator,
            io: std.Io,
            url: []u8,
            body: []u8,
            // Headers: owned `auth` copy (or none), plus the
            // Content-Type literal. Stored as a fixed slot count
            // so the thread doesn't need an allocator dance.
            auth_storage: ?[]u8,
            // Response sink — owned by task during run, ownership
            // transfers to whoever wins the swap on completion.
            response_buf: []u8,

            // Status transitions (acq_rel):
            //   RUNNING → DONE (sub-thread finishes; worker
            //                   sees swap == DONE and consumes)
            //   RUNNING → ABANDONED (worker times out; sub-thread
            //                        eventually finishes and frees)
            status: std.atomic.Value(u8),

            // Set by sub-thread before transitioning to DONE.
            outcome: FetchOutcome = .{ .kind = .fetch_failed },

            fn deinit(self: *HttpFetchTask) void {
                const a = self.gpa;
                a.free(self.url);
                a.free(self.body);
                if (self.auth_storage) |s| a.free(s);
                a.free(self.response_buf);
                a.destroy(self);
            }

            fn run(self: *HttpFetchTask) void {
                var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
                defer client.deinit();

                var headers_buf: [2]std.http.Header = undefined;
                var headers_len: usize = 0;
                headers_buf[headers_len] = .{ .name = "Content-Type", .value = "application/json" };
                headers_len += 1;
                if (self.auth_storage) |s| {
                    headers_buf[headers_len] = .{ .name = "Authorization", .value = s };
                    headers_len += 1;
                }

                var response_writer: std.Io.Writer = .fixed(self.response_buf);
                const fetched = client.fetch(.{
                    .location = .{ .url = self.url },
                    .method = .POST,
                    .payload = self.body,
                    .extra_headers = headers_buf[0..headers_len],
                    .response_writer = &response_writer,
                }) catch {
                    self.outcome = .{ .kind = .fetch_failed };
                    self.publishDone();
                    return;
                };

                self.outcome = .{
                    .kind = .ok,
                    .status = @intFromEnum(fetched.status),
                    .response_buf = self.response_buf,
                    .response_len = response_writer.end,
                };
                self.publishDone();
            }

            fn publishDone(self: *HttpFetchTask) void {
                // Swap is the synchronization point: whoever sees
                // the OLD value of RUNNING (= 0) is the worker
                // thread; whoever sees ABANDONED owns cleanup.
                const prev = self.status.swap(STATUS_DONE, .acq_rel);
                if (prev == STATUS_ABANDONED) self.deinit();
            }
        };

        const STATUS_RUNNING: u8 = 0;
        const STATUS_DONE: u8 = 1;
        const STATUS_ABANDONED: u8 = 2;

        /// Run `std.http.Client.fetch` on a sub-thread with a
        /// deadline (`timeout_ms` from config; `0` = no deadline).
        /// On timely completion: returns the fetched result;
        /// caller owns `response_buf` and must free it. On
        /// timeout: returns `.timed_out`; the sub-thread is
        /// detached and frees its own state when it eventually
        /// completes. The worker can return and start a new
        /// request immediately, so repeated requests against a
        /// blackholed endpoint accumulate several orphaned tasks
        /// in parallel until each one's `client.fetch` returns
        /// (typically when the OS TCP timeout fires). Each
        /// orphan holds ~`response_cap` bytes plus url/body/auth
        /// dupes; users tuning `timeout_ms` should size with
        /// retry behavior in mind. Spawn-failures and OOM are
        /// reported via their own `FetchKind` variants.
        ///
        /// `url`, `body`, `auth_header` are copied into task-owned
        /// heap so the worker can return without holding caller
        /// storage alive across the timeout window.
        /// Init the heap-owned task. Returns an error union so
        /// `errdefer` chains fire correctly on partial OOM — a
        /// plain `catch return .{...}` form (returning a value, not
        /// an error union) silently skips `errdefer`, leaking the
        /// already-allocated dupes.
        fn initHttpFetchTask(
            gpa: std.mem.Allocator,
            io: std.Io,
            url_in: []const u8,
            body_in: []const u8,
            auth_header_in: ?[]const u8,
            response_cap: usize,
        ) !*HttpFetchTask {
            const task = try gpa.create(HttpFetchTask);
            errdefer gpa.destroy(task);

            const url_dup = try gpa.dupe(u8, url_in);
            errdefer gpa.free(url_dup);
            const body_dup = try gpa.dupe(u8, body_in);
            errdefer gpa.free(body_dup);
            const auth_dup: ?[]u8 = if (auth_header_in) |h| try gpa.dupe(u8, h) else null;
            errdefer if (auth_dup) |s| gpa.free(s);
            const response_buf = try gpa.alloc(u8, response_cap);
            errdefer gpa.free(response_buf);

            task.* = HttpFetchTask{
                .gpa = gpa,
                .io = io,
                .url = url_dup,
                .body = body_dup,
                .auth_storage = auth_dup,
                .response_buf = response_buf,
                .status = std.atomic.Value(u8).init(STATUS_RUNNING),
                .outcome = .{ .kind = .fetch_failed },
            };
            return task;
        }

        pub fn runHttpFetchWithDeadline(
            gpa: std.mem.Allocator,
            io: std.Io,
            url_in: []const u8,
            body_in: []const u8,
            auth_header_in: ?[]const u8,
            response_cap: usize,
            timeout_ms: u32,
        ) FetchOutcome {
            const task = initHttpFetchTask(gpa, io, url_in, body_in, auth_header_in, response_cap) catch
                return .{ .kind = .oom };

            // No-deadline mode: run inline on the worker thread.
            // Skips the thread spawn + heap-of-dupes the deadline
            // path needs for ownership transfer — pure waste when
            // there's no deadline to enforce.
            if (timeout_ms == 0) {
                task.run();
                return consumeTask(task);
            }

            const thread = std.Thread.spawn(.{}, HttpFetchTask.run, .{task}) catch {
                task.deinit();
                return .{ .kind = .spawn_failed };
            };

            // Wall-clock deadline (mirrors subprocess Watchdog
            // pattern — EINTR-shortened nanosleep doesn't advance
            // elapsed so the deadline can't fire early).
            const start_ms = nowMs();
            const deadline_signed: i64 = @as(i64, timeout_ms);
            var slice: std.c.timespec = .{ .sec = 0, .nsec = @intCast(50 * std.time.ns_per_ms) };
            while ((nowMs() - start_ms) < deadline_signed) {
                if (task.status.load(.acquire) == STATUS_DONE) break;
                _ = std.c.nanosleep(&slice, null);
            }

            if (task.status.load(.acquire) == STATUS_DONE) {
                thread.join();
                return consumeTask(task);
            }

            // Deadline expired. Race-tight transition: swap to
            // ABANDONED. If the sub-thread already transitioned to
            // DONE between our last poll and the swap, the swap
            // returns DONE and we still own the result; consume it.
            const prev = task.status.swap(STATUS_ABANDONED, .acq_rel);
            if (prev == STATUS_DONE) {
                thread.join();
                return consumeTask(task);
            }

            // True timeout. Detach: the sub-thread will eventually
            // complete and `publishDone` will see ABANDONED and
            // call `deinit` on the task (freeing everything we
            // allocated above). The worker returns and can start
            // another request immediately, so concurrent orphans
            // can accumulate against a blackholed endpoint —
            // bounded only by the OS TCP timeout under which
            // each orphan's `client.fetch` eventually returns.
            thread.detach();
            return .{ .kind = .timed_out };
        }

        /// Take ownership of the task's outcome — on success, the
        /// caller owns `response_buf` and frees it via `gpa.free`;
        /// the helper frees the rest of the task's heap state. On
        /// failure, the helper frees everything (including the
        /// untouched response_buf).
        fn consumeTask(task: *HttpFetchTask) FetchOutcome {
            const out = task.outcome;
            if (out.kind == .ok) {
                const a = task.gpa;
                a.free(task.url);
                a.free(task.body);
                if (task.auth_storage) |s| a.free(s);
                a.destroy(task);
            } else {
                task.deinit();
            }
            return out;
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

            // Cap the response body at `max_response_bytes * 16`.
            // The JSON envelope around the message content is
            // larger than the content itself; 16× is a comfortable
            // ceiling for typical chat-completion shapes.
            const response_cap = cfg.max_response_bytes * 16;
            const outcome = runHttpFetchWithDeadline(gpa, io, url, body, auth_header, response_cap, cfg.timeout_ms);
            switch (outcome.kind) {
                .ok => {},
                .fetch_failed => return RequestResult{
                    .cmd_len = 0,
                    .exp_len = 0,
                    .err_len = writeStatic(error_out, "request failed (endpoint unreachable?)"),
                },
                .timed_out => {
                    const msg = std.fmt.bufPrint(error_out, "HTTP request timed out ({d}ms)", .{cfg.timeout_ms}) catch
                        error_out[0..writeStatic(error_out, "HTTP request timed out")];
                    return RequestResult{ .cmd_len = 0, .exp_len = 0, .err_len = msg.len };
                },
                .spawn_failed => return RequestResult{
                    .cmd_len = 0,
                    .exp_len = 0,
                    .err_len = writeStatic(error_out, "couldn't spawn HTTP worker thread"),
                },
                .oom => return RequestResult{
                    .cmd_len = 0,
                    .exp_len = 0,
                    .err_len = writeStatic(error_out, "out of memory allocating HTTP fetch state"),
                },
            }
            const response_buf = outcome.response_buf.?;
            defer gpa.free(response_buf);

            if (outcome.status < 200 or outcome.status >= 300) {
                const err_msg = std.fmt.bufPrint(error_out, "HTTP {d}", .{outcome.status}) catch
                    error_out[0..writeStatic(error_out, "HTTP error")];
                return RequestResult{ .cmd_len = 0, .exp_len = 0, .err_len = err_msg.len };
            }

            const extracted = extractResponse(response_buf[0..outcome.response_len], out, explanation_out);
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

            const response_cap = cfg.max_response_bytes * 16;
            const outcome = runHttpFetchWithDeadline(gpa, io, url, body, auth_header, response_cap, cfg.timeout_ms);
            switch (outcome.kind) {
                .ok => {},
                .fetch_failed => return RequestResult{
                    .cmd_len = 0,
                    .exp_len = 0,
                    .err_len = writeStatic(error_out, "request failed (endpoint unreachable?)"),
                },
                .timed_out => {
                    const msg = std.fmt.bufPrint(error_out, "HTTP request timed out ({d}ms)", .{cfg.timeout_ms}) catch
                        error_out[0..writeStatic(error_out, "HTTP request timed out")];
                    return RequestResult{ .cmd_len = 0, .exp_len = 0, .err_len = msg.len };
                },
                .spawn_failed => return RequestResult{
                    .cmd_len = 0,
                    .exp_len = 0,
                    .err_len = writeStatic(error_out, "couldn't spawn HTTP worker thread"),
                },
                .oom => return RequestResult{
                    .cmd_len = 0,
                    .exp_len = 0,
                    .err_len = writeStatic(error_out, "out of memory allocating HTTP fetch state"),
                },
            }
            const response_buf = outcome.response_buf.?;
            defer gpa.free(response_buf);

            if (outcome.status < 200 or outcome.status >= 300) {
                const err_msg = std.fmt.bufPrint(error_out, "HTTP {d}", .{outcome.status}) catch
                    error_out[0..writeStatic(error_out, "HTTP error")];
                return RequestResult{ .cmd_len = 0, .exp_len = 0, .err_len = err_msg.len };
            }

            const n = extractRawContent(response_buf[0..outcome.response_len], out);
            if (n == 0) {
                return RequestResult{
                    .cmd_len = 0,
                    .exp_len = 0,
                    .err_len = writeStatic(error_out, "empty response from model"),
                };
            }
            return RequestResult{ .cmd_len = n, .exp_len = 0 };
        }

        // ─────────────────────────────────────────────────────────
        // Subprocess transport
        // ─────────────────────────────────────────────────────────

        /// Spawn the configured CLI, deliver the prompt (final argv
        /// slot or stdin per `sub.prompt_via`), read stdout to EOF,
        /// wait for exit. Returns owned bytes; caller frees via the
        /// same allocator. On any failure returns
        /// `error.SubprocessFailed` and populates `error_out`.
        pub fn runSubprocess(
            gpa: std.mem.Allocator,
            io: std.Io,
            sub: SubprocessProvider,
            prompt: []const u8,
            /// Extra argv slots inserted between `sub.argv` and the
            /// prompt slot. atty uses this for session continuation
            /// (`["--resume", "<id>"]`) without baking session state
            /// into `sub.argv` itself.
            prepend_argv: []const []const u8,
            error_out: []u8,
            err_len_out: *usize,
        ) ![]u8 {
            err_len_out.* = 0;
            var argv_list: std.ArrayList([]const u8) = .empty;
            defer argv_list.deinit(gpa);
            try argv_list.appendSlice(gpa, sub.argv);
            try argv_list.appendSlice(gpa, prepend_argv);
            if (sub.prompt_via == .final_arg) {
                try argv_list.append(gpa, prompt);
            }

            const want_stdin = sub.prompt_via == .stdin;
            var child = std.process.spawn(io, .{
                .argv = argv_list.items,
                .stdin = if (want_stdin) .pipe else .ignore,
                .stdout = .pipe,
                .stderr = .pipe,
            }) catch {
                err_len_out.* = writeStatic(error_out, "subprocess spawn failed (binary on $PATH?)");
                return error.SubprocessFailed;
            };

            var completed = std.atomic.Value(bool).init(false);
            var timed_out = std.atomic.Value(bool).init(false);
            const Watchdog = struct {
                fn run(deadline_ms: u64, pid: std.posix.pid_t, done: *std.atomic.Value(bool), expired: *std.atomic.Value(bool)) void {
                    // Wall-clock deadline (not slice-counted) — an
                    // EINTR-shortened `nanosleep` doesn't advance
                    // elapsed time, so the watchdog can't fire
                    // ahead of the configured budget.
                    const start_ms = nowMs();
                    const deadline_signed: i64 = @intCast(deadline_ms);
                    var slice: std.c.timespec = .{ .sec = 0, .nsec = @intCast(50 * std.time.ns_per_ms) };
                    while ((nowMs() - start_ms) < deadline_signed) {
                        _ = std.c.nanosleep(&slice, null);
                        if (done.load(.acquire)) return;
                    }
                    // Re-check `done` immediately before the kill
                    // closes the race window where the main thread
                    // completes between our last poll and the
                    // SIGTERM (the kill would otherwise target a
                    // zombie or — if pid reuse won — an unrelated
                    // process; pid reuse is impossible while the
                    // main thread holds off `wait` until our join,
                    // but belt-and-suspenders).
                    if (done.load(.acquire)) return;
                    expired.store(true, .release);
                    // SIGTERM first — gives well-behaved CLIs a
                    // chance to flush stderr / close files. SIGKILL
                    // 200 ms later catches anything that didn't
                    // exit. `std.posix.kill` instead of
                    // `child.kill` because the latter mutates
                    // `child.id` and races with the main thread's
                    // read/wait.
                    std.posix.kill(pid, .TERM) catch {};
                    var grace: std.c.timespec = .{ .sec = 0, .nsec = @intCast(200 * std.time.ns_per_ms) };
                    _ = std.c.nanosleep(&grace, null);
                    std.posix.kill(pid, .KILL) catch {};
                }
            };
            // If the user asked for a timeout but we can't spawn
            // the watchdog (thread-count limit, OOM), fail the
            // request rather than silently running without
            // enforcement — the user's config explicitly said
            // "kill after Nms" and a silent unbounded subprocess
            // is the worst possible default. `child.id != null`
            // is an assert-grade invariant (spawn returns a valid
            // child or errors out above); keep it as a defensive
            // check because the cost is one branch.
            const watchdog_thread: ?std.Thread = if (sub.timeout_ms > 0) blk: {
                const t = std.Thread.spawn(.{}, Watchdog.run, .{ sub.timeout_ms, child.id orelse unreachable, &completed, &timed_out }) catch {
                    // At this point only stdin (maybe) was touched
                    // — no other threads to join. Kill + reap the
                    // child so it doesn't run unbounded.
                    child.kill(io);
                    err_len_out.* = writeStatic(error_out, "subprocess watchdog thread spawn failed");
                    return error.SubprocessFailed;
                };
                break :blk t;
            } else null;

            if (want_stdin) {
                if (child.stdin) |stdin_file| {
                    var write_buf: [4096]u8 = undefined;
                    var w = stdin_file.writer(io, &write_buf);
                    // EPIPE here is fine — the child can legitimately
                    // close stdin before we finish writing (it had
                    // all the bytes it needed). Other write errors
                    // would still result in a downstream stdout-read
                    // failure that surfaces a useful message.
                    w.interface.writeAll(prompt) catch {};
                    w.interface.flush() catch {};
                    stdin_file.close(io);
                    child.stdin = null;
                }
            }

            // Read stdout to EOF. The Reader's internal buffer is
            // the only allocation hot-path; cap the alloc at the
            // worker's max-response window × 16 to match the HTTP
            // path's `response_cap` (JSON envelope overhead can be
            // ~10× the content for small responses).
            const read_cap = cfg.max_response_bytes * 16;
            const stdout_file = child.stdout orelse {
                child.kill(io);
                completed.store(true, .release);
                if (watchdog_thread) |t| t.join();
                err_len_out.* = writeStatic(error_out, "subprocess produced no stdout pipe");
                return error.SubprocessFailed;
            };
            // Drain stderr concurrently with stdout. Sequentially
            // reading stdout to EOF first deadlocks on any tool
            // that emits >~64 KB on stderr (kernel pipe buffer is
            // 64 KB by default on Linux) — the child blocks
            // writing stderr while we're stuck waiting on its
            // never-arriving stdout EOF. Spawn a tiny drainer
            // thread that runs the stderr read to completion.
            const StderrDrainer = struct {
                fn run(d_io: std.Io, file: std.Io.File, ally: std.mem.Allocator) void {
                    var buf: [4096]u8 = undefined;
                    var r = file.reader(d_io, &buf);
                    const bytes = r.interface.allocRemaining(ally, .limited(64 * 1024)) catch return;
                    ally.free(bytes);
                }
            };
            const stderr_thread: ?std.Thread = if (child.stderr) |stderr_file|
                std.Thread.spawn(.{}, StderrDrainer.run, .{ io, stderr_file, gpa }) catch null
            else
                null;

            var read_buf: [4096]u8 = undefined;
            var reader = stdout_file.reader(io, &read_buf);

            const stdout_bytes = reader.interface.allocRemaining(gpa, .limited(read_cap)) catch {
                child.kill(io);
                completed.store(true, .release);
                if (stderr_thread) |t| t.join();
                if (watchdog_thread) |t| t.join();
                err_len_out.* = writeStatic(error_out, "subprocess stdout read failed");
                return error.SubprocessFailed;
            };
            errdefer gpa.free(stdout_bytes);

            // Signal `completed` BEFORE `wait` so the watchdog
            // can exit promptly on its next slice check rather
            // than waiting out the full budget if `wait` happens
            // to block briefly.
            completed.store(true, .release);
            if (stderr_thread) |t| t.join();
            if (watchdog_thread) |t| t.join();

            const term = child.wait(io) catch {
                err_len_out.* = writeStatic(error_out, "subprocess wait failed");
                return error.SubprocessFailed;
            };

            // If the watchdog fired, the child was SIGKILL'd —
            // report the timeout regardless of how `wait` framed
            // the death. This needs to come BEFORE the generic
            // signal-killed branch below so the user sees the
            // actionable error.
            if (timed_out.load(.acquire)) {
                const formatted = std.fmt.bufPrint(error_out, "subprocess timed out ({d}ms)", .{sub.timeout_ms}) catch null;
                err_len_out.* = if (formatted) |s| s.len else writeStatic(error_out, "subprocess timed out");
                return error.SubprocessFailed;
            }

            switch (term) {
                .exited => |code| if (code != 0) {
                    const formatted = std.fmt.bufPrint(error_out, "subprocess exit {d}", .{code}) catch null;
                    err_len_out.* = if (formatted) |s| s.len else writeStatic(error_out, "subprocess non-zero exit");
                    return error.SubprocessFailed;
                },
                .signal, .stopped, .unknown => {
                    err_len_out.* = writeStatic(error_out, "subprocess killed by signal");
                    return error.SubprocessFailed;
                },
            }

            return stdout_bytes;
        }

        /// Combined output of a single stream-json walk.
        pub const StreamParse = struct {
            result_len: usize = 0,
            session_id_len: usize = 0,
        };

        /// One-pass walker over a stream-json body. Captures the
        /// value of `result_field` from the first `type="result"`
        /// line AND the value of `session_id_field` from the first
        /// `type="system",subtype="init"` line, returning both in
        /// a single `StreamParse`. Pass empty field/out slices for
        /// the capture you don't need — the walker skips the
        /// corresponding branch entirely. Short-circuits once both
        /// requested captures have landed.
        ///
        /// Replaces the pre-#168 two-walk approach
        /// (`extractStreamSessionId` + `extractJsonStreamResult`
        /// each iterated the body separately).
        pub fn parseStreamJson(
            body: []const u8,
            result_field: []const u8,
            session_id_field: []const u8,
            result_out: []u8,
            session_id_out: []u8,
        ) StreamParse {
            var out: StreamParse = .{};
            const want_result = result_field.len > 0 and result_out.len > 0;
            var want_session = session_id_field.len > 0 and session_id_out.len > 0;
            if (!want_result and !want_session) return out;

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var it = std.mem.splitScalar(u8, body, '\n');
            while (it.next()) |raw_line| {
                const need_result = want_result and out.result_len == 0;
                const need_session = want_session and out.session_id_len == 0;
                if (!need_result and !need_session) return out;

                const line = std.mem.trim(u8, raw_line, " \t\r");
                if (line.len == 0) continue;
                _ = arena.reset(.retain_capacity);
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch continue;
                if (parsed != .object) continue;
                const type_val = parsed.object.get("type") orelse continue;
                if (type_val != .string) continue;
                const type_str = type_val.string;

                if (need_session and std.mem.eql(u8, type_str, "system")) {
                    // Match only `subtype="init"` — claude wraps
                    // init events that way. Bare `type=system`
                    // without subtype (e.g. a hypothetical
                    // `subtype=info` mid-stream) mustn't claim
                    // the session-id slot.
                    if (parsed.object.get("subtype")) |sv| if (sv == .string and std.mem.eql(u8, sv.string, "init")) {
                        if (parsed.object.get(session_id_field)) |idv| if (idv == .string) {
                            if (idv.string.len <= session_id_out.len) {
                                @memcpy(session_id_out[0..idv.string.len], idv.string);
                                out.session_id_len = idv.string.len;
                            } else {
                                // Oversized id — preserve the
                                // pre-#168 contract: the first
                                // init event's id is the canonical
                                // one. If it doesn't fit, abandon
                                // session capture entirely rather
                                // than silently picking up a
                                // narrower id from a later (likely
                                // bogus) re-init. Result capture
                                // continues independently.
                                want_session = false;
                            }
                        };
                    };
                }

                if (need_result and std.mem.eql(u8, type_str, "result")) {
                    // Walk past malformed result events instead of
                    // returning 0 — a stray "result with wrong
                    // shape" early in the stream mustn't suppress
                    // a later valid one.
                    if (parsed.object.get(result_field)) |fv| if (fv == .string) {
                        const n = @min(fv.string.len, result_out.len);
                        @memcpy(result_out[0..n], fv.string[0..n]);
                        out.result_len = n;
                    };
                }
            }
            return out;
        }

        /// Return the configured session-id JSON field for a
        /// subprocess provider's continuation mode, or empty
        /// string when the provider isn't asking for session
        /// capture. Centralises the `switch (sub.session)` that
        /// both `doSubprocessRequest` and `doSubprocessDialogRequest`
        /// otherwise duplicate.
        pub fn sessionIdField(sub: SubprocessProvider) []const u8 {
            return switch (sub.session) {
                .continuation => |c| c.id_field,
                .none => "",
            };
        }

        /// Thin wrapper kept for callers (and tests) that only need
        /// the session id. Single-purpose, single-walk shape.
        pub fn extractStreamSessionId(body: []const u8, field: []const u8, out: []u8) usize {
            var unused: [0]u8 = undefined;
            return parseStreamJson(body, "", field, &unused, out).session_id_len;
        }

        /// Thin wrapper kept for callers (and tests) that only need
        /// the result field. Single-purpose, single-walk shape.
        pub fn extractJsonStreamResult(body: []const u8, field: []const u8, out: []u8) usize {
            var unused: [0]u8 = undefined;
            return parseStreamJson(body, field, "", out, &unused).result_len;
        }

        /// Extract a top-level string field from a JSON object by
        /// name. Writes the JSON-decoded value into `out` and
        /// returns the byte count (0 on parse failure, missing
        /// field, wrong-shape document, or non-string value). Uses
        /// `std.json` so escape sequences including `\uXXXX`
        /// (smart quotes, emoji, non-ASCII paths in `claude -p`'s
        /// `result`) round-trip correctly.
        pub fn extractJsonStringField(body: []const u8, field: []const u8, out: []u8) usize {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch return 0;
            if (parsed != .object) return 0;
            const val = parsed.object.get(field) orelse return 0;
            if (val != .string) return 0;
            const s = val.string;
            const n = @min(s.len, out.len);
            @memcpy(out[0..n], s[0..n]);
            return n;
        }

        /// Single-mode subprocess round-trip. Mirrors `doRequest`'s
        /// contract: success → `cmd_len > 0`; failure → `cmd_len ==
        /// 0` and `err_len > 0` with a human message.
        pub fn doSubprocessRequest(
            gpa: std.mem.Allocator,
            io: std.Io,
            sub: SubprocessProvider,
            shell_name: []const u8,
            context_blob: []const u8,
            prompt: []const u8,
            model: []const u8,
            prepend_argv: []const []const u8,
            session_id_out: []u8,
            session_id_len_out: *usize,
            out: []u8,
            explanation_out: []u8,
            error_out: []u8,
        ) !RequestResult {
            _ = model; // CLI tools take --model in argv (user-configured)
            session_id_len_out.* = 0;

            // Compose the same prompt body that the HTTP path
            // builds, minus the JSON envelope. The subprocess gets
            // system_prompt + user_message concatenated as plain
            // text; the CLI's own model handles it as one shot.
            const user_msg = if (context_blob.len > 0)
                try std.fmt.allocPrint(
                    gpa,
                    "Generate a {s} command to: {s}\n\nContext: {s}",
                    .{ shell_name, prompt, context_blob },
                )
            else
                try std.fmt.allocPrint(
                    gpa,
                    "Generate a {s} command to: {s}",
                    .{ shell_name, prompt },
                );
            defer gpa.free(user_msg);

            const full_prompt = try std.fmt.allocPrint(
                gpa,
                "{s}\n\n{s}",
                .{ effective_system_prompt, user_msg },
            );
            defer gpa.free(full_prompt);

            var err_len: usize = 0;
            const stdout = runSubprocess(gpa, io, sub, full_prompt, prepend_argv, error_out, &err_len) catch {
                return RequestResult{ .cmd_len = 0, .exp_len = 0, .err_len = err_len };
            };
            defer gpa.free(stdout);

            // Decode to the assistant content text per the
            // configured output shape. For `.json_stream` we do a
            // single body walk that captures both the result field
            // AND (when session continuation is configured) the
            // session id — avoids parsing the stream twice on the
            // continuation path.
            var content_buf: [cfg.max_response_bytes]u8 = undefined;
            const content = switch (sub.output) {
                .raw => blk: {
                    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
                    const n = @min(trimmed.len, content_buf.len);
                    @memcpy(content_buf[0..n], trimmed[0..n]);
                    break :blk content_buf[0..n];
                },
                .json_field => |fname| blk: {
                    const n = extractJsonStringField(stdout, fname, &content_buf);
                    if (n == 0) {
                        return RequestResult{ .cmd_len = 0, .exp_len = 0, .err_len = writeStatic(error_out, "subprocess JSON missing requested field") };
                    }
                    break :blk content_buf[0..n];
                },
                .json_stream => |js| blk: {
                    const sid_field = sessionIdField(sub);
                    const p = parseStreamJson(stdout, js.field, sid_field, &content_buf, session_id_out);
                    session_id_len_out.* = p.session_id_len;
                    if (p.result_len == 0) {
                        return RequestResult{ .cmd_len = 0, .exp_len = 0, .err_len = writeStatic(error_out, "stream-json: no result event in subprocess output") };
                    }
                    break :blk content_buf[0..p.result_len];
                },
            };

            const extracted = extractExplanationAndCommand(content, out, explanation_out);
            if (extracted.cmd_len == 0) {
                return RequestResult{ .cmd_len = 0, .exp_len = 0, .err_len = writeStatic(error_out, "couldn't extract a command from the subprocess output") };
            }
            return RequestResult{ .cmd_len = extracted.cmd_len, .exp_len = extracted.explanation_len };
        }

        /// Dialog-mode subprocess round-trip. Mirrors
        /// `doDialogRequest`: `body` arrives as the OpenAI-style
        /// JSON envelope built by `dialog.buildRequestBody`. We
        /// parse it, render the messages as plain text, hand to
        /// the subprocess, return the raw response (the dialog
        /// state machine on the main thread does the JSON-envelope
        /// parse).
        pub fn doSubprocessDialogRequest(
            gpa: std.mem.Allocator,
            io: std.Io,
            sub: SubprocessProvider,
            body: []const u8,
            prepend_argv: []const []const u8,
            session_active: bool,
            session_id_out: []u8,
            session_id_len_out: *usize,
            out: []u8,
            error_out: []u8,
        ) !RequestResult {
            session_id_len_out.* = 0;
            // When a session is active the CLI maintains the
            // conversation — send only the latest user turn instead
            // of re-rendering the whole history.
            const rendered = if (session_active)
                renderLatestUserTurn(gpa, body) catch {
                    return RequestResult{ .cmd_len = 0, .exp_len = 0, .err_len = writeStatic(error_out, "couldn't extract latest user turn for resumed session") };
                }
            else
                renderDialogBodyAsPrompt(gpa, body) catch {
                    return RequestResult{ .cmd_len = 0, .exp_len = 0, .err_len = writeStatic(error_out, "couldn't render dialog body for subprocess") };
                };
            defer gpa.free(rendered);

            var err_len: usize = 0;
            const stdout = runSubprocess(gpa, io, sub, rendered, prepend_argv, error_out, &err_len) catch {
                return RequestResult{ .cmd_len = 0, .exp_len = 0, .err_len = err_len };
            };
            defer gpa.free(stdout);

            const content_n = switch (sub.output) {
                .raw => blk: {
                    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
                    const n = @min(trimmed.len, out.len);
                    @memcpy(out[0..n], trimmed[0..n]);
                    break :blk n;
                },
                .json_field => |fname| extractJsonStringField(stdout, fname, out),
                .json_stream => |js| blk: {
                    // Same single-pass walk as the single-mode
                    // path — captures result + session id in one
                    // scan over the body.
                    const sid_field = sessionIdField(sub);
                    const p = parseStreamJson(stdout, js.field, sid_field, out, session_id_out);
                    session_id_len_out.* = p.session_id_len;
                    break :blk p.result_len;
                },
            };
            if (content_n == 0) {
                return RequestResult{ .cmd_len = 0, .exp_len = 0, .err_len = writeStatic(error_out, "empty response from subprocess") };
            }

            // Strip surrounding fence the way `extractRawContent`
            // does for the HTTP dialog path — small models like to
            // wrap JSON in ```json … ``` despite the system prompt
            // saying not to.
            const stripped_n = stripJsonFence(out[0..content_n], out);
            return RequestResult{ .cmd_len = stripped_n, .exp_len = 0 };
        }

        /// Render the LATEST user message from an OpenAI-style
        /// body — for session-continuation mode where the CLI
        /// already has the conversation history and only needs
        /// the new user turn. Falls back to the full body if no
        /// user role is found (degrades to the same behavior as
        /// the non-session path).
        fn renderLatestUserTurn(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
            const Message = struct {
                role: []const u8,
                content: []const u8,
            };
            const Parsed = struct {
                model: []const u8 = "",
                messages: []const Message = &.{},
                stream: bool = false,
            };
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const parsed = std.json.parseFromSliceLeaky(Parsed, arena.allocator(), body, .{ .ignore_unknown_fields = true }) catch {
                // Fall through to the role-rendered fallback rather
                // than hand raw JSON to the CLI — the parse path is
                // unreachable today (dialog.buildRequestBody is the
                // sole producer) but a future producer change would
                // otherwise silently send bytes the model can't
                // make sense of.
                return renderDialogBodyAsPrompt(gpa, body);
            };
            var i: usize = parsed.messages.len;
            while (i > 0) {
                i -= 1;
                const msg = parsed.messages[i];
                if (std.mem.eql(u8, msg.role, "user")) {
                    return gpa.dupe(u8, msg.content);
                }
            }
            return renderDialogBodyAsPrompt(gpa, body);
        }

        /// Render an OpenAI-style request body as plain text for a
        /// subprocess that has no notion of "messages". Walks the
        /// JSON, emits each message as `ROLE:\n<content>\n\n`.
        fn renderDialogBodyAsPrompt(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
            const Message = struct {
                role: []const u8,
                content: []const u8,
            };
            const Parsed = struct {
                model: []const u8 = "",
                messages: []const Message = &.{},
                stream: bool = false,
            };
            // ParseFromSliceLeaky over a single-use arena — every
            // string borrows from the arena bytes, freed in one go.
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const parsed = std.json.parseFromSliceLeaky(Parsed, arena.allocator(), body, .{ .ignore_unknown_fields = true }) catch {
                // Body wasn't parseable as the expected shape — fall
                // back to handing the whole body verbatim. Better
                // than failing the request.
                return gpa.dupe(u8, body);
            };

            var allocating: std.Io.Writer.Allocating = .init(gpa);
            errdefer allocating.deinit();
            for (parsed.messages) |msg| {
                try allocating.writer.print("{s}:\n{s}\n\n", .{ msg.role, msg.content });
            }
            return allocating.toOwnedSlice();
        }

        /// Strip ```json … ``` (or bare ``` … ```) wrapping if
        /// present. In-place safe — `out` and `buf` may overlap;
        /// data is read before being overwritten because the trim
        /// only moves bytes earlier.
        fn stripJsonFence(buf: []const u8, out: []u8) usize {
            const trimmed = std.mem.trim(u8, buf, " \t\r\n");
            if (!std.mem.startsWith(u8, trimmed, "```")) {
                if (trimmed.ptr != out.ptr) {
                    @memmove(out[0..trimmed.len], trimmed);
                }
                return trimmed.len;
            }
            const nl = std.mem.indexOfScalar(u8, trimmed[3..], '\n') orelse {
                if (trimmed.ptr != out.ptr) @memmove(out[0..trimmed.len], trimmed);
                return trimmed.len;
            };
            const after_open = 3 + nl + 1;
            const close_at = std.mem.indexOfPos(u8, trimmed, after_open, "```") orelse {
                if (trimmed.ptr != out.ptr) @memmove(out[0..trimmed.len], trimmed);
                return trimmed.len;
            };
            if (close_at <= after_open) {
                if (trimmed.ptr != out.ptr) @memmove(out[0..trimmed.len], trimmed);
                return trimmed.len;
            }
            const inner = std.mem.trim(u8, trimmed[after_open..close_at], " \t\r\n");
            @memmove(out[0..inner.len], inner);
            return inner.len;
        }

        /// Apply the explanation + fenced-command shape to an
        /// already-decoded assistant content string. Parallel to
        /// `extractResponse` minus the `decodeContent` step that
        /// pulls the field out of an OpenAI JSON envelope.
        fn extractExplanationAndCommand(content: []const u8, cmd_out: []u8, explanation_out: []u8) ExtractedResponse {
            const fence_open_idx = std.mem.indexOf(u8, content, "```") orelse {
                return .{
                    .cmd_len = parse.sanitizeCommand(content, cmd_out),
                    .explanation_len = 0,
                };
            };
            const after_open = fence_open_idx + 3;
            const inner_start = if (std.mem.indexOfScalar(u8, content[after_open..], '\n')) |nl|
                after_open + nl + 1
            else
                after_open;
            const fence_close_idx = std.mem.indexOfPos(u8, content, inner_start, "```") orelse {
                return .{
                    .cmd_len = parse.sanitizeCommand(content, cmd_out),
                    .explanation_len = 0,
                };
            };
            const explanation_raw = std.mem.trim(u8, content[0..fence_open_idx], " \t\r\n");
            const fence_body = content[inner_start..fence_close_idx];
            return .{
                .cmd_len = parse.sanitizeCommand(fence_body, cmd_out),
                .explanation_len = parse.sanitizeExplanation(explanation_raw, explanation_out),
            };
        }

        /// Worker thread function. Owns the lock-and-wait loop:
        /// waits on `shared.cv` until either `shared.shutdown` or
        /// `shared.req_pending` is set, then dispatches based on
        /// `shared.req_kind` + `shared.dispatch_mode`. Resolves
        /// the provider RUNTIME via `resolveProviderForMode` so
        /// `cfg.providers[]` can hold a mix of HTTP and subprocess
        /// entries (both transport arms ship in the binary —
        /// ~2 KB cost accepted per #162 design). Picks HTTP
        /// (`doRequest` / `doDialogRequest`) or subprocess
        /// (`doSubprocessRequest` / `doSubprocessDialogRequest`).
        /// Fixture-replay (`cfg.fixture_responses` non-empty) is
        /// provider-agnostic — replays canned responses before any
        /// transport dispatch. Always signals completion via
        /// `res_done = true` so the proxy can clear `in_flight`
        /// regardless of outcome.
        pub fn worker(
            shared: *Shared,
            io: std.Io,
            gpa: std.mem.Allocator,
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
                // identically. The `shared.current_provider_idx` read is the
                // ONLY field intentionally skipped here (fixture
                // responses are model-agnostic).
                if (cfg.fixture_responses.len > 0) {
                    const fixture_n = cfg.fixture_responses.len;
                    const fi = shared.fixture_idx % fixture_n;
                    shared.fixture_idx = (fi + 1) % fixture_n;
                    const canned = cfg.fixture_responses[fi];
                    const copy_n = @min(canned.len, cfg.max_response_bytes);
                    var fixture_err: usize = 0;
                    storeResponse(gpa, shared, canned[0..copy_n]) catch {
                        clearResBuf(gpa, shared);
                        const oom_msg = "out of memory staging fixture response";
                        fixture_err = @min(oom_msg.len, shared.error_buf.len);
                        @memcpy(shared.error_buf[0..fixture_err], oom_msg[0..fixture_err]);
                    };
                    shared.explanation_len = 0;
                    shared.error_len = fixture_err;
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
                const provider_idx = shared.current_provider_idx;
                const dispatch_mode = shared.dispatch_mode;
                // Snapshot the session id under the same lock so the
                // worker has a stable view while building argv.
                var session_id_local: [256]u8 = undefined;
                const session_id_len = shared.request_session_id_len;
                if (session_id_len > 0) {
                    @memcpy(session_id_local[0..session_id_len], shared.request_session_id_buf[0..session_id_len]);
                }
                shared.mutex.unlock(io);

                // Resolve which provider serves THIS request. Runtime
                // dispatch — providers[] can hold a mix of HTTP and
                // subprocess entries, so the worker can't comptime-
                // DCE either arm. Empty providers[] returns the
                // single-provider shorthand from cfg.provider.
                const resolved = resolveProviderForMode(dispatch_mode, cfg.providers, cfg.provider, provider_idx);

                // Fire the request OUTSIDE the lock — it may block
                // for many seconds.
                var response_buf: [cfg.max_response_bytes]u8 = undefined;
                var explanation_local: [512]u8 = undefined;
                var error_local: [256]u8 = undefined;
                var captured_session_id: [256]u8 = undefined;
                var captured_session_id_len: usize = 0;
                // Resume-argv slot — only populated when the resolved
                // provider is subprocess with `.session = .continuation`
                // AND we have a captured id.
                var resume_argv_storage: [2][]const u8 = undefined;
                const resume_argv: []const []const u8 = switch (resolved.provider) {
                    .subprocess => |sub| switch (sub.session) {
                        .continuation => |c| if (session_id_len > 0) blk: {
                            resume_argv_storage[0] = c.flag;
                            resume_argv_storage[1] = session_id_local[0..session_id_len];
                            break :blk resume_argv_storage[0..2];
                        } else &.{},
                        .none => &.{},
                    },
                    .http => &.{},
                };
                const result = switch (resolved.provider) {
                    .http => |http| blk: {
                        const api_base = env_mod_ns.resolveHttpApiBase(gpa, http) catch break :blk RequestResult{
                            .cmd_len = 0,
                            .exp_len = 0,
                            .err_len = writeStatic(&error_local, "out of memory resolving api_base"),
                        };
                        defer gpa.free(api_base);
                        if (api_base.len == 0) break :blk RequestResult{
                            .cmd_len = 0,
                            .exp_len = 0,
                            .err_len = writeStatic(&error_local, "no HTTP endpoint configured for this provider"),
                        };
                        const api_key = env_mod_ns.resolveHttpApiKey(gpa, http) catch break :blk RequestResult{
                            .cmd_len = 0,
                            .exp_len = 0,
                            .err_len = writeStatic(&error_local, "out of memory resolving api_key"),
                        };
                        defer gpa.free(api_key);
                        break :blk if (req_kind == .single)
                            doRequest(
                                gpa,
                                io,
                                api_base,
                                api_key,
                                shell_name,
                                context_blob,
                                prompt_local[0..prompt_len],
                                http.model,
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
                    },
                    .subprocess => |sub| if (req_kind == .single)
                        doSubprocessRequest(
                            gpa,
                            io,
                            sub,
                            shell_name,
                            context_blob,
                            prompt_local[0..prompt_len],
                            "", // model: subprocess bakes it into argv
                            resume_argv,
                            &captured_session_id,
                            &captured_session_id_len,
                            &response_buf,
                            &explanation_local,
                            &error_local,
                        ) catch RequestResult{
                            .cmd_len = 0,
                            .exp_len = 0,
                            .err_len = writeStatic(&error_local, "internal error in worker"),
                        }
                    else
                        doSubprocessDialogRequest(
                            gpa,
                            io,
                            sub,
                            body_local[0..body_len],
                            resume_argv,
                            session_id_len > 0,
                            &captured_session_id,
                            &captured_session_id_len,
                            &response_buf,
                            &error_local,
                        ) catch RequestResult{
                            .cmd_len = 0,
                            .exp_len = 0,
                            .err_len = writeStatic(&error_local, "internal error in worker"),
                        },
                };

                // Signal completion regardless of outcome — proxy
                // needs to clear `in_flight` so the 🧠 thinking…
                // statusbar doesn't stick when a request fails.
                // The proxy filters stale-generation responses
                // separately.
                shared.mutex.lockUncancelable(io);
                if (result.cmd_len > 0) {
                    storeResponse(gpa, shared, response_buf[0..result.cmd_len]) catch {
                        // OOM staging the response — fall through to
                        // the error path so the proxy still sees
                        // res_done and clears in_flight.
                        clearResBuf(gpa, shared);
                        shared.explanation_len = 0;
                        const oom_msg = "out of memory staging response";
                        const en = @min(oom_msg.len, shared.error_buf.len);
                        @memcpy(shared.error_buf[0..en], oom_msg[0..en]);
                        shared.error_len = en;
                        shared.res_gen = serving_gen;
                        shared.res_kind = req_kind;
                        shared.res_done = true;
                        shared.mutex.unlock(io);
                        continue;
                    };
                    if (result.exp_len > 0) {
                        @memcpy(shared.explanation_buf[0..result.exp_len], explanation_local[0..result.exp_len]);
                        shared.explanation_len = result.exp_len;
                    } else {
                        shared.explanation_len = 0;
                    }
                    shared.error_len = 0;
                } else {
                    clearResBuf(gpa, shared);
                    shared.explanation_len = 0;
                    if (result.err_len > 0) {
                        const en = @min(result.err_len, shared.error_buf.len);
                        @memcpy(shared.error_buf[0..en], error_local[0..en]);
                        shared.error_len = en;
                    } else {
                        shared.error_len = 0;
                    }
                }
                // Publish a freshly-captured session id (if any).
                // Zero-length writes leave the previous response
                // slot untouched on purpose — a result event that
                // didn't carry an init line shouldn't clobber the
                // id captured on the first turn.
                if (captured_session_id_len > 0) {
                    const en = @min(captured_session_id_len, shared.response_session_id_buf.len);
                    @memcpy(shared.response_session_id_buf[0..en], captured_session_id[0..en]);
                    shared.response_session_id_len = en;
                }
                shared.res_gen = serving_gen;
                shared.res_kind = req_kind;
                shared.res_done = true;
                shared.mutex.unlock(io);
            }
        }
    };
}

test {
    _ = @import("worker_tests.zig");
}
