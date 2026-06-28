//! attop shell-integration writer — the managed-snippet model behind the
//! wizard's "wire my shell" action (caps.shellIntegrated detects it).
//!
//! A single marker-guarded block in the user's rc exports $ATTY_SOURCE and
//! sources a per-shell init file (the `atty init <shell>` output). The block
//! is the ONLY thing attop owns in the rc: `upsertBlock` rewrites it in place
//! when present and never touches a byte outside the markers, so it's safe to
//! re-run and trivial for the user to remove (delete between the markers).
//!
//! `upsertBlock` is pure (rc string in → new string out) so the
//! idempotency + content-preservation guarantees are unit-tested without
//! touching a real file; the fs layer (confirm → backup → write) lives in
//! the caller.

const std = @import("std");
const caps = @import("caps.zig");

/// Opening marker — shared with caps so detection and writing agree.
pub const begin = caps.rc_marker; // "# >>> atty >>>"
pub const end = "# <<< atty <<<";

/// The managed block: source the per-shell init file via $ATTY_SOURCE. Trailing
/// newline so it sits cleanly whether appended or spliced.
pub fn buildBlock(allocator: std.mem.Allocator, init_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\nexport ATTY_SOURCE=\"{s}\"\n[ -r \"$ATTY_SOURCE\" ] && . \"$ATTY_SOURCE\"\n{s}\n",
        .{ begin, init_path, end },
    );
}

/// The per-shell init file ($ATTY_SOURCE target): re-evaluate atty's shell
/// integration at every shell start. A one-liner rather than a captured
/// `atty init` snapshot so it can't go stale when atty updates, and so attop
/// needn't shell out to capture output. Caller owns the result.
pub fn buildInitFile(allocator: std.mem.Allocator, shell: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "# Managed by attop — re-evaluates atty's shell integration each start.\neval \"$(atty init {s})\"\n",
        .{shell},
    );
}

/// `rc` with the managed block inserted (absent) or rewritten in place
/// (present). Idempotent — applying twice equals applying once — and content
/// outside the markers is preserved byte-for-byte. Caller owns the result.
pub fn upsertBlock(allocator: std.mem.Allocator, rc: []const u8, init_path: []const u8) ![]u8 {
    const block = try buildBlock(allocator, init_path);
    defer allocator.free(block);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (std.mem.indexOf(u8, rc, begin)) |bi| {
        // Replace [start of the begin-marker line .. end of the end-marker
        // line] with the fresh block; keep everything before and after.
        const line_start = if (std.mem.lastIndexOfScalar(u8, rc[0..bi], '\n')) |nl| nl + 1 else 0;
        // Tolerate a corrupted block missing its end marker: splice to EOL of
        // the begin marker so we don't swallow the rest of the file.
        const ei = std.mem.indexOfPos(u8, rc, bi, end) orelse bi;
        const after = if (std.mem.indexOfScalarPos(u8, rc, ei, '\n')) |nl| nl + 1 else rc.len;
        try out.appendSlice(allocator, rc[0..line_start]);
        try out.appendSlice(allocator, block);
        try out.appendSlice(allocator, rc[after..]);
        return out.toOwnedSlice(allocator);
    }

    // Append, with a separating newline if the rc doesn't end in one.
    try out.appendSlice(allocator, rc);
    if (rc.len > 0 and rc[rc.len - 1] != '\n') try out.append(allocator, '\n');
    try out.appendSlice(allocator, block);
    return out.toOwnedSlice(allocator);
}

test {
    _ = @import("rc_writer_tests.zig");
}
