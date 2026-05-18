//! Tests for `subprocess/parse.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("parse.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const subprocess = @import("../subprocess.zig");

// Re-binds of pub decls so test bodies stay short.
const extractSshTarget = mod.extractSshTarget;
const looksLikeOneShotSshLine = mod.looksLikeOneShotSshLine;
const looksLikeSudoShell = mod.looksLikeSudoShell;
const parseContainerExec = mod.parseContainerExec;
const parseDockerExec = mod.parseDockerExec;
const parseInto = mod.parseInto;
const parseKubectlExec = mod.parseKubectlExec;

// ===========================================================================
// Tests
// ===========================================================================

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

test "extractSshTarget: long flag that takes a value consumes the next token" {
    // Without `--ssh` in the value-taking allowlist, the extractor
    // would see `ssh` as the first non-flag positional and return
    // it as the target — mosh runs would always be tagged as
    // `ssh:ssh` instead of `ssh:host`. Pinning the fix.
    try testing.expectEqualStrings("host", extractSshTarget("--ssh ssh host").?);
    try testing.expectEqualStrings("foo@bar", extractSshTarget("--port 2222 foo@bar").?);
    // `--name=value` is self-contained — value is in the token, no
    // next-token consumption.
    try testing.expectEqualStrings("foo@bar", extractSshTarget("--port=2222 foo@bar").?);
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

test "parseKubectlExec: basic pod (no flags = ?/?/<pod>)" {
    const r = parseKubectlExec("exec mypod -- bash") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("?/?/mypod", r);
}

test "parseKubectlExec: with namespace flag (?/ns/<pod>)" {
    const r = parseKubectlExec("exec -n kube-system coredns-abc -- sh") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("?/kube-system/coredns-abc", r);
}

test "parseKubectlExec: with context + namespace + container flags" {
    const r = parseKubectlExec("exec --context=prod --namespace=apps -c web mypod-7d -- bash") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("prod/apps/mypod-7d", r);
}

test "parseKubectlExec: global flags BEFORE exec are recognised" {
    const r1 = parseKubectlExec("-n kube-system exec coredns-abc -- sh") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("?/kube-system/coredns-abc", r1);

    const r2 = parseKubectlExec("--context=prod exec mypod -- bash") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("prod/?/mypod", r2);

    const r3 = parseKubectlExec("--kubeconfig /tmp/kc --context=prod -n apps exec db-0 -- bash") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("prod/apps/db-0", r3);
}

test "parseKubectlExec: returns null when `exec` is not in the args" {
    try testing.expectEqual(@as(?[]const u8, null), parseKubectlExec("get pods"));
    try testing.expectEqual(@as(?[]const u8, null), parseKubectlExec("-n kube-system get pods"));
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

test "looksLikeSudoShell: boolean long flags don't eat the trailing shell name" {
    // `sudo --preserve-env bash` should be elevation. Pre-fix the
    // parser treated `--preserve-env` as value-taking and skipped
    // `bash`, missing the classification.
    try testing.expect(looksLikeSudoShell("--preserve-env bash"));
    try testing.expect(looksLikeSudoShell("--non-interactive zsh"));
    try testing.expect(looksLikeSudoShell("--reset-timestamp -i"));
    // Value-taking long flags still consume the next token. The
    // resulting target is the shell after that.
    try testing.expect(looksLikeSudoShell("--user root bash"));
    try testing.expect(looksLikeSudoShell("--chdir /tmp bash"));
}
