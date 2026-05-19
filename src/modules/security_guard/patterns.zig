//! Pattern matchers for security_guard Tier 1.
//!
//! Each pattern is a `(category, description, match_fn)` triple.
//! Match functions return the matched substring on a hit (used as
//! the trust-cache key after SHA-256ing) or null on no match.
//!
//! Keep these self-contained: no allocations, no I/O — they're
//! comptime-known and walked on every Enter. Heavy work belongs in
//! the V2 sidecar.

const std = @import("std");

pub const Category = enum {
    curl_pipe_sh,
    npm_unsafe_install,
    bash_c_base64,
};

pub const Pattern = struct {
    category: Category,
    /// Short human-facing description rendered in the banner.
    description: []const u8,
    /// Match function. Returns the matched substring (the portion
    /// that triggered the hit) so the trust cache can key on it.
    /// MUST be pure / no side effects — called on every Enter.
    match: *const fn (line: []const u8) ?[]const u8,
};

pub const default_patterns: [4]Pattern = .{
    .{ .category = .curl_pipe_sh, .description = "remote-fetch-and-execute (`curl … | sh`)", .match = matchCurlPipeSh },
    .{ .category = .npm_unsafe_install, .description = "`npm install` of a flagged package name", .match = matchNpmUnsafe },
    .{ .category = .bash_c_base64, .description = "`bash -c` with a long base64-shaped payload", .match = matchBashCBase64 },
    // Flagged-URL matcher last so prior tests indexed at [0..2]
    // keep referring to the same patterns. The category re-uses
    // `curl_pipe_sh` because the trust-cache + threat-level
    // mapping is identical (a flagged IOC URL is morally the
    // same shape as a `curl|sh`); future work can split this
    // into its own category if banner reasons need finer
    // distinction.
    .{ .category = .curl_pipe_sh, .description = "command references a flagged-URL substring (known IOC / exploit-PoC host)", .match = matchFlaggedUrl },
};

// ---------------------------------------------------------------------------
// Flagged URLs — substring match against the typed line. Loaded from
// the shared data file (same approach as flagged_npm.txt).

const flagged_urls_raw = @embedFile("data/flagged_urls.txt");

fn parseFlaggedUrls() []const []const u8 {
    @setEvalBranchQuota(20000);
    comptime {
        var urls: [128][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, flagged_urls_raw, '\n');
        while (it.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue;
            if (n >= urls.len) @compileError("flagged_urls.txt exceeds 128 entries");
            urls[n] = trimmed;
            n += 1;
        }
        const final = urls[0..n].*;
        return &final;
    }
}

const flagged_urls = parseFlaggedUrls();

