//! Subprocess-context tracker — what's running between OSC 133 `;C` and `;D`.
//!
//! Local atty sees every keystroke in the local PTY, including those
//! sent to subprocesses (ssh, sudo, kubectl exec, docker exec, …) and
//! interactive apps (vim, less, psql, …). PR #15 added a blanket-drop
//! for `dispatchLineCommit` while in a subprocess so the user's local
//! atuin index doesn't get polluted with every Enter inside vim.
//!
//! But blanket-drop also discards commands typed at *remote shell
//! prompts*, which is a real loss — the cleanest way to search "what
//! did I run on prod-bastion last week" is to type `<query>` in atuin
//! Ctrl+R if those commands were recorded with the remote target
//! attached. This tracker takes the next step:
//!
//!   1. Sniff each line committed at the LOCAL prompt before `;C`.
//!   2. If the first token is a known shell-launcher (`ssh`, `mosh`,
//!      `kubectl exec`, `docker exec`, `sudo bash`, `su`, …), resolve
//!      the target (host / pod / container / …) and push a
//!      `Context` onto the stack.
//!   3. Subsequent committed lines (typed by the user at the remote
//!      prompt, captured by atty's local keystroke tracking) are
//!      tagged with the top-of-stack `Context` so atuin / history
//!      can attribute them properly. Encoding goes through the
//!      modules' `--cwd` parameter as `ssh://user@host/<remote-cwd>`
//!      or `k8s://<context>/<ns>/<pod>` etc. — atuin's `--cwd` is a
//!      free-form string, so [DIRECTORY] mode on Ctrl+R naturally
//!      scopes per target.
//!   4. On `;D` we pop. Nested ssh chains (local → server1 → server2)
//!      naturally produce a stack of depth 2.
//!
//! The unknown-app blanket drop from PR #15 still applies — anything
//! that ISN'T a recognized shell launcher continues to suppress its
//! typed lines (vim, less, psql, mysql, nano, …).
//!
//! `Tracker` is fixed-size — no allocations in the hot path. Stack
//! depth caps at 8 (deeper ssh chains than that are operator error;
//! we just refuse to grow rather than allocating).

const std = @import("std");

/// What kind of subprocess we detected at the last `;C` transition.
/// `none` means the line was a regular command (vim, less, ls, …) —
/// we won't record commits typed inside it.
pub const Kind = enum {
    none,
    /// `ssh` or `mosh` to a remote host.
    ssh,
    /// `kubectl exec -it pod -- bash` and friends.
    kubectl_exec,
    /// `docker exec -it container bash`, `podman exec`, `nerdctl exec`.
    docker_exec,
    /// `lxc exec`, `incus exec`.
    container_exec,
    /// `sudo bash`, `sudo -s`, `sudo -i`, `doas <shell>`. Stays on the
    /// LOCAL host but the privilege boundary is recorded so the user
    /// can filter "what did I do as root last week".
    elevation,
    /// `su -`, `su username`. Same as `elevation` from a recording POV.
    su,
};

/// One frame on the subprocess stack. Fixed-size buffers — the
/// `name_buf` / `cwd_buf` storage is owned by the frame and copied
/// from `ssh -G` output or OSC 7 capture.
pub const Frame = struct {
    kind: Kind = .none,
    /// Total bytes used in `name_buf`. The semantic of `name_buf`
    /// depends on `kind`:
    ///   .ssh           → "user@host" (or just "host" when no user)
    ///   .kubectl_exec  → "<context>/<ns>/<pod>"
    ///   .docker_exec   → "<container>"
    ///   .container_exec → "<container>"
    ///   .elevation     → "sudo" or "doas"
    ///   .su            → "su:<user>" or "su"
    ///   .none          → empty
    name_len: usize = 0,
    name_buf: [256]u8 = undefined,

    /// Remote cwd if known (captured via OSC 7 from the remote
    /// shell's integration). Empty until / unless OSC 7 fires.
    cwd_len: usize = 0,
    cwd_buf: [512]u8 = undefined,

    pub fn name(self: *const Frame) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn cwd(self: *const Frame) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }

    fn setName(self: *Frame, s: []const u8) void {
        const n = @min(s.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], s[0..n]);
        self.name_len = n;
    }
    fn setCwd(self: *Frame, s: []const u8) void {
        const n = @min(s.len, self.cwd_buf.len);
        @memcpy(self.cwd_buf[0..n], s[0..n]);
        self.cwd_len = n;
    }
};

