//! attop runtime capability detection — what the dashboard can see about the
//! host (attop is a separate binary talking to the daemon over the UDS, so
//! this is system state, not atty's compiled config). Drives the wizard
//! landing + capability-gated screens: don't show what isn't there, guide
//! the user to install/enable it instead.

const std = @import("std");

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
const X_OK: c_int = 1;
const O_RDONLY: c_int = 0;

/// The guard marker the wizard's managed rc block is wrapped in (see the
/// ATTY_SOURCE design); its presence means the shell is wired to atty.
pub const rc_marker = "# >>> atty >>>";

/// Is the `atty` binary installed + executable on $PATH? (The wizard guides
/// installation when not.)
pub fn attyOnPath() bool {
    const path = std.c.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, std.mem.span(path), ':');
    var buf: [4096]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        // "<dir>/atty\0"; skip a dir whose path won't fit the buffer.
        const candidate = std.fmt.bufPrintZ(&buf, "{s}/atty", .{dir}) catch continue;
        if (access(candidate.ptr, X_OK) == 0) return true;
    }
    return false;
}

/// Running inside an atty session? (atty exports $ATTY into the child shell.)
pub fn underAtty() bool {
    return std.c.getenv("ATTY") != null;
}

/// Integration signatures scanned for in the rc: the managed-snippet marker
/// (3b), plus the two integrations users wire by hand today — `atty init`
/// (the eval/OSC-133 line) and `exec atty` (the wrap guard from the README).
/// Any one means the shell is wired, so detection is accurate before the
/// managed writer exists.
const rc_signatures = [_][]const u8{ rc_marker, "atty init", "exec atty" };

/// Is the shell wired to atty? True when $ATTY_SOURCE is exported (the managed
/// snippet was sourced) or the detected shell's rc carries any integration
/// signature. Read-only + best-effort: an unreadable/absent rc reads as false.
pub fn shellIntegrated() bool {
    if (std.c.getenv("ATTY_SOURCE") != null) return true;
    var buf: [4096]u8 = undefined;
    const rc = rcPath(&buf) orelse return false;
    return rcHasIntegration(rc);
}

/// The login shell's short name (bash/zsh/fish) from $SHELL; bash by default.
/// Drives both the rc path and the `atty init <shell>` fix shown on Setup.
pub fn shellName() []const u8 {
    const shell = if (std.c.getenv("SHELL")) |s| std.mem.span(s) else "";
    if (std.mem.endsWith(u8, shell, "zsh")) return "zsh";
    if (std.mem.endsWith(u8, shell, "fish")) return "fish";
    return "bash";
}

/// The login shell's rc path, derived from $SHELL + $HOME (bash/default →
/// ~/.bashrc, zsh → ~/.zshrc, fish → ~/.config/fish/config.fish). The common
/// interactive rc — login-only files (~/.bash_profile, ~/.zprofile) read as
/// unwired, which the $ATTY_SOURCE short-circuit covers when run under atty.
pub fn rcPath(buf: []u8) ?[:0]const u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    const name = shellName();
    const rel = if (std.mem.eql(u8, name, "zsh"))
        "/.zshrc"
    else if (std.mem.eql(u8, name, "fish"))
        "/.config/fish/config.fish"
    else
        "/.bashrc";
    return std.fmt.bufPrintZ(buf, "{s}{s}", .{ home, rel }) catch null;
}

/// Does the rc file contain any integration signature? Bounded read
/// (≤64 KiB), libc so no io threading; any open/read failure → false.
fn rcHasIntegration(path: [:0]const u8) bool {
    const fd = open(path.ptr, O_RDONLY);
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    var buf: [65536]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        // posix.read retries EINTR internally — attop installs a SIGWINCH
        // handler, and a raw read() interrupted by a resize would truncate the
        // scan into a false "not wired". A real error → best-effort: scan what
        // we have.
        const n = std.posix.read(fd, buf[len..]) catch break;
        if (n == 0) break; // EOF
        len += n;
    }
    const hay = buf[0..len];
    for (rc_signatures) |sig| {
        if (std.mem.indexOf(u8, hay, sig) != null) return true;
    }
    return false;
}

test {
    _ = @import("caps_tests.zig");
}
