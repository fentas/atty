//! Pure path-token detection for mouse_links.
//!
//! Given a captured terminal line + a column (1-based), find the
//! path-shaped substring whose extent covers that column, parse off
//! any `:LINE` / `:LINE:COL` suffix the line emitter appended, and
//! return both. Designed for compiler/test/grep output shapes:
//!
//!     src/foo.zig:42:7: error: …
//!     /abs/path/to/file.rs:13:1
//!     ./test/integration_tests.zig
//!     "src/with space/x.md":5
//!
//! Rejects clear non-paths (URLs, bare numbers, emails) so the click
//! is a no-op rather than launching `$EDITOR /home/u/https:` style.
//!
//! Stateless and allocation-free — returns slices into the input.
//! Hot-path safe; the module wrapper owns the captured buffer's
//! lifetime.
//!
//! **Caller responsibility:** the returned `path` is NOT sanitised
//! for shell metacharacters. Pass it to `$EDITOR` via an execve-
//! style argv (no shell), never via `system()` / `popen()` /
//! `sh -c`. Path strings can legitimately contain `*`, `?`, `[`,
//! `$`, etc. and we deliberately don't quote them here.

const std = @import("std");

pub const Hit = struct {
    /// Path text, with quotes and trailing punctuation stripped.
    path: []const u8,
    /// 1-based line number from a `:N` suffix; null if absent.
    line: ?u32,
    /// 1-based column number from a `:N:M` suffix; null if absent.
    col: ?u32,
};

pub const Options = struct {
    /// Accept tokens without a leading `/` (e.g. `src/foo.zig`).
    /// Relative paths are the dominant compiler-output shape.
    accept_relative: bool = true,
};

/// Find a path-shaped token in `line` whose run covers `click_col`
/// (1-based). Returns null when no candidate covers the column or
/// the candidate fails the path-shape filter.
pub fn find(line: []const u8, click_col: u16, opts: Options) ?Hit {
    if (click_col == 0 or line.len == 0) return null;

    const click_idx = byteIndexAtColumn(line, click_col);
    if (click_idx == null) return null;
    const idx = click_idx.?;

    if (quotedHit(line, idx, opts)) |hit| return hit;

    if (classify(expandRun(line, idx, .right), opts)) |hit| return hit;
    if (idx > 0) {
        if (classify(expandRun(line, idx, .left), opts)) |hit| return hit;
    }
    return null;
}

fn classify(run_in: []const u8, opts: Options) ?Hit {
    if (run_in.len == 0) return null;
    const run = stripWrappers(run_in);
    if (run.len == 0) return null;

    var path_part = run;
    var line_n: ?u32 = null;
    var col_n: ?u32 = null;
    if (splitTrailingNumber(path_part)) |s1| {
        if (splitTrailingNumber(s1.head)) |s2| {
            path_part = s2.head;
            line_n = s2.n;
            col_n = s1.n;
        } else {
            path_part = s1.head;
            line_n = s1.n;
        }
    }

    if (path_part.len == 0) return null;
    if (!isPathShape(path_part, opts)) return null;
    return .{ .path = path_part, .line = line_n, .col = col_n };
}

/// Resolve a click inside a `"..."` or `'...'` region to a Hit.
/// The path is the inner content; if the closing quote is followed
/// by `:N` / `:N:M`, those parse as line/col. Lets a click anywhere
/// inside a quoted path-with-spaces resolve to the full path.
fn quotedHit(line: []const u8, idx: usize, opts: Options) ?Hit {
    return quotedHitWithDelim(line, idx, '"', opts) orelse
        quotedHitWithDelim(line, idx, '\'', opts);
}