/// Encoding for the `--cwd` we hand to atuin / pass to history.
/// Free-form strings — atuin treats `--cwd` as a label, so we can
/// shove whatever URI-ish scheme we want here.
///
///   ssh://user@host/<remote-cwd>
///   k8s://<context>/<ns>/<pod>/<remote-cwd>
///   docker://<container>/<remote-cwd>
///   container://<name>/<remote-cwd>
///   sudo:<local-cwd>
///   su:<user>:<local-cwd>
///
/// The `local-cwd` for elevation/su variants comes from the *real*
/// shell cwd (we'd grab it via /proc/<child_pid>/cwd elsewhere; for
/// MVP we leave it as `?` and let users see "sudo:?" in Ctrl+R).
pub fn formatCwd(
    frame: *const Frame,
    out: []u8,
    fallback_local_cwd: []const u8,
) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    // Strip the leading `/` from the remote path before composing the
    // URI — OSC 7 reports absolute paths, and naively concatenating
    // `ssh://host/` + `/home/foo` produces the double-slashed
    // `ssh://host//home/foo`. With this normalisation we get the
    // documented `ssh://host/home/foo` shape, which is also what
    // atuin's `[ DIRECTORY ]` filter groups by.
    const rcwd_raw: []const u8 = if (frame.cwd_len > 0) frame.cwd() else "?";
    // Strip any leading `/`. The previous `len > 1` form left a bare
    // `/` cwd untouched, producing `ssh://host//` for sessions
    // currently at root — common enough on minimal containers /
    // service images. With `len >= 1` the `/` becomes empty and the
    // URI lands as `ssh://host/`, which is what atuin's
    // `[ DIRECTORY ]` group key wants.
    const rcwd: []const u8 = if (rcwd_raw.len >= 1 and rcwd_raw[0] == '/')
        rcwd_raw[1..]
    else
        rcwd_raw;
    // Elevation/su frames format `<name>:<local-cwd>` — when the
    // caller didn't pass a local cwd we substitute `?` so the
    // recorded entry doesn't end with a dangling colon (`sudo:`,
    // `su:postgres:`). The placeholder makes it visible in atuin's
    // Ctrl+R that we elevated but didn't capture a path.
    const elev_cwd: []const u8 = if (fallback_local_cwd.len > 0) fallback_local_cwd else "?";
    switch (frame.kind) {
        .none => {
            w.writeAll(fallback_local_cwd) catch {};
        },
        .ssh => {
            w.print("ssh://{s}/{s}", .{ frame.name(), rcwd }) catch {};
        },
        .kubectl_exec => {
            w.print("k8s://{s}/{s}", .{ frame.name(), rcwd }) catch {};
        },
        .docker_exec => {
            w.print("docker://{s}/{s}", .{ frame.name(), rcwd }) catch {};
        },
        .container_exec => {
            w.print("container://{s}/{s}", .{ frame.name(), rcwd }) catch {};
        },
        .elevation => {
            w.print("{s}:{s}", .{ frame.name(), elev_cwd }) catch {};
        },
        .su => {
            w.print("{s}:{s}", .{ frame.name(), elev_cwd }) catch {};
        },
    }
    return out[0..w.end];
}

/// Maximum stack depth. Deeper nesting than this is operator error
/// (and atty refuses to grow rather than allocating); the top frame
/// just stays pinned as long as additional `;C` markers arrive.
pub const max_depth = 8;