fn matchFlaggedUrl(line: []const u8) ?[]const u8 {
    for (flagged_urls) |needle| {
        if (std.mem.indexOf(u8, line, needle)) |at| {
            return line[at .. at + needle.len];
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// curl|sh / wget|sh family
//
// Matches when ANY of {curl, wget, fetch} appears before a pipe AND
// the pipe target is {sh, bash, zsh, fish, dash, ksh}. The classic
// drive-by-install signature. Detects `curl url | sh -s -- args`,
// `wget -O- url | bash`, etc.
//
// Returns the slice from the fetcher invocation through the shell
// target so the trust hash includes the URL — trusting one
// `curl|sh` doesn't trust all of them.

fn matchCurlPipeSh(line: []const u8) ?[]const u8 {
    const fetchers = [_][]const u8{ "curl ", "wget ", "fetch " };
    const shells = [_][]const u8{ " sh", " bash", " zsh", " fish", " dash", " ksh" };

    var fetcher_start: ?usize = null;
    for (fetchers) |f| {
        if (std.mem.indexOf(u8, line, f)) |i| {
            if (fetcher_start == null or i < fetcher_start.?) fetcher_start = i;
        }
    }
    const start = fetcher_start orelse return null;

    const pipe = std.mem.indexOfScalarPos(u8, line, start, '|') orelse return null;
    if (pipe + 1 >= line.len) return null;

    // After '|' there may be whitespace then the shell name. Strip
    // leading space.
    var after = pipe + 1;
    while (after < line.len and line[after] == ' ') after += 1;

    for (shells) |sh| {
        // shells[] starts with a space; match against the substring
        // beginning at `pipe` (so the space is consumed from the
        // pipe side either way).
        const trim_sh = sh[1..];
        if (after + trim_sh.len <= line.len and
            std.mem.eql(u8, line[after .. after + trim_sh.len], trim_sh))
        {
            // Terminator must be EOL, space, semicolon, or pipe.
            const end = after + trim_sh.len;
            if (end == line.len or line[end] == ' ' or line[end] == ';' or line[end] == '|' or line[end] == '\n' or line[end] == '\r') {
                return line[start..end];
            }
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// npm install <flagged-package>
//
// Load the package list from the SHARED data file in
// `atty-guard/data/flagged_npm.txt`. The Rust sidecar's classifier
// includes the same file via `include_str!`. Editing the .txt
// updates both sides on the next build.

const flagged_npm_raw = @embedFile("data/flagged_npm.txt");

/// Comptime-parse the embedded data file: split on '\n', trim
/// trailing CR/space, skip blank lines + '#'-prefixed comments.
/// Returns a slice of static-lifetime strings (all slices reference
/// the original `@embedFile` buffer).
fn parseFlaggedNpm() []const []const u8 {
    @setEvalBranchQuota(20000);
    comptime {
        var packages: [256][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, flagged_npm_raw, '\n');
        while (it.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue;
            if (n >= packages.len) @compileError("flagged_npm.txt exceeds 256 entries — bump the buffer");
            packages[n] = trimmed;
            n += 1;
        }
        const final = packages[0..n].*;
        return &final;
    }
}

const flagged_npm_packages = parseFlaggedNpm();

fn matchNpmUnsafe(line: []const u8) ?[]const u8 {
    // Accepts: `npm install <pkg>`, `npm i <pkg>`, `npm add <pkg>`,
    // also pnpm/yarn variants.
    const verb_pairs = [_]struct { cmd: []const u8, verb: []const u8 }{
        .{ .cmd = "npm ", .verb = "install" },
        .{ .cmd = "npm ", .verb = "i " },
        .{ .cmd = "npm ", .verb = "add" },
        .{ .cmd = "pnpm ", .verb = "install" },
        .{ .cmd = "pnpm ", .verb = "i " },
        .{ .cmd = "pnpm ", .verb = "add" },
        .{ .cmd = "yarn ", .verb = "add" },
    };

    var match_start: ?usize = null;
    var args_start: ?usize = null;
    for (verb_pairs) |vp| {
        const cmd_at = std.mem.indexOf(u8, line, vp.cmd) orelse continue;
        // Must be at start of line OR after whitespace / ';' / '&&'.
        if (cmd_at != 0) {
            const prev = line[cmd_at - 1];
            if (prev != ' ' and prev != ';' and prev != '&' and prev != '|') continue;
        }
        const after_cmd = cmd_at + vp.cmd.len;
        if (after_cmd + vp.verb.len > line.len) continue;
        const verb_end = after_cmd + vp.verb.len;
        // The literal `i ` already includes the trailing space; for
        // the others require a space (or EOL) after the verb.
        if (!std.mem.endsWith(u8, vp.verb, " ")) {
            if (verb_end == line.len) continue;
            if (line[verb_end] != ' ') continue;
        }
        if (!std.mem.eql(u8, line[after_cmd..verb_end], vp.verb)) continue;
        match_start = cmd_at;
        args_start = verb_end;
        break;
    }
    const args_off = args_start orelse return null;

    // Walk space-separated args; flag if any matches a bad pkg.
    var i = args_off;
    while (i < line.len) {
        while (i < line.len and line[i] == ' ') i += 1;
        const tok_start = i;
        while (i < line.len and line[i] != ' ' and line[i] != '\n' and line[i] != '\r') i += 1;
        if (tok_start == i) break;
        const tok = line[tok_start..i];
        // Skip flags. Note: the outer-while's leading-space skipper
        // re-runs on next iter, so `continue` here is fine — it
        // doesn't strand us at the same token.
        if (tok.len > 0 and tok[0] == '-') continue;
        // Strip a trailing `@version` suffix while keeping the
        // leading `@scope/` intact. `@ctrl/tinycolor@1.0.0` →
        // `@ctrl/tinycolor`; bare `event-stream@0.1.0` →
        // `event-stream`; bare scope `@ctrl/tinycolor` →
        // unchanged. Using lastIndexOf catches the version
        // separator (LAST `@`) rather than the leading scope
        // marker (position 0).
        const last_at = std.mem.lastIndexOfScalar(u8, tok, '@');
        const name = if (last_at) |idx| (if (idx == 0) tok else tok[0..idx]) else tok;
        for (flagged_npm_packages) |bad| {
            if (std.mem.eql(u8, name, bad)) return line[match_start.?..i];
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// bash -c "<long-base64>"
//
// Heuristic — looks for the shape `<shell> -c <quoted-arg>` where
// the quoted-arg is long enough AND mostly base64 alphabet. Trusts
// the obvious-only — `bash -c 'foo'` with a short literal goes
// through.

const base64_min_len: usize = 40;
const base64_alphabet_ratio_num: usize = 9; // 90%
const base64_alphabet_ratio_den: usize = 10;

fn isBase64Char(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '+' or c == '/' or c == '=';
}

fn matchBashCBase64(line: []const u8) ?[]const u8 {
    const shells = [_][]const u8{ "bash -c ", "sh -c ", "zsh -c " };
    for (shells) |sh| {
        const at = std.mem.indexOf(u8, line, sh) orelse continue;
        if (at != 0) {
            const prev = line[at - 1];
            if (prev != ' ' and prev != ';' and prev != '&' and prev != '|') continue;
        }
        const after = at + sh.len;
        if (after >= line.len) continue;
        // Look at the quoted arg. Accept ', ", or unquoted.
        var arg_start = after;
        var arg_end = line.len;
        var quote: u8 = 0;
        if (line[after] == '\'' or line[after] == '"') {
            quote = line[after];
            arg_start = after + 1;
            const close = std.mem.indexOfScalarPos(u8, line, arg_start, quote) orelse continue;
            arg_end = close;
        } else {
            // Unquoted — scan to first whitespace.
            var i = after;
            while (i < line.len and line[i] != ' ' and line[i] != '\n' and line[i] != '\r') i += 1;
            arg_end = i;
        }
        const arg = line[arg_start..arg_end];
        if (arg.len < base64_min_len) continue;
        var b64_count: usize = 0;
        for (arg) |c| if (isBase64Char(c)) {
            b64_count += 1;
        };
        // Require >= ratio of base64 alphabet.
        if (b64_count * base64_alphabet_ratio_den >= arg.len * base64_alphabet_ratio_num) {
            return line[at..arg_end];
        }
    }
    return null;
}

test {
    _ = @import("patterns_tests.zig");
}
