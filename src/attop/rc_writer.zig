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

fn isFish(shell: []const u8) bool {
    return std.mem.eql(u8, shell, "fish");
}

/// The managed block: source the per-shell init file via $ATTY_SOURCE, in the
/// detected shell's syntax (fish has its own export/test/source). Trailing
/// newline so it sits cleanly whether appended or spliced.
pub fn buildBlock(allocator: std.mem.Allocator, init_path: []const u8, shell: []const u8) ![]u8 {
    if (isFish(shell)) {
        return std.fmt.allocPrint(
            allocator,
            "{s}\nset -gx ATTY_SOURCE \"{s}\"\ntest -r \"$ATTY_SOURCE\"; and source \"$ATTY_SOURCE\"\n{s}\n",
            .{ begin, init_path, end },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}\nexport ATTY_SOURCE=\"{s}\"\n[ -r \"$ATTY_SOURCE\" ] && . \"$ATTY_SOURCE\"\n{s}\n",
        .{ begin, init_path, end },
    );
}

/// The per-shell init file ($ATTY_SOURCE target): re-evaluate atty's shell
/// integration at every shell start, in the shell's own syntax (fish pipes to
/// `source`; posix shells `eval`). A one-liner rather than a captured snapshot
/// so it can't go stale when atty updates, and so attop needn't shell out.
pub fn buildInitFile(allocator: std.mem.Allocator, shell: []const u8) ![]u8 {
    const head = "# Managed by attop — re-evaluates atty's shell integration each start.\n";
    if (isFish(shell)) {
        return std.fmt.allocPrint(allocator, "{s}atty init fish | source\n", .{head});
    }
    return std.fmt.allocPrint(allocator, "{s}eval \"$(atty init {s})\"\n", .{ head, shell });
}

/// `rc` with the managed block inserted (absent) or rewritten in place
/// (present). Idempotent — applying twice equals applying once — and content
/// outside the markers is preserved byte-for-byte. Caller owns the result.
pub fn upsertBlock(allocator: std.mem.Allocator, rc: []const u8, init_path: []const u8, shell: []const u8) ![]u8 {
    const block = try buildBlock(allocator, init_path, shell);
    defer allocator.free(block);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Only a LINE-ANCHORED begin marker is ours (the writer always emits at
    // col 0); a marker mid-line is user content — don't rewrite from there or
    // we'd swallow the text before it.
    if (findLineAnchored(rc, begin)) |bi| {
        // Replace [the begin-marker line .. the end-marker line] with the
        // fresh block; keep everything before and after.
        // Tolerate a corrupted block missing its end marker: splice to EOL of
        // the begin marker so we don't swallow the rest of the file.
        const ei = std.mem.indexOfPos(u8, rc, bi, end) orelse bi;
        const after = if (std.mem.indexOfScalarPos(u8, rc, ei, '\n')) |nl| nl + 1 else rc.len;
        try out.appendSlice(allocator, rc[0..bi]);
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

/// Index of `needle` only where it starts a line (col 0 or right after a
/// newline) — so a marker pasted mid-line isn't mistaken for our block.
fn findLineAnchored(hay: []const u8, needle: []const u8) ?usize {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, needle)) |pos| {
        if (pos == 0 or hay[pos - 1] == '\n') return pos;
        i = pos + 1;
    }
    return null;
}

test {
    _ = @import("rc_writer_tests.zig");
}