/// Tracker — owns the stack. Methods are called from the proxy at
/// `;C` / `;D` transitions, and `current()` is consulted when
/// `dispatchLineCommit` fires.
///
/// Zero allocations after `init`; all state is inline.
pub const Tracker = struct {
    frames: [max_depth]Frame = [_]Frame{.{}} ** max_depth,
    depth: usize = 0,
    /// Pushes beyond `max_depth` increment this counter instead of
    /// touching the frame array. `;D` pops consume the overflow
    /// before unwinding real frames, preserving the
    /// `depth(;C) == depth(;D) + 1` invariant after saturation
    /// (otherwise we'd unwind the pinned-deep stack too early once
    /// the user dropped back below the saturation point).
    overflow: usize = 0,

    /// Path to `ssh` binary used for `-G` resolution. Configurable
    /// because some setups (NixOS, Guix, custom containers) put ssh
    /// outside `$PATH` or want a particular wrapper.
    ssh_binary: []const u8 = "ssh",

    /// When false, the parser still detects launchers but `ssh -G`
    /// is skipped — host is taken straight from the typed command
    /// (`ssh foo@bar.example.com` → `foo@bar.example.com`). Loses
    /// ssh_config alias resolution but doesn't fork+exec on every
    /// `ssh` invocation; useful when ssh is slow or absent.
    use_ssh_g: bool = true,

    pub fn init() Tracker {
        return .{};
    }

    /// Top frame's kind. `.none` when stack is empty.
    pub fn currentKind(self: *const Tracker) Kind {
        if (self.depth == 0) return .none;
        return self.frames[self.depth - 1].kind;
    }

    /// Borrow of the top frame. Null when stack is empty.
    /// Reflects the IMMEDIATE state of the stack including any
    /// `.none` frames pushed for unrecognised commands running
    /// inside a recognised subprocess. Use this when correctness
    /// depends on "what command is currently running"; use
    /// `currentRecognized()` when correctness depends on the
    /// ambient context (e.g. statusbar segment display).
    pub fn current(self: *const Tracker) ?*const Frame {
        if (self.depth == 0) return null;
        return &self.frames[self.depth - 1];
    }

    /// Borrow of the topmost frame whose `kind` is **not** `.none`,
    /// skipping `.none` frames pushed for unrecognised commands
    /// running INSIDE a recognised subprocess.
    ///
    /// Why it matters: when the user is inside `ssh remote` and runs
    /// `ls`, the stack briefly becomes `[ssh:remote, .none(ls)]`
    /// between `ls`'s `;C` and `;D`. `current()` returns the `.none`
    /// frame; for statusbar display, that would make the
    /// `→ ssh:remote` segment vanish for the duration of `ls`,
    /// reappearing only when the next prompt fires — visible flicker.
    /// `currentRecognized()` walks down past `.none` frames and
    /// returns the ssh frame, so the segment stays stable across
    /// the whole ssh session.
    pub fn currentRecognized(self: *const Tracker) ?*const Frame {
        var i: usize = self.depth;
        while (i > 0) {
            i -= 1;
            if (self.frames[i].kind != .none) return &self.frames[i];
        }
        return null;
    }

    /// Pop on `;D`. Idempotent on an empty stack. When we previously
    /// saturated (overflow > 0) the pop consumes overflow first so
    /// the real stack stays pinned at max_depth until the user has
    /// returned below the saturation point.
    pub fn onCommandEnd(self: *Tracker) void {
        if (self.overflow > 0) {
            self.overflow -= 1;
            return;
        }
        if (self.depth == 0) return;
        self.depth -= 1;
        // Reset the popped frame so a stale name doesn't leak via
        // currentKind/current after over-pop.
        self.frames[self.depth] = .{};
    }

    /// Push on `;C`. Parses `committed_line` to decide what kind of
    /// frame to push. Lines that aren't recognized launchers get a
    /// `.none` frame so `;D` arrives + pops correctly — keeping the
    /// stack invariant `depth(;C) == depth(;D) + 1`.
    ///
    /// `gpa` + `io` are only used when `kind == .ssh` and
    /// `use_ssh_g` is true — to spawn `ssh -G <args>`. Pass
    /// `null` for `io` to force the regex fallback even when
    /// `use_ssh_g` is configured on.
    pub fn onCommandStart(
        self: *Tracker,
        committed_line: []const u8,
        gpa: std.mem.Allocator,
        io: ?std.Io,
    ) void {
        // Saturation: increment overflow so the matching ;D pops it
        // instead of unwinding a real frame. Top context stays pinned.
        if (self.depth >= max_depth) {
            self.overflow += 1;
            return;
        }
        const frame = &self.frames[self.depth];
        frame.* = .{};
        self.depth += 1;

        parseInto(frame, committed_line, self.ssh_binary, self.use_ssh_g, gpa, io);
    }

    /// Capture an OSC 7 cwd report into the current top frame.
    /// Accepts either form:
    ///   - A `file://<host>/<path>` URI (raw OSC 7 payload)
    ///   - A bare absolute path (what `Osc7.takeCwd()` returns after
    ///     it pre-strips the `file://<host>` prefix for us)
    /// No-op when stack is empty or the input has no extractable path.
    pub fn onRemoteCwd(self: *Tracker, cwd_or_uri: []const u8) void {
        if (self.depth == 0) return;
        const path: []const u8 = if (std.mem.startsWith(u8, cwd_or_uri, "file://")) blk: {
            const after_scheme = cwd_or_uri["file://".len..];
            const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return;
            break :blk after_scheme[slash..];
        } else cwd_or_uri;
        if (path.len == 0) return;
        self.frames[self.depth - 1].setCwd(path);
    }
};

// ===========================================================================
// Parsers
// ===========================================================================

/// Inspect `line` and populate `out` with the best-effort
/// classification. Falls back to `kind=.none` for unrecognized
/// commands.
fn parseInto(
    out: *Frame,
    line: []const u8,
    ssh_binary: []const u8,
    use_ssh_g: bool,
    gpa: std.mem.Allocator,
    io: ?std.Io,
) void {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return;

    // Split off the first token. Quoted commands aren't expanded — we
    // just look at the first whitespace-delimited word. atty sees the
    // literal first token the user typed at the prompt; shell aliases
    // are expanded by the shell at EXECUTION time, AFTER atty has
    // already committed the line, so `alias k=kubectl` + typing
    // `k exec pod` reaches us as `k exec pod` (NOT `kubectl exec`).
    // That's why both `kubectl` and the common shorthand aliases
    // (`k`, `kubecolor`) are listed below. Users with custom aliases
    // fork the project and extend the registry — atty is Suckless-
    // style, no runtime alias config.
    const space = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const head = trimmed[0..space];
    const rest = if (space < trimmed.len) std.mem.trim(u8, trimmed[space..], " \t") else "";

    // ── ssh / mosh ──────────────────────────────────────────────────
    if (std.mem.eql(u8, head, "ssh") or std.mem.eql(u8, head, "mosh")) {
        // Quick reject one-shot invocations like `ssh host cmd`. They
        // run a single command and exit; no remote shell to type at.
        // Heuristic: if there's a non-flag positional argument AFTER
        // the host token (taking flag values into account), it's a
        // one-shot. The check is best-effort — false negatives just
        // mean we push a context that pops immediately at the
        // matching `;D`, no functional harm.
        if (looksLikeOneShotSshLine(rest)) return;

        out.kind = .ssh;
        const target = extractSshTarget(rest) orelse "?";
        // Run `ssh -G <args>` to resolve aliases / Match blocks if
        // configured, then re-extract.
        if (use_ssh_g and io != null and head[0] == 's') {
            if (resolveViaSshG(gpa, io.?, ssh_binary, rest)) |resolved| {
                defer gpa.free(resolved);
                out.setName(resolved);
                return;
            } else |_| {}
        }
        out.setName(target);
        return;
    }

    // ── sudo ────────────────────────────────────────────────────────
    if (std.mem.eql(u8, head, "sudo") or std.mem.eql(u8, head, "doas")) {
        if (looksLikeSudoShell(rest)) {
            out.kind = .elevation;
            out.setName(head);
        }
        // sudo <cmd> for a non-shell stays `.none` — typing inside
        // `sudo cat`, `sudo make`, `sudo systemctl status …` isn't
        // shell input.
        return;
    }

    // ── su ──────────────────────────────────────────────────────────
    if (std.mem.eql(u8, head, "su")) {
        out.kind = .su;
        // `su` (current user's login shell), `su -`, `su username`,
        // `su - username`. We just grab the last non-flag argument
        // as the target user (or empty).
        const target_user = lastNonFlagToken(rest) orelse "";
        var buf: [128]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "su:{s}", .{target_user}) catch "su";
        out.setName(formatted);
        return;
    }

    // ── kubectl exec ────────────────────────────────────────────────
    if (std.mem.eql(u8, head, "kubectl") or std.mem.eql(u8, head, "kubecolor") or std.mem.eql(u8, head, "k")) {
        if (parseKubectlExec(rest)) |target| {
            out.kind = .kubectl_exec;
            out.setName(target);
        }
        return;
    }

    // ── docker / podman / nerdctl exec ──────────────────────────────
    if (std.mem.eql(u8, head, "docker") or std.mem.eql(u8, head, "podman") or std.mem.eql(u8, head, "nerdctl")) {
        if (parseDockerExec(rest)) |target| {
            out.kind = .docker_exec;
            out.setName(target);
        }
        return;
    }

    // ── lxc / incus exec ────────────────────────────────────────────
    if (std.mem.eql(u8, head, "lxc") or std.mem.eql(u8, head, "incus")) {
        if (parseContainerExec(rest)) |target| {
            out.kind = .container_exec;
            out.setName(target);
        }
        return;
    }
}