fn quotedHitWithDelim(line: []const u8, idx: usize, delim: u8, opts: Options) ?Hit {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] != delim) {
            i += 1;
            continue;
        }
        const open = i;
        var j: usize = open + 1;
        while (j < line.len and line[j] != delim) : (j += 1) {}
        if (j >= line.len) return null;
        if (idx > open and idx < j) {
            const path = line[open + 1 .. j];
            if (!isPathShape(path, opts)) return null;

            var line_n: ?u32 = null;
            var col_n: ?u32 = null;
            if (j + 1 < line.len and line[j + 1] == ':') {
                var k: usize = j + 2;
                const first_start = k;
                while (k < line.len and std.ascii.isDigit(line[k])) : (k += 1) {}
                const first = line[first_start..k];
                if (first.len > 0 and first.len <= 10) {
                    line_n = std.fmt.parseInt(u32, first, 10) catch null;
                    if (line_n != null and k + 1 < line.len and line[k] == ':') {
                        const second_start = k + 1;
                        var m: usize = second_start;
                        while (m < line.len and std.ascii.isDigit(line[m])) : (m += 1) {}
                        const second = line[second_start..m];
                        if (second.len > 0 and second.len <= 10) {
                            col_n = std.fmt.parseInt(u32, second, 10) catch null;
                        }
                    }
                }
            }

            return .{ .path = path, .line = line_n, .col = col_n };
        }
        i = j + 1;
    }
    return null;
}

/// Map a 1-based terminal column to a byte index in `line`. Assumes
/// ASCII-equivalent width (one cell per byte). The capture path
/// strips SGR sequences before storing, but multi-byte UTF-8 still
/// gets counted byte-wise — close enough for the common
/// English/ASCII compiler-output target. A later refactor can pull
/// in atty's existing display-width helpers if needed.
fn byteIndexAtColumn(line: []const u8, col: u16) ?usize {
    const i: usize = @as(usize, col) - 1;
    if (i >= line.len) return null;
    return i;
}

const Side = enum { left, right };

/// Expand from `idx` outward to the run of non-whitespace characters
/// containing the click. When `idx` lands on a separator the side
/// preference picks which neighbour token to try — callers retry
/// the opposite side on miss to keep the click forgiving.
fn expandRun(line: []const u8, idx: usize, side: Side) []const u8 {
    if (idx >= line.len) return &.{};

    var pivot = idx;
    if (isBoundary(line[pivot])) {
        switch (side) {
            .right => {
                var k = pivot + 1;
                while (k < line.len and isBoundary(line[k])) : (k += 1) {}
                if (k >= line.len) return &.{};
                pivot = k;
            },
            .left => {
                if (pivot == 0) return &.{};
                var k = pivot;
                while (k > 0 and isBoundary(line[k - 1])) : (k -= 1) {}
                if (k == 0) return &.{};
                pivot = k - 1;
            },
        }
    }

    var start: usize = pivot;
    while (start > 0 and !isBoundary(line[start - 1])) start -= 1;

    var end: usize = pivot + 1;
    while (end < line.len and !isBoundary(line[end])) end += 1;

    return line[start..end];
}

/// Strip surrounding quotes / brackets / matched punctuation, then
/// drop a trailing `,`, `.`, or `:` left by prose-style emission
/// (the `:` after `src/foo.zig:42:7:` in compiler output is
/// punctuation, not a path delimiter).
fn stripWrappers(s: []const u8) []const u8 {
    var t = s;
    if (t.len >= 2) {
        const open = t[0];
        const close = t[t.len - 1];
        const matched: bool = switch (open) {
            '"' => close == '"',
            '\'' => close == '\'',
            '(' => close == ')',
            '[' => close == ']',
            '<' => close == '>',
            '{' => close == '}',
            else => false,
        };
        if (matched) t = t[1 .. t.len - 1];
    }
    while (t.len > 0) {
        const c = t[t.len - 1];
        if (c == ',' or c == '.' or c == ':' or c == ';' or c == ')' or c == ']' or c == '}' or c == '>') {
            t = t[0 .. t.len - 1];
        } else break;
    }
    return t;
}

