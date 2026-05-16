//! Env-var resolution helpers for the LLM module. Extracted from
//! `llm.zig` per the file-split plan in
//! `docs/llm-exec-mode-followups.md` — these are pure-ish
//! configure-time / attach-time helpers that close over `cfg`
//! (API endpoint env-var names, context-vars list, shell name
//! override). Returning a `Module(comptime cfg: Config) type`
//! factory mirrors the dialog.zig / worker.zig extracts.
//!
//! What's exposed (all `pub`, callable as
//! `env.Module(cfg).resolveApiBase(allocator)`):
//!
//!   - `resolveApiBase` — applies the priority order
//!     (cfg.api_base → cfg.api_base_env → cfg.api_base_fallback_env
//!     with `/v1` suffix for Ollama-shaped endpoints). Strips a
//!     trailing slash so `<base>/chat/completions` lands clean.
//!   - `resolveEnv` — generic env-var → owned-slice helper, used
//!     for `cfg.api_key_env`.
//!   - `resolveContextEnv` — builds the context-blob string
//!     (`KEY=value, KEY2=value2`) from `cfg.context_env_vars`.
//!     Sanitises whitespace / control bytes inside values via
//!     `writeSanitizedEnvValue` to keep the JSON-encoded prompt
//!     body single-line.
//!   - `writeSanitizedEnvValue` — helper exposed pub so callers
//!     can use the same sanitiser if they're building their own
//!     context-blob shapes.
//!   - `resolveShell` — basename-extraction from `cfg.shell` /
//!     `$SHELL` / fallback to `"sh"`.
//!   - `envValue` — libc `getenv` wrapper that returns the value
//!     as a sentinel-trimmed slice, or null if unset/empty. Used
//!     internally by the other resolvers; exposed pub so the
//!     surrounding module can also probe env in the same shape.

const std = @import("std");
const types = @import("types.zig");
const Config = types.Config;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

pub fn Module(comptime cfg: Config) type {
    return struct {
        pub fn resolveApiBase(allocator: std.mem.Allocator) ![]u8 {
            // Priority order: static cfg → primary env → fallback env
            // (with /v1 suffixing for the Ollama path). Normalize a
            // single trailing slash on each — `doRequest` appends
            // `/chat/completions`, so a base ending in `/` would
            // produce `…//chat/completions`, which some
            // proxies/routers reject or normalize inconsistently.
            // Strip exactly one slash; we don't want to collapse
            // intentional multi-segment paths.
            if (cfg.api_base.len > 0) {
                const s = cfg.api_base;
                const trimmed = if (s[s.len - 1] == '/') s[0 .. s.len - 1] else s;
                return allocator.dupe(u8, trimmed);
            }
            if (envValue(cfg.api_base_env)) |s| {
                const trimmed = if (s.len > 0 and s[s.len - 1] == '/') s[0 .. s.len - 1] else s;
                return allocator.dupe(u8, trimmed);
            }
            if (envValue(cfg.api_base_fallback_env)) |s| {
                const trimmed = if (s.len > 0 and s[s.len - 1] == '/') s[0 .. s.len - 1] else s;
                if (std.mem.endsWith(u8, trimmed, "/v1")) return allocator.dupe(u8, trimmed);
                return std.fmt.allocPrint(allocator, "{s}/v1", .{trimmed});
            }
            return allocator.dupe(u8, "");
        }

        pub fn resolveEnv(allocator: std.mem.Allocator, env_name: []const u8) ![]u8 {
            if (envValue(env_name)) |s| return allocator.dupe(u8, s);
            return allocator.dupe(u8, "");
        }

        /// Build the env-var context blob from `cfg.context_env_vars`.
        /// Format: `KEY=value, KEY2=value2` — single line, comma-
        /// separated, only entries whose env var is set and non-
        /// empty are included. Returns an empty slice when no
        /// matches are found so the worker can append-and-no-op.
        pub fn resolveContextEnv(allocator: std.mem.Allocator) ![]u8 {
            if (cfg.context_env_vars.len == 0) return allocator.dupe(u8, "");
            var allocating: std.Io.Writer.Allocating = .init(allocator);
            errdefer allocating.deinit();
            var first = true;
            for (cfg.context_env_vars) |env_name| {
                const v = envValue(env_name) orelse continue;
                if (!first) try allocating.writer.writeAll(", ");
                first = false;
                try allocating.writer.print("{s}=", .{env_name});
                try writeSanitizedEnvValue(&allocating.writer, v);
            }
            return allocating.toOwnedSlice();
        }

        /// Write an env-var value into the context blob writer with
        /// any whitespace / control bytes collapsed to a single
        /// space. Env values can legally contain newlines, carriage
        /// returns, tabs, NUL — without sanitisation a value with
        /// `\n` would split the "one-line" context across multiple
        /// lines in the JSON-encoded prompt body, confusing the
        /// model and risking prompt-injection-shaped behaviours.
        /// Per-value cap of 256 bytes after sanitisation; longer
        /// values truncate with no ellipsis (the context is a
        /// hint, not authoritative).
        pub fn writeSanitizedEnvValue(w: *std.Io.Writer, v: []const u8) !void {
            const max_per_value = 256;
            var written: usize = 0;
            var last_was_space = false;
            for (v) |b| {
                if (written >= max_per_value) break;
                if (b < 0x20 or b == 0x7F or b == ' ' or b == '\t' or b == '\r' or b == '\n') {
                    if (last_was_space) continue;
                    try w.writeByte(' ');
                    written += 1;
                    last_was_space = true;
                    continue;
                }
                try w.writeByte(b);
                written += 1;
                last_was_space = false;
            }
        }

        pub fn resolveShell(allocator: std.mem.Allocator) ![]u8 {
            if (cfg.shell) |s| return allocator.dupe(u8, s);
            if (envValue("SHELL")) |s| {
                if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return allocator.dupe(u8, s[i + 1 ..]);
                return allocator.dupe(u8, s);
            }
            return allocator.dupe(u8, "sh");
        }

        pub fn envValue(env_name: []const u8) ?[]const u8 {
            // Null-terminated lookup via libc — we don't want to
            // walk std.os.environ ourselves.
            var name_buf: [128]u8 = undefined;
            if (env_name.len >= name_buf.len) return null;
            @memcpy(name_buf[0..env_name.len], env_name);
            name_buf[env_name.len] = 0;
            const v = getenv(@ptrCast(&name_buf)) orelse return null;
            const s = std.mem.sliceTo(v, 0);
            if (s.len == 0) return null;
            return s;
        }
    };
}