/// Extract the ssh / mosh target token from the args. Returns the
/// raw `user@host` (or `host`) without flag scanning beyond skipping
/// the `-X arg` pattern for any flag that takes a value.
///
/// Examples (in -> out):
///   `foo@bar.example.com`                    -> `foo@bar.example.com`
///   `-p 2222 foo@bar`                        -> `foo@bar`
///   `-i ~/.ssh/key -p 22 foo`                -> `foo`
///   `-F /etc/ssh/ssh_config alias`           -> `alias`
///   `-J jump1.example.com foo@dest`          -> `foo@dest`
fn extractSshTarget(args: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (tok[0] == '-' and tok.len >= 2) {
            // Flag. Some flags take a value as the next token; others
            // don't. We use a conservative allowlist of known
            // value-taking ssh flags.
            if (flagTakesValue(tok)) {
                _ = it.next(); // consume the value
            }
            continue;
        }
        // First non-flag positional → target.
        return tok;
    }
    return null;
}

fn flagTakesValue(flag: []const u8) bool {
    if (flag.len < 2) return false;
    // Single-letter flags with values per `man ssh(1)`.
    if (flag.len == 2 and flag[0] == '-') {
        return switch (flag[1]) {
            'B', 'b', 'c', 'D', 'E', 'e', 'F', 'I', 'i', 'J', 'L', 'l', 'm', 'O', 'o', 'p', 'Q', 'R', 'S', 'W', 'w' => true,
            else => false,
        };
    }
    // GNU long-option style `--name=value` — already self-contained, no value follows.
    // Unknown longer flags conservatively assume they take a value.
    return false;
}

fn looksLikeOneShotSshLine(args: []const u8) bool {
    // Heuristic: after we find the target token, if there are MORE
    // non-flag tokens, it's a one-shot (`ssh host cmd ...`).
    var it = std.mem.tokenizeAny(u8, args, " \t");
    var saw_target = false;
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (tok[0] == '-' and tok.len >= 2) {
            if (flagTakesValue(tok)) _ = it.next();
            continue;
        }
        if (saw_target) return true; // a second positional → one-shot
        saw_target = true;
    }
    return false;
}

fn looksLikeSudoShell(args: []const u8) bool {
    // `sudo` with no args opens a shell-aware setting depending on
    // distro; we conservatively treat that as elevation.
    if (std.mem.trim(u8, args, " \t").len == 0) return true;
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        // Login-shell shortcuts terminate the scan in our favour.
        if (std.mem.eql(u8, tok, "-s") or std.mem.eql(u8, tok, "-i") or
            std.mem.eql(u8, tok, "--shell") or std.mem.eql(u8, tok, "--login"))
        {
            return true;
        }
        if (tok[0] == '-') {
            // Sudo flags that consume a value as the next token. We
            // skip the value so the *real* command argument lands as
            // the next non-flag token. (`sudo -u root -s` should be
            // elevation, not "is `root` a shell".)
            if (sudoFlagTakesValue(tok)) _ = it.next();
            continue;
        }
        return isShellName(tok);
    }
    return false;
}

fn sudoFlagTakesValue(flag: []const u8) bool {
    // Short flags taking a value per `man sudo(8)`:
    //   -A (askpass), -C (close-from), -D (chdir), -g (group),
    //   -h (host), -p (prompt), -R (chroot), -r (role), -t (type),
    //   -T (timeout), -u (user)
    if (flag.len == 2 and flag[0] == '-') {
        return switch (flag[1]) {
            'A', 'C', 'D', 'g', 'h', 'p', 'R', 'r', 't', 'T', 'u' => true,
            else => false,
        };
    }
    // Long --flag=value is self-contained. Long --flag without `=`
    // typically takes the next token; we conservatively assume yes
    // for unknown long flags whose first char is `-`.
    if (std.mem.startsWith(u8, flag, "--") and std.mem.indexOfScalar(u8, flag, '=') == null) {
        return true;
    }
    return false;
}

