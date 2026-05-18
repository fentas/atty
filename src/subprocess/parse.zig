//! Subprocess — command-line parsers + `ssh -G` resolver.
//!
//! Pulled out of `../subprocess.zig` so the public types (Kind, Frame,
//! Tracker) stay legible: this file is mostly token-walking heuristics
//! across ssh / mosh / sudo / su / kubectl / docker / lxc / incus
//! invocations, plus the synchronous `ssh -G` fallback that resolves
//! aliases against ssh_config.
//!
//! Caller is `subprocess.Tracker.onCommandStart`. Tests cover each
//! parser in isolation and the surrounding integration assertions
//! live in `../subprocess.zig` (they exercise Tracker, which in turn
//! drives these parsers).

const std = @import("std");
const subprocess = @import("../subprocess.zig");

/// Inspect `line` and populate `out` with the best-effort
/// classification. Falls back to `kind=.none` for unrecognized
/// commands.
pub fn parseInto(
    out: *subprocess.Frame,
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
        // Emit just `su` (no trailing colon) when the user wasn't
        // specified. The `.su` encoding path later appends
        // `:<local-cwd>` to `name`, so a `"su:"` name would
        // produce `"su::?"` in atuin's `--cwd` — visibly malformed.
        if (target_user.len == 0) {
            out.setName("su");
        } else {
            var buf: [128]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "su:{s}", .{target_user}) catch "su";
            out.setName(formatted);
        }
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
pub fn extractSshTarget(args: []const u8) ?[]const u8 {
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
    // GNU long-option `--name=value` is self-contained — the value
    // is part of the same token, no next-token consumption.
    if (std.mem.startsWith(u8, flag, "--") and std.mem.indexOfScalar(u8, flag, '=') != null) {
        return false;
    }
    // Known long flags from `mosh` / `ssh` that DO take a separate
    // value as the next token. Without these listed, the target
    // extractor would treat the value as the positional host —
    // e.g. `mosh --ssh ssh host` would pick `ssh` as the target.
    //
    // Conservative allowlist rather than "any long flag takes a
    // value" because plenty of long flags ARE booleans (`--verbose`,
    // `--quiet`, `--xauth-location`-style switches handled in the
    // ssh -G path …). Mis-classifying a boolean as value-taking
    // eats the next token (often the host), which is worse than
    // mis-classifying a value-taking flag (the parser keeps going
    // and finds the host anyway — the false value just looks like
    // a positional that we then ignore).
    if (std.mem.eql(u8, flag, "--ssh")) return true; // mosh --ssh <ssh-cmd>
    if (std.mem.eql(u8, flag, "--port")) return true; // mosh / ssh aliases
    if (std.mem.eql(u8, flag, "--server")) return true; // mosh --server <path>
    if (std.mem.eql(u8, flag, "--predict")) return true; // mosh --predict <mode>
    if (std.mem.eql(u8, flag, "--bind-server")) return true; // mosh
    return false;
}

