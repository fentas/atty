//! URL-token detection for mouse_urls.
//!
//! Given a captured terminal line + a click column, find the URL whose
//! run covers that column. Stateless and allocation-free; returns
//! slices into the input.
//!
//! Detection rule: a URL run starts at a scheme prefix (one of the
//! whitelisted schemes followed by `://`) and extends until the first
//! URL-unsafe byte. Bracket-balancing peels matched wrappers (parens
//! around a URL in prose, angle brackets in mailto-style citations).
//!
//! Schemes are an explicit allow-list to avoid lighting up exotic
//! `app+scheme://` patterns we don't have a sane handler for.
//!
//! The host (between `://` and the next `/`, `?`, `#`, or end) is
//! returned alongside the full URL — callers use the host for trust
//! lookups without re-parsing.

const std = @import("std");

pub const Hit = struct {
    /// Full URL text with wrappers and trailing punctuation stripped.
    url: []const u8,
    /// Host portion (no scheme, no path). May contain a trailing
    /// `:port` because the trust store is host:port indexed.
    host: []const u8,
    /// Lowercase scheme (`https`, `http`, …).
    scheme: []const u8,
};

pub const Options = struct {
    /// Which schemes are clickable. Order doesn't matter; matching is
    /// case-insensitive against the lowercased scheme.
    accept_schemes: []const []const u8 = &.{
        "https", "http", "ftp", "ftps", "ssh", "file", "git", "mailto",
    },
};

/// Find a URL in `line` whose run covers `click_col` (1-based).
pub fn find(line: []const u8, click_col: u16, opts: Options) ?Hit {
    if (click_col == 0 or line.len == 0) return null;
    const click_idx_raw: usize = @as(usize, click_col) - 1;
    if (click_idx_raw >= line.len) return null;

    // Find every scheme prefix in the line and pick the run that
    // covers the click. Multiple URLs on one line are common
    // (markdown link footers, `see X and Y`).
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const start = findSchemeStart(line, i, opts) orelse return null;
        const run_end = scanUrlEnd(line, start.body_start);
        if (start.scheme_start <= click_idx_raw and click_idx_raw < run_end) {
            const trimmed_end = stripTrailingPunct(line, start.scheme_start, run_end);
            if (trimmed_end <= start.body_start) return null;
            const full = line[start.scheme_start..trimmed_end];
            const host = extractHost(line[start.body_start..trimmed_end]);
            if (host.len == 0) return null;
            return .{
                .url = full,
                .host = host,
                .scheme = line[start.scheme_start .. start.scheme_start + start.scheme_len],
            };
        }
        i = run_end;
    }
    return null;
}

const SchemeMatch = struct {
    scheme_start: usize,
    scheme_len: usize,
    body_start: usize,
};

fn findSchemeStart(line: []const u8, from: usize, opts: Options) ?SchemeMatch {
    var i: usize = from;
    while (i < line.len) : (i += 1) {
        // `://` must be present after some scheme bytes
        const colon = std.mem.indexOfPos(u8, line, i, "://") orelse return null;
        if (colon <= i) return null;
        const scheme_start = schemeStartBefore(line, colon);
        if (scheme_start >= colon) {
            // No ASCII letters before `://` — skip and try after.
            i = colon + 3;
            continue;
        }
        const scheme = line[scheme_start..colon];
        if (!isAcceptedScheme(scheme, opts)) {
            i = colon + 3;
            continue;
        }
        return .{
            .scheme_start = scheme_start,
            .scheme_len = scheme.len,
            .body_start = colon + 3,
        };
    }
    return null;
}

fn schemeStartBefore(line: []const u8, colon: usize) usize {
    var s: usize = colon;
    while (s > 0) {
        const c = line[s - 1];
        if (!isSchemeChar(c)) break;
        s -= 1;
    }
    return s;
}

fn isSchemeChar(c: u8) bool {
    // Per RFC 3986 §3.1: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
    if (std.ascii.isAlphabetic(c)) return true;
    if (std.ascii.isDigit(c)) return true;
    return c == '+' or c == '-' or c == '.';
}

fn isAcceptedScheme(scheme: []const u8, opts: Options) bool {
    for (opts.accept_schemes) |s| {
        if (std.ascii.eqlIgnoreCase(scheme, s)) return true;
    }
    return false;
}

fn scanUrlEnd(line: []const u8, from: usize) usize {
    var i: usize = from;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (isUrlTerminator(c)) break;
    }
    return i;
}

fn isUrlTerminator(c: u8) bool {
    // RFC 3986 unreserved + reserved characters are allowed inside a
    // URL token. The set here is the COMPLEMENT — anything that
    // can't appear unescaped in a URL OR that would obviously be
    // prose-attached punctuation.
    return c <= 0x20 // controls + SP
    or c == 0x7f // DEL
    or c == '"' or c == '<' or c == '>' or c == '`' or c == '^' or c == '{' or c == '}' or c == '|' or c == '\\';
}

fn stripTrailingPunct(line: []const u8, start: usize, end: usize) usize {
    var e: usize = end;
    while (e > start) {
        const c = line[e - 1];
        switch (c) {
            ',', '.', ';', ':', '!', '?' => e -= 1,
            ')', ']', '}' => {
                const open: u8 = switch (c) {
                    ')' => '(',
                    ']' => '[',
                    '}' => '{',
                    else => unreachable,
                };
                if (countByte(line[start..e], c) > countByte(line[start..e], open)) {
                    e -= 1;
                } else break;
            },
            else => break,
        }
    }
    return e;
}

fn countByte(buf: []const u8, b: u8) usize {
    var n: usize = 0;
    for (buf) |c| {
        if (c == b) n += 1;
    }
    return n;
}

fn extractHost(body: []const u8) []const u8 {
    var end: usize = 0;
    while (end < body.len) : (end += 1) {
        const c = body[end];
        if (c == '/' or c == '?' or c == '#') break;
    }
    // Strip user-info (`user:pass@host`).
    if (std.mem.lastIndexOfScalar(u8, body[0..end], '@')) |at| {
        return body[at + 1 .. end];
    }
    return body[0..end];
}

test {
    _ = @import("detect_tests.zig");
}