fn isShellName(tok: []const u8) bool {
    // Strip leading path components.
    var name = tok;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| name = name[slash + 1 ..];
    return std.mem.eql(u8, name, "bash") or
        std.mem.eql(u8, name, "zsh") or
        std.mem.eql(u8, name, "sh") or
        std.mem.eql(u8, name, "fish") or
        std.mem.eql(u8, name, "dash") or
        std.mem.eql(u8, name, "ksh") or
        std.mem.eql(u8, name, "tcsh") or
        std.mem.eql(u8, name, "csh") or
        std.mem.eql(u8, name, "nu") or
        std.mem.eql(u8, name, "elvish");
}

fn lastNonFlagToken(args: []const u8) ?[]const u8 {
    var last: ?[]const u8 = null;
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |tok| {
        if (tok.len == 0 or tok[0] == '-') continue;
        last = tok;
    }
    return last;
}

/// Parse `kubectl exec [flags] <pod> -- <cmd>` (or without `--`).
/// Returns the pod identifier in `<context>/<ns>/<pod>` form when we
/// can extract context/namespace from CLI flags; otherwise just the
/// pod name.
fn parseKubectlExec(args: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, args, " \t");
    // First positional must be `exec`.
    const first = it.next() orelse return null;
    if (!std.mem.eql(u8, first, "exec")) return null;

    var ns: []const u8 = "";
    var ctx: []const u8 = "";
    var pod: []const u8 = "";

    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "--")) {
            // Anything after `--` is the remote command. We're done.
            break;
        }
        if (tok[0] == '-') {
            // Flag handling. We care about --namespace/-n, --context.
            if (std.mem.eql(u8, tok, "-n") or std.mem.eql(u8, tok, "--namespace")) {
                ns = it.next() orelse "";
                continue;
            }
            if (std.mem.startsWith(u8, tok, "--namespace=")) {
                ns = tok["--namespace=".len..];
                continue;
            }
            if (std.mem.eql(u8, tok, "--context")) {
                ctx = it.next() orelse "";
                continue;
            }
            if (std.mem.startsWith(u8, tok, "--context=")) {
                ctx = tok["--context=".len..];
                continue;
            }
            // Flags that take a value but aren't context/ns: skip.
            if (std.mem.eql(u8, tok, "-c") or std.mem.eql(u8, tok, "--container") or std.mem.eql(u8, tok, "--pod-running-timeout")) {
                _ = it.next();
                continue;
            }
            // Boolean flags (-i, -t, --stdin, --tty, …) — just skip.
            continue;
        }
        // First positional = pod name.
        pod = tok;
        break;
    }
    if (pod.len == 0) return null;

    // Compose. Memory comes from a thread-local static buffer below.
    parse_buf_len = 0;
    appendToParseBuf(if (ctx.len > 0) ctx else "?");
    appendToParseBuf("/");
    appendToParseBuf(if (ns.len > 0) ns else "default");
    appendToParseBuf("/");
    appendToParseBuf(pod);
    return parse_buf[0..parse_buf_len];
}

fn parseDockerExec(args: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, args, " \t");
    const first = it.next() orelse return null;
    if (!std.mem.eql(u8, first, "exec")) return null;
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (tok[0] == '-') {
            // Most docker exec flags are booleans (-i, -t, -d).
            // -e / -u / -w take values; handle defensively.
            if (std.mem.eql(u8, tok, "-e") or std.mem.eql(u8, tok, "-u") or std.mem.eql(u8, tok, "-w") or std.mem.eql(u8, tok, "--env") or std.mem.eql(u8, tok, "--user") or std.mem.eql(u8, tok, "--workdir")) {
                _ = it.next();
            }
            continue;
        }
        return tok; // first non-flag positional = container name
    }
    return null;
}

fn parseContainerExec(args: []const u8) ?[]const u8 {
    // `lxc exec name -- bash`, `incus exec name -- bash`.
    var it = std.mem.tokenizeAny(u8, args, " \t");
    const first = it.next() orelse return null;
    if (!std.mem.eql(u8, first, "exec")) return null;
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (tok[0] == '-' and tok.len > 1) continue;
        return tok;
    }
    return null;
}