/// Try to peel a trailing `:NUMBER` off the run. The path itself
/// may legitimately contain digits, so we only strip when the tail
/// is `:` followed by 1..10 ASCII digits to end-of-string.
fn splitTrailingNumber(s: []const u8) ?struct { head: []const u8, n: u32 } {
    const end: usize = s.len;
    var i: usize = end;
    while (i > 0 and std.ascii.isDigit(s[i - 1])) : (i -= 1) {}
    const digits = s[i..end];
    if (digits.len == 0 or digits.len > 10) return null;
    if (i == 0 or s[i - 1] != ':') return null;
    const n = std.fmt.parseInt(u32, digits, 10) catch return null;
    return .{ .head = s[0 .. i - 1], .n = n };
}

/// Filter the post-strip path candidate to something that plausibly
/// names a file on disk. Hard rejections (URLs, schemes) avoid
/// pointing $EDITOR at junk; soft requirements (must contain `/` or
/// a known extension) avoid clicking on bare words like `Cargo` or
/// `Makefile` — except those are common filenames, so we whitelist
/// a few unambiguous cases.
fn isPathShape(s: []const u8, opts: Options) bool {
    if (containsScheme(s)) return false;
    if (looksLikeEmail(s)) return false;
    if (isAllDigits(s)) return false;

    // A bare `/` or `~` is not a useful click target — require at
    // least one more byte so `$EDITOR` always gets a name to open.
    if (s.len < 2) return false;

    const absolute = s[0] == '/';
    const tilde = s[0] == '~';
    const dot_rel = std.mem.startsWith(u8, s, "./") or std.mem.startsWith(u8, s, "../");
    const has_slash = std.mem.indexOfScalar(u8, s, '/') != null;
    const has_known_ext = hasKnownExtension(s);
    const is_known_bare = isKnownBareFilename(s);

    if (absolute or tilde or dot_rel) return true;
    if (opts.accept_relative and (has_slash or has_known_ext)) return true;
    if (is_known_bare) return true;
    return false;
}

fn containsScheme(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "://") != null;
}

fn looksLikeEmail(s: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at + 1 >= s.len) return false;
    return std.mem.indexOfScalarPos(u8, s, at + 1, '.') != null;
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// Editable-text formats only; binaries/media (.png/.pdf/.bin) are
// intentionally absent — `$EDITOR` opening a PDF is a worse UX
// than the click being a no-op.
const known_exts = [_][]const u8{
    ".zig",   ".rs",   ".c",     ".h",   ".cpp",   ".hpp",    ".cc",  ".cxx",
    ".go",    ".py",   ".pyi",   ".js",  ".jsx",   ".ts",     ".tsx", ".mjs",
    ".cjs",   ".rb",   ".java",  ".kt",  ".swift", ".scala",  ".cs",  ".fs",
    ".vb",    ".php",  ".pl",    ".lua", ".sh",    ".bash",   ".zsh", ".fish",
    ".md",    ".rst",  ".txt",   ".log", ".toml",  ".yaml",   ".yml", ".json",
    ".jsonl", ".html", ".htm",   ".css", ".scss",  ".less",   ".vue", ".svelte",
    ".tex",   ".dot",  ".proto", ".sql", ".csv",   ".tsv",    ".ini", ".conf",
    ".cfg",   ".env",  ".lock",  ".mk",  ".cmake", ".gradle",
};

fn hasKnownExtension(s: []const u8) bool {
    for (known_exts) |ext| {
        if (std.ascii.endsWithIgnoreCase(s, ext)) return true;
    }
    return false;
}

const known_bare = [_][]const u8{
    "Makefile",   "makefile",      "GNUmakefile",
    "Dockerfile", "Containerfile", "Rakefile",
    "Gemfile",    "BUILD",         "WORKSPACE",
};

fn isKnownBareFilename(s: []const u8) bool {
    for (known_bare) |name| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

fn isBoundary(c: u8) bool {
    return c <= 0x20 or c == 0x7f;
}

test {
    _ = @import("path_detect_tests.zig");
}
