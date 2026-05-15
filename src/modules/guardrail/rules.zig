//! Rule data model for the guardrail module: the `Behavior` enum,
//! the `AuthorMask` gate, the `Rule` shape, and the shipped
//! `default_rules` list.
//!
//! Lives in its own file so the rule list — the part most users
//! customise — is the first thing visible when opening the folder,
//! without the comptime `configure()` machinery getting in the way.

const Author = @import("../../module.zig").Author;
const Match = @import("match.zig").Match;

/// Whether a rule fires depending on who initiated the commit.
/// Default = applies to both. Use this to declare two rules for the
/// same pattern with different `Behavior` per author (the canonical
/// "confirm for user, block for llm" shape).
pub const AuthorMask = struct {
    user: bool = true,
    llm: bool = true,

    pub fn applies(self: AuthorMask, author: Author) bool {
        return switch (author) {
            .user => self.user,
            .llm => self.llm,
        };
    }
};

/// What to do when a rule matches.
pub const Behavior = enum {
    /// Banner + swallow. Press Enter again to confirm (forwards),
    /// any other key to cancel (disarms; user can keep editing).
    confirm,
    /// Like `.confirm`, but the confirmation persists for the rest
    /// of the session. Once the user confirms this rule once,
    /// subsequent matches forward immediately with no banner.
    /// Per-rule, not module-wide.
    confirm_once,
    /// Banner with a "blocked." trailer; the Enter is replaced with
    /// Ctrl+U (unix-line-discard) so readline kills the typed line.
    /// Nothing reaches the shell.
    block,
    /// Banner with a "warning — running anyway." trailer; the Enter
    /// is forwarded. Use for lines that should be flagged but not
    /// stopped (audit trail without friction).
    warn,
};

pub const Rule = struct {
    name: []const u8,
    match: Match,
    reason: []const u8,
    /// Which author(s) trigger this rule. Default = both. To get
    /// different behavior per author for the same pattern, declare
    /// two rules with mutually-exclusive masks.
    authors: AuthorMask = .{},
    behavior: Behavior = .confirm,
};

/// Default rules. Catastrophic patterns (exact `rm -rf /`, fork
/// bomb) are `.block` for both authors so neither party can talk
/// their way past them. Merely-dangerous patterns (`rm -rf` with a
/// subpath, `mkfs`, `dd …`) `.block` when the line is
/// `.llm`-authored but only `.confirm` for `.user` — the human can
/// override their own decision; a model suggesting the same line
/// cannot.
pub const default_rules = [_]Rule{
    .{
        // Exact-only — `rm -rf /home/me` falls through to the
        // broader "rm -rf" substring rules below (confirm for
        // user, block for llm). Use `.glob` not `.substring` so
        // typing `rm -rf /something` doesn't get blocked outright.
        .name = "rm-rf-root",
        .match = .{ .glob = "rm -rf /" },
        .reason = "rm -rf on the root path",
        .behavior = .block,
    },
    .{
        .name = "fork-bomb",
        .match = .{ .substring = ":(){ :|:& };:" },
        .reason = "classic fork bomb",
        .behavior = .block,
    },
    .{
        .name = "rm-rf-tilde-user",
        .match = .{ .substring = "rm -rf ~" },
        .reason = "rm -rf on home",
        .authors = .{ .user = true, .llm = false },
        .behavior = .confirm,
    },
    .{
        .name = "rm-rf-tilde-llm",
        .match = .{ .substring = "rm -rf ~" },
        .reason = "rm -rf on home (llm)",
        .authors = .{ .user = false, .llm = true },
        .behavior = .block,
    },
    .{
        .name = "rm-rf-user",
        .match = .{ .substring = "rm -rf" },
        .reason = "rm -rf invocation",
        .authors = .{ .user = true, .llm = false },
        .behavior = .confirm,
    },
    .{
        .name = "rm-rf-llm",
        .match = .{ .substring = "rm -rf" },
        .reason = "rm -rf invocation",
        .authors = .{ .user = false, .llm = true },
        .behavior = .block,
    },
    .{
        // Must precede the generic `sudo` rule: `sudo mkfs.ext4
        // /dev/sda` would otherwise match `sudo` first and only
        // require `.confirm`, bypassing the prefix-anchored `mkfs`
        // block rule for llm. Same goes for the dd variant below.
        .name = "sudo-mkfs-llm",
        .match = .{ .prefix = "sudo mkfs" },
        .reason = "sudo mkfs (llm)",
        .authors = .{ .user = false, .llm = true },
        .behavior = .block,
    },
    .{
        .name = "sudo-dd-llm",
        .match = .{ .prefix = "sudo dd " },
        .reason = "sudo dd (llm)",
        .authors = .{ .user = false, .llm = true },
        .behavior = .block,
    },
    .{
        .name = "sudo",
        .match = .{ .prefix = "sudo " },
        .reason = "sudo invocation",
        .behavior = .confirm,
    },
    .{
        .name = "mkfs-user",
        .match = .{ .prefix = "mkfs" },
        .reason = "filesystem creation",
        .authors = .{ .user = true, .llm = false },
        .behavior = .confirm,
    },
    .{
        .name = "mkfs-llm",
        .match = .{ .prefix = "mkfs" },
        .reason = "filesystem creation (llm)",
        .authors = .{ .user = false, .llm = true },
        .behavior = .block,
    },
    .{
        // Prefix not substring — any `dd ` invocation deserves a
        // beat (covers both `dd if=/dev/sda …` reads and
        // `dd … of=/dev/sda` writes; `dd if=/tmp of=/tmp/copy`
        // too, which is fine — the confirm prompt is cheap).
        .name = "dd-user",
        .match = .{ .prefix = "dd " },
        .reason = "dd invocation",
        .authors = .{ .user = true, .llm = false },
        .behavior = .confirm,
    },
    .{
        .name = "dd-llm",
        .match = .{ .prefix = "dd " },
        .reason = "dd invocation",
        .authors = .{ .user = false, .llm = true },
        .behavior = .block,
    },
    .{
        .name = "curl-pipe-sh",
        .match = .{ .substring = "| sh" },
        .reason = "piping untrusted output into a shell",
        .behavior = .confirm,
    },
    .{
        .name = "curl-pipe-bash",
        .match = .{ .substring = "| bash" },
        .reason = "piping untrusted output into a shell",
        .behavior = .confirm,
    },
    .{
        .name = "chmod-world",
        .match = .{ .substring = "chmod 777 /" },
        .reason = "world-writable root path",
        .behavior = .confirm,
    },
};