/// Run `ssh -G <args>` and extract the resolved `hostname` and `user`.
/// Returns an allocated string `"user@host"` or `"host"` when no user.
///
/// Spawned synchronously — `ssh -G` is fast (typically <100ms) and
/// the user already paid an Enter on `ssh ...` so they're waiting
/// anyway. Failure cases (ssh not installed, syntax error, hang …)
/// surface as an error and the caller falls back to the regex
/// extraction.
fn resolveViaSshG(
    gpa: std.mem.Allocator,
    io: std.Io,
    ssh_binary: []const u8,
    args: []const u8,
) ![]u8 {
    // Build argv: [ssh, -G, <tokenised args...>]. We tokenize on
    // whitespace; quoted args are an edge case we don't handle
    // (regex fallback covers them).
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, ssh_binary);
    try argv.append(gpa, "-G");
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |tok| try argv.append(gpa, tok);

    const result = std.process.run(gpa, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024),
    }) catch return error.SshGFailed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    // ssh -G output is a series of `key value` lines. Find hostname and user.
    var hostname: []const u8 = "";
    var user: []const u8 = "";
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..sp];
        const value = std.mem.trim(u8, line[sp + 1 ..], " \t\r");
        if (std.mem.eql(u8, key, "hostname")) hostname = value;
        if (std.mem.eql(u8, key, "user")) user = value;
    }
    if (hostname.len == 0) return error.SshGFailed;
    if (user.len == 0) return try gpa.dupe(u8, hostname);
    return try std.fmt.allocPrint(gpa, "{s}@{s}", .{ user, hostname });
}

// Scratch buffer for parse output strings. Single-threaded — atty's
// proxy is the only caller and the buffer is read into Frame.name_buf
// immediately. Allocator-free.
var parse_buf: [512]u8 = undefined;
var parse_buf_len: usize = 0;

