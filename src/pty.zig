//! PTY (pseudo-terminal) allocation, child spawning, and window-size sync.
//!
//! `atty` is a proxy: stdin/stdout connect us to the user's terminal
//! emulator (e.g. Ghostty) and the PTY master/slave pair connects us
//! to the child shell. Conceptually:
//!
//!     user keyboard --> stdin --> [proxy + interceptors] --> master
//!                                                              |
//!                                                              v
//!                                                            slave  (== shell's stdin/stdout/stderr)
//!     user screen   <-- stdout <-- [proxy + interceptors] <-- master
//!
//! We deliberately use the low-level POSIX dance (posix_openpt + grantpt
//! + unlockpt + ptsname) rather than `openpty(3)`/`forkpty(3)` from
//! libutil. That keeps the link-time surface small (libc only) and makes
//! the lifecycle explicit: we own both ends of the PTY and we know
//! exactly when each fd is open.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

// ----- libc bindings -------------------------------------------------------
//
// `std.c` does not surface all of these in a stable, portable form, so
// we declare them explicitly. They are part of POSIX.1-2001 (XSI), so
// the signatures are stable across glibc/musl.

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn fork() c_int;
extern "c" fn setsid() c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn getpid() c_int;

const version = @import("version.zig").version;

// posix_openpt() takes a raw int (C ABI). On Linux: O_RDWR (0o2) | O_NOCTTY (0o400).
const O_RDWR_NOCTTY_RAW: c_int = 0o2 | 0o400;

// For std.c.open() Zig wants the packed std.c.O struct. This is the same
// flag set, expressed structurally.
const open_flags: std.c.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };

// ioctl numbers — see <asm-generic/ioctls.h>. We deliberately hardcode them
// (rather than @cImport) so the file stays small and obvious.
pub const TIOCSCTTY: u32 = 0x540E;
pub const TIOCGWINSZ: u32 = 0x5413;
pub const TIOCSWINSZ: u32 = 0x5414;

pub const Error = error{
    OpenPtFailed,
    GrantPtFailed,
    UnlockPtFailed,
    PtsnameFailed,
    OpenSlaveFailed,
    SetCtrlTtyFailed,
    ForkFailed,
    ExecFailed,
    IoctlFailed,
} || std.mem.Allocator.Error;

pub const WinSize = extern struct {
    rows: u16,
    cols: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,

    pub fn fromLinux(ws: posix.winsize) WinSize {
        return .{
            .rows = ws.row,
            .cols = ws.col,
            .xpixel = ws.xpixel,
            .ypixel = ws.ypixel,
        };
    }
};