pub fn looksLikeOneShotSshLine(args: []const u8) bool {
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

pub fn looksLikeSudoShell(args: []const u8) bool {
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
    // Long flags `--name=value` are self-contained — the value is
    // baked into the token, no next-token consumption.
    if (std.mem.startsWith(u8, flag, "--") and std.mem.indexOfScalar(u8, flag, '=') != null) {
        return false;
    }
    // Allowlist of known long flags that take a SEPARATE value
    // token. Default-true for unknown long flags was wrong — sudo
    // has many boolean long flags (`--preserve-env`,
    // `--non-interactive`, `--reset-timestamp`, `--list`, …) and
    // skipping the next token after one of those would gobble the
    // user's actual shell argument (`sudo --preserve-env bash`
    // would skip `bash` and miss the elevation classification).
    if (std.mem.eql(u8, flag, "--askpass")) return true;
    if (std.mem.eql(u8, flag, "--close-from")) return true;
    if (std.mem.eql(u8, flag, "--chdir")) return true;
    if (std.mem.eql(u8, flag, "--group")) return true;
    if (std.mem.eql(u8, flag, "--host")) return true;
    if (std.mem.eql(u8, flag, "--prompt")) return true;
    if (std.mem.eql(u8, flag, "--chroot")) return true;
    if (std.mem.eql(u8, flag, "--role")) return true;
    if (std.mem.eql(u8, flag, "--type")) return true;
    if (std.mem.eql(u8, flag, "--command-timeout")) return true;
    if (std.mem.eql(u8, flag, "--user")) return true;
    if (std.mem.eql(u8, flag, "--other-user")) return true;
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

/// Parse `kubectl [global-flags] exec [exec-flags] <pod> -- <cmd>`.
/// Recognises kubectl's GLOBAL flags before the `exec` subcommand
/// (`kubectl -n kube-system exec …`, `kubectl --context=prod exec …`)
/// and the exec-side flags after. Returns the pod identifier as
/// `<context>/<ns>/<pod>` where missing fields are `?` — *never*
/// the kubeconfig's `default` namespace, because we don't read
/// kubeconfig and can't know the user's current default. The `?`
/// placeholder makes "unresolved" visible in atuin's Ctrl+R cwd
/// view rather than silently mis-labelling commands.
pub fn parseKubectlExec(args: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, args, " \t");

    var ns: []const u8 = "";
    var ctx: []const u8 = "";

    // Pass 1: consume global flags + look for `exec`. kubectl's
    // global flags include `-n` / `--namespace`, `--context`,
    // `--kubeconfig`, `-v`, `--user`, `--server`, etc. We capture
    // the ones we care about and skip the rest.
    var found_exec = false;
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "exec")) {
            found_exec = true;
            break;
        }
        if (tok[0] != '-') return null; // unrecognised non-flag positional before exec
        // Global flag handling — same name/value pairs as exec-side.
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
        // Other known value-taking global flags — consume value.
        if (std.mem.eql(u8, tok, "--kubeconfig") or
            std.mem.eql(u8, tok, "--user") or
            std.mem.eql(u8, tok, "--server") or
            std.mem.eql(u8, tok, "--token") or
            std.mem.eql(u8, tok, "--cluster") or
            std.mem.eql(u8, tok, "--as") or
            std.mem.eql(u8, tok, "--cache-dir") or
            std.mem.eql(u8, tok, "-s") or
            std.mem.eql(u8, tok, "-v"))
        {
            _ = it.next();
            continue;
        }
        if (std.mem.indexOfScalar(u8, tok, '=') != null) continue; // --flag=value, self-contained
        // Unknown flag — boolean by default.
    }
    if (!found_exec) return null;

    // Pass 2: exec-side flags + pod.
    var pod: []const u8 = "";
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "--")) {
            // Anything after `--` is the remote command. We're done.
            break;
        }
        if (tok[0] == '-') {
            // Exec-side overrides of namespace / context (allowed
            // by kubectl even though it's unusual).
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

    // Compose into the module-scope `parse_buf` below. Caller
    // (`parseInto`) copies the slice into `Frame.name_buf` before
    // the next parse runs, so the borrow is short-lived. This
    // module is single-threaded by design — the proxy event loop
    // is the only caller — so the shared global is safe.
    //
    // Unresolved fields emit `?` rather than a kubeconfig default
    // we can't verify. That keeps the encoded `--cwd` honest:
    // `k8s://?/?/mypod` says "we know the pod but not the
    // context/namespace" instead of asserting `k8s://?/default/mypod`
    // which would silently be wrong on any cluster whose current
    // context's namespace isn't `default`.
    parse_buf_len = 0;
    appendToParseBuf(if (ctx.len > 0) ctx else "?");
    appendToParseBuf("/");
    appendToParseBuf(if (ns.len > 0) ns else "?");
    appendToParseBuf("/");
    appendToParseBuf(pod);
    return parse_buf[0..parse_buf_len];
}

pub fn parseDockerExec(args: []const u8) ?[]const u8 {
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

pub fn parseContainerExec(args: []const u8) ?[]const u8 {
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
/// **Synchronous on the proxy main loop.** `ssh -G` is fast in the
/// common case (typically <100ms — config parse + DNS lookup) and
/// the user just pressed Enter on `ssh …`, so they're already
/// blocked waiting on the connect. The added latency is invisible
/// behind ssh's own connect cost.
///
/// Known risk: a misbehaving `ssh -G` (slow DNS resolver, hung
/// `Match exec` block, ssh binary that prints on -G and waits
/// forever) WOULD stall the proxy until it returns. We accept this
/// trade vs. growing a worker-thread + watchdog for what is in
/// practice a 100ms call. `Config.subprocess.use_ssh_g = false`
/// turns the call off and falls back to regex extraction, which
/// users on flaky DNS or odd ssh wrappers should pick.
///
/// Buffers: both `stdout_limit` and `stderr_limit` are bounded so
/// a verbose / errored ssh (e.g. one run with `-vv` in the user's
/// ssh config) can't allocate unbounded memory.
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
        // Cap stderr too. ssh's -G output is normally clean, but
        // unusual configs (`-vv`, broken `Match exec` block, etc.)
        // can produce verbose / unbounded errors; without a cap
        // the proxy would balloon memory on a single bad
        // invocation. 4 KiB is far more than any sane diagnostic.
        .stderr_limit = .limited(4 * 1024),
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
// Tests — extracted to `parse_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("parse_tests.zig");
}