fn appendToParseBuf(s: []const u8) void {
    const n = @min(s.len, parse_buf.len - parse_buf_len);
    @memcpy(parse_buf[parse_buf_len .. parse_buf_len + n], s[0..n]);
    parse_buf_len += n;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "extractSshTarget: simple user@host" {
    try testing.expectEqualStrings("foo@bar.example.com", extractSshTarget("foo@bar.example.com").?);
}

test "extractSshTarget: skips known value-taking flags" {
    try testing.expectEqualStrings("foo@bar", extractSshTarget("-p 2222 foo@bar").?);
    try testing.expectEqualStrings("foo", extractSshTarget("-i ~/.ssh/key -p 22 foo").?);
    try testing.expectEqualStrings("alias", extractSshTarget("-F /etc/ssh/ssh_config alias").?);
    try testing.expectEqualStrings("foo@dest", extractSshTarget("-J jump.example.com foo@dest").?);
}

test "extractSshTarget: returns null when no positional argument" {
    try testing.expectEqual(@as(?[]const u8, null), extractSshTarget(""));
    try testing.expectEqual(@as(?[]const u8, null), extractSshTarget("-v"));
}

test "looksLikeOneShotSshLine: ssh host plain interactive is NOT one-shot" {
    try testing.expect(!looksLikeOneShotSshLine("foo@bar.example.com"));
    try testing.expect(!looksLikeOneShotSshLine("-p 22 foo@bar"));
    try testing.expect(!looksLikeOneShotSshLine("alias"));
}

test "looksLikeOneShotSshLine: ssh host cmd IS one-shot" {
    try testing.expect(looksLikeOneShotSshLine("foo@bar uptime"));
    try testing.expect(looksLikeOneShotSshLine("-p 22 foo@bar ls -la"));
}

test "parseKubectlExec: basic pod" {
    const r = parseKubectlExec("exec mypod -- bash") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("?/default/mypod", r);
}

test "parseKubectlExec: with namespace flag" {
    const r = parseKubectlExec("exec -n kube-system coredns-abc -- sh") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("?/kube-system/coredns-abc", r);
}

test "parseKubectlExec: with context + namespace + container flags" {
    const r = parseKubectlExec("exec --context=prod --namespace=apps -c web mypod-7d -- bash") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("prod/apps/mypod-7d", r);
}

test "parseKubectlExec: returns null when first arg isn't exec" {
    try testing.expectEqual(@as(?[]const u8, null), parseKubectlExec("get pods"));
}

test "parseDockerExec: basic container" {
    try testing.expectEqualStrings("mycontainer", parseDockerExec("exec -it mycontainer bash").?);
    try testing.expectEqualStrings("mycontainer", parseDockerExec("exec -u root -w /app mycontainer sh").?);
}

test "parseDockerExec: returns null when first arg isn't exec" {
    try testing.expectEqual(@as(?[]const u8, null), parseDockerExec("ps -a"));
}

test "parseContainerExec: lxc exec" {
    try testing.expectEqualStrings("my-vm", parseContainerExec("exec my-vm -- bash").?);
}

test "looksLikeSudoShell: bare sudo and -s / -i" {
    try testing.expect(looksLikeSudoShell(""));
    try testing.expect(looksLikeSudoShell("-s"));
    try testing.expect(looksLikeSudoShell("-i"));
    try testing.expect(looksLikeSudoShell("bash"));
    try testing.expect(looksLikeSudoShell("zsh"));
    try testing.expect(looksLikeSudoShell("-u root -s"));
}

test "looksLikeSudoShell: sudo <non-shell-cmd> is NOT elevation" {
    try testing.expect(!looksLikeSudoShell("apt update"));
    try testing.expect(!looksLikeSudoShell("systemctl restart nginx"));
    try testing.expect(!looksLikeSudoShell("-u www-data cat /etc/passwd"));
}

test "Tracker: push/pop balance" {
    var t = Tracker.init();
    try testing.expectEqual(@as(usize, 0), t.depth);

    // Use the regex fallback only — pass `null` for io to skip ssh -G.
    t.onCommandStart("ssh foo@bar", testing.allocator, null);
    try testing.expectEqual(@as(usize, 1), t.depth);
    try testing.expectEqual(Kind.ssh, t.currentKind());
    try testing.expectEqualStrings("foo@bar", t.current().?.name());

    t.onCommandEnd();
    try testing.expectEqual(@as(usize, 0), t.depth);
    try testing.expectEqual(Kind.none, t.currentKind());
}

test "Tracker: unrecognized command pushes a .none frame" {
    var t = Tracker.init();
    t.onCommandStart("ls -la", testing.allocator, null);
    try testing.expectEqual(@as(usize, 1), t.depth);
    try testing.expectEqual(Kind.none, t.currentKind());
    t.onCommandEnd();
    try testing.expectEqual(@as(usize, 0), t.depth);
}

test "Tracker.currentRecognized: skips `.none` frames sitting on top" {
    // The statusbar consults `currentRecognized` so the
    // `→ ssh:remote` segment doesn't flicker every time the user
    // runs a regular command inside the remote shell. Stack here
    // mirrors that scenario exactly.
    var t = Tracker.init();
    t.onCommandStart("ssh foo@bar", testing.allocator, null);
    t.onCommandStart("ls -la", testing.allocator, null);
    // current() returns the immediate top (`.none` ls frame).
    try testing.expectEqual(Kind.none, t.current().?.kind);
    // currentRecognized() walks down to the ssh frame underneath.
    try testing.expectEqual(Kind.ssh, t.currentRecognized().?.kind);
    try testing.expectEqualStrings("foo@bar", t.currentRecognized().?.name());
}

test "Tracker.currentRecognized: returns null when only `.none` frames are on the stack" {
    var t = Tracker.init();
    t.onCommandStart("ls -la", testing.allocator, null);
    t.onCommandStart("date", testing.allocator, null);
    try testing.expectEqual(@as(?*const Frame, null), t.currentRecognized());
}

test "Tracker.currentRecognized: returns null on an empty stack" {
    var t = Tracker.init();
    try testing.expectEqual(@as(?*const Frame, null), t.currentRecognized());
}

test "Tracker: nested ssh chain" {
    var t = Tracker.init();
    t.onCommandStart("ssh server1", testing.allocator, null);
    try testing.expectEqualStrings("server1", t.current().?.name());

    // From inside ssh, user types another ssh — local atty sees it
    // because keystrokes flow through us.
    t.onCommandStart("ssh server2", testing.allocator, null);
    try testing.expectEqualStrings("server2", t.current().?.name());
    try testing.expectEqual(@as(usize, 2), t.depth);

    // Exit server2 — top frame pops back to server1.
    t.onCommandEnd();
    try testing.expectEqualStrings("server1", t.current().?.name());

    // Exit server1.
    t.onCommandEnd();
    try testing.expectEqual(@as(usize, 0), t.depth);
}

test "Tracker: over-pop is a no-op (doesn't crash)" {
    var t = Tracker.init();
    t.onCommandEnd();
    t.onCommandEnd();
    try testing.expectEqual(@as(usize, 0), t.depth);
}

test "Tracker: stack saturates at max_depth" {
    var t = Tracker.init();
    var i: usize = 0;
    while (i < max_depth + 3) : (i += 1) {
        t.onCommandStart("ssh server", testing.allocator, null);
    }
    try testing.expectEqual(max_depth, t.depth);
    try testing.expectEqual(@as(usize, 3), t.overflow);
}

test "Tracker: balanced pops after saturation drain overflow first" {
    // Push 11 times (max_depth=8 plus 3 overflow). The first 8 land
    // as real frames; the last 3 increment overflow. Then 11 pops:
    // first 3 consume overflow (depth stays pinned at 8), next 8
    // unwind the stack one frame each.
    var t = Tracker.init();
    var i: usize = 0;
    while (i < max_depth + 3) : (i += 1) {
        t.onCommandStart("ssh foo@bar", testing.allocator, null);
    }
    try testing.expectEqual(max_depth, t.depth);
    try testing.expectEqual(@as(usize, 3), t.overflow);

    // First three pops drain overflow without unwinding.
    t.onCommandEnd();
    try testing.expectEqual(max_depth, t.depth);
    try testing.expectEqual(@as(usize, 2), t.overflow);
    t.onCommandEnd();
    t.onCommandEnd();
    try testing.expectEqual(max_depth, t.depth);
    try testing.expectEqual(@as(usize, 0), t.overflow);

    // Remaining pops unwind real frames.
    i = 0;
    while (i < max_depth) : (i += 1) t.onCommandEnd();
    try testing.expectEqual(@as(usize, 0), t.depth);
    try testing.expectEqual(@as(usize, 0), t.overflow);
}

test "Tracker: OSC 7 cwd update lands on top frame" {
    var t = Tracker.init();
    t.onCommandStart("ssh foo@bar", testing.allocator, null);
    t.onRemoteCwd("file://bar.example.com/home/foo/work");
    try testing.expectEqualStrings("/home/foo/work", t.current().?.cwd());
}

test "Tracker: onRemoteCwd accepts bare path (what Osc7.takeCwd returns)" {
    // The Osc7 parser strips the `file://<host>` prefix before
    // handing us the path, so onRemoteCwd must accept the bare
    // absolute path too — otherwise the proxy → Tracker plumbing
    // silently drops every OSC 7 in production.
    var t = Tracker.init();
    t.onCommandStart("ssh foo@bar", testing.allocator, null);
    t.onRemoteCwd("/var/log");
    try testing.expectEqualStrings("/var/log", t.current().?.cwd());
}

test "Tracker: OSC 7 ignored when no frame is active" {
    var t = Tracker.init();
    t.onRemoteCwd("file://host/path"); // no crash
    try testing.expectEqual(@as(usize, 0), t.depth);
}

test "Tracker: onRemoteCwd ignores empty input and malformed file:// URIs" {
    var t = Tracker.init();
    t.onCommandStart("ssh foo@bar", testing.allocator, null);
    // Empty path → silently dropped (no cwd set).
    t.onRemoteCwd("");
    try testing.expectEqual(@as(usize, 0), t.current().?.cwd_len);
    // file:// without a path slash → dropped (we need to know
    // where the host ends and the path begins).
    t.onRemoteCwd("file://hostonly");
    try testing.expectEqual(@as(usize, 0), t.current().?.cwd_len);
    // file:// with valid path → accepted.
    t.onRemoteCwd("file://host/srv");
    try testing.expectEqualStrings("/srv", t.current().?.cwd());
}

test "Tracker: one-shot ssh host cmd doesn't classify as ssh" {
    var t = Tracker.init();
    t.onCommandStart("ssh foo@bar uptime", testing.allocator, null);
    // The frame still pushes (stack invariant for `;D`-pop balance)
    // but its kind stays `.none` so commits aren't tagged with a
    // remote target.
    try testing.expectEqual(@as(usize, 1), t.depth);
    try testing.expectEqual(Kind.none, t.currentKind());
}

test "Tracker: sudo bash classified as elevation" {
    var t = Tracker.init();
    t.onCommandStart("sudo bash", testing.allocator, null);
    try testing.expectEqual(Kind.elevation, t.currentKind());
    try testing.expectEqualStrings("sudo", t.current().?.name());
}

test "Tracker: sudo apt update is NOT elevation (typing inside apt isn't shell input)" {
    var t = Tracker.init();
    t.onCommandStart("sudo apt update", testing.allocator, null);
    try testing.expectEqual(Kind.none, t.currentKind());
}

test "Tracker: su classification" {
    var t = Tracker.init();
    t.onCommandStart("su - postgres", testing.allocator, null);
    try testing.expectEqual(Kind.su, t.currentKind());
    try testing.expectEqualStrings("su:postgres", t.current().?.name());
}

test "Tracker: kubectl exec classification + namespace/context" {
    var t = Tracker.init();
    t.onCommandStart("kubectl exec --context=prod --namespace=apps -it mypod -- bash", testing.allocator, null);
    try testing.expectEqual(Kind.kubectl_exec, t.currentKind());
    try testing.expectEqualStrings("prod/apps/mypod", t.current().?.name());
}

test "Tracker: docker exec classification" {
    var t = Tracker.init();
    t.onCommandStart("docker exec -it nginx bash", testing.allocator, null);
    try testing.expectEqual(Kind.docker_exec, t.currentKind());
    try testing.expectEqualStrings("nginx", t.current().?.name());
}

test "formatCwd: ssh frame produces ssh:// URI without double-slash" {
    var f = Frame{ .kind = .ssh };
    f.setName("foo@bar");
    f.setCwd("/home/foo");
    var buf: [256]u8 = undefined;
    // The leading `/` from the OSC 7-captured path is normalised
    // away to avoid `ssh://host//path` — see the comment in
    // formatCwd. atuin's [DIRECTORY] groups by exact string match;
    // single-slash is what we want both as docs and as filter key.
    try testing.expectEqualStrings("ssh://foo@bar/home/foo", formatCwd(&f, &buf, "/local/cwd"));
}

test "formatCwd: ssh frame without cwd uses `?`" {
    var f = Frame{ .kind = .ssh };
    f.setName("foo@bar");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("ssh://foo@bar/?", formatCwd(&f, &buf, "/local/cwd"));
}

test "formatCwd: kubectl frame" {
    var f = Frame{ .kind = .kubectl_exec };
    f.setName("prod/apps/mypod");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("k8s://prod/apps/mypod/?", formatCwd(&f, &buf, "/local/cwd"));
}

test "formatCwd: elevation frame prepends sudo: to local cwd" {
    var f = Frame{ .kind = .elevation };
    f.setName("sudo");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("sudo:/home/me", formatCwd(&f, &buf, "/home/me"));
}

test "formatCwd: elevation with empty fallback uses ? placeholder (not trailing colon)" {
    // atuin's `--cwd` should never end with a bare `:`. The local
    // shell's cwd isn't always available to atty (we'd need to
    // shell out to read /proc/<child_pid>/cwd, which we don't do
    // synchronously); the placeholder makes that visible in
    // Ctrl+R rather than producing a malformed value.
    var f = Frame{ .kind = .elevation };
    f.setName("sudo");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("sudo:?", formatCwd(&f, &buf, ""));
}

test "formatCwd: su with empty fallback also uses ? placeholder" {
    var f = Frame{ .kind = .su };
    f.setName("su:postgres");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("su:postgres:?", formatCwd(&f, &buf, ""));
}

test "formatCwd: none frame falls back to local cwd verbatim" {
    var f = Frame{ .kind = .none };
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/me", formatCwd(&f, &buf, "/home/me"));
}