pub const Pty = struct {
    master: posix.fd_t,
    slave_path: [:0]u8,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator) Error!Pty {
        const master = posix_openpt(O_RDWR_NOCTTY_RAW);
        if (master < 0) return Error.OpenPtFailed;
        errdefer _ = std.c.close(master);

        if (grantpt(master) != 0) return Error.GrantPtFailed;
        if (unlockpt(master) != 0) return Error.UnlockPtFailed;

        const name_ptr = ptsname(master) orelse return Error.PtsnameFailed;
        const name_slice = std.mem.sliceTo(name_ptr, 0);
        const owned = try allocator.dupeZ(u8, name_slice);

        return .{
            .master = master,
            .slave_path = owned,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pty) void {
        _ = std.c.close(self.master);
        self.allocator.free(self.slave_path);
        self.* = undefined;
    }

    pub fn setSize(self: Pty, size: WinSize) Error!void {
        const ws = posix.winsize{
            .row = size.rows,
            .col = size.cols,
            .xpixel = size.xpixel,
            .ypixel = size.ypixel,
        };
        const rc = linux.ioctl(self.master, TIOCSWINSZ, @intFromPtr(&ws));
        if (@as(isize, @bitCast(rc)) < 0) return Error.IoctlFailed;
    }

    /// Read window size from a TTY (typically our own stdout). Used at
    /// startup and on each SIGWINCH to keep the child in sync.
    pub fn querySize(fd: posix.fd_t) Error!WinSize {
        var ws: posix.winsize = undefined;
        const rc = linux.ioctl(fd, TIOCGWINSZ, @intFromPtr(&ws));
        if (@as(isize, @bitCast(rc)) < 0) return Error.IoctlFailed;
        return WinSize.fromLinux(ws);
    }

    /// Spawn `argv` (typically a shell) attached to the slave end of this
    /// PTY. Returns the child PID; in the parent we keep `self.master` and
    /// the slave fd was only briefly held by the child.
    ///
    /// argv must be a sentinel-terminated array of null-terminated strings
    /// (`[*:null]const ?[*:0]const u8`), the standard execve shape.
    pub fn spawn(
        self: Pty,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) Error!posix.pid_t {
        // Capture our own pid so the child can advertise it as ATTY_PID.
        // getpid() inside the child would return the child's pid (atty
        // is the parent), so we read it here and pass it down.
        const atty_pid = getpid();

        const pid = fork();
        if (pid < 0) return Error.ForkFailed;
        if (pid == 0) {
            // ---- Child ------------------------------------------------------
            //
            // The child must become a new session leader and acquire the slave
            // as its controlling terminal, otherwise programs like `vim`,
            // signal handling (Ctrl-C → SIGINT), and job control will not
            // behave correctly.
            // We can't `return` an error from a forked child — abort with
            // a distinctive exit code so the parent's waitpid can tell
            // why we died.
            childSetup(self.master, self.slave_path) catch std.c._exit(127);

            // execve(2) preserves SIG_IGN across exec, so the parent's
            // SIGPIPE → SIG_IGN disposition would leak into the user's
            // shell and break `yes | head` / `curl | less` / any
            // pipeline whose writer expects to die on EPIPE. Restore
            // default before exec so the shell starts with a vanilla
            // signal mask.
            const dfl = posix.Sigaction{
                .handler = .{ .handler = posix.SIG.DFL },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(posix.SIG.PIPE, &dfl, null);

            // Inject the ATTY env markers so shell rc files can detect
            // "running inside atty" and skip wrapping themselves again.
            injectAttyEnv(atty_pid);

            // execvp returns only on failure.
            _ = execvp(argv[0].?, argv);
            std.c._exit(127);
        }
        _ = envp; // reserved for future use (custom env); execvp inherits ours
        return pid;
    }
};

/// Inject ATTY / ATTY_PID / ATTY_VERSION into the child's environment.
/// Best-effort — failures are silent because we're past the fork point
/// and the shell can survive without these.
fn injectAttyEnv(atty_pid: c_int) void {
    _ = setenv("ATTY", "1", 1);

    var pid_buf: [24]u8 = undefined;
    if (std.fmt.bufPrintZ(&pid_buf, "{d}", .{atty_pid})) |s| {
        _ = setenv("ATTY_PID", s.ptr, 1);
    } else |_| {}

    var ver_buf: [32]u8 = undefined;
    if (std.fmt.bufPrintZ(&ver_buf, "{s}", .{version})) |s| {
        _ = setenv("ATTY_VERSION", s.ptr, 1);
    } else |_| {}
}

fn childSetup(master_fd: posix.fd_t, slave_path: [:0]const u8) !void {
    // Detach from the current controlling TTY (the user's real terminal)
    // and become a new session leader.
    if (setsid() == -1) return Error.SetCtrlTtyFailed;

    // Open the slave end. We must do this *after* setsid() so that the
    // open call associates the new session with this PTY.
    const slave_fd = std.c.open(slave_path.ptr, open_flags, @as(std.c.mode_t, 0));
    if (slave_fd < 0) return Error.OpenSlaveFailed;

    // Make the slave our controlling terminal. Without this, the kernel
    // won't deliver SIGINT/SIGTSTP etc. to the foreground process group.
    const rc = linux.ioctl(slave_fd, TIOCSCTTY, 0);
    if (@as(isize, @bitCast(rc)) < 0) return Error.SetCtrlTtyFailed;

    // Wire the slave to stdin/stdout/stderr of the child. dup2 closes the
    // target fd if it was open, which is what we want.
    if (std.c.dup2(slave_fd, 0) < 0) return Error.OpenSlaveFailed;
    if (std.c.dup2(slave_fd, 1) < 0) return Error.OpenSlaveFailed;
    if (std.c.dup2(slave_fd, 2) < 0) return Error.OpenSlaveFailed;

    if (slave_fd > 2) _ = std.c.close(slave_fd);
    _ = std.c.close(master_fd);
}

test "Pty.open allocates a master and slave path" {
    var pty = try Pty.open(std.testing.allocator);
    defer pty.deinit();

    try std.testing.expect(pty.master >= 0);
    try std.testing.expect(std.mem.startsWith(u8, pty.slave_path, "/dev/pts/"));
}

test "Pty.setSize round-trips through ioctl" {
    var pty = try Pty.open(std.testing.allocator);
    defer pty.deinit();

    try pty.setSize(.{ .rows = 24, .cols = 80 });
    const got = try Pty.querySize(pty.master);
    try std.testing.expectEqual(@as(u16, 24), got.rows);
    try std.testing.expectEqual(@as(u16, 80), got.cols);
}
