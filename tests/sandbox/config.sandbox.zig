// Sandbox build config for atty. The host user's src/config.zig is
// untouched; the sandbox runner builds atty with
// `zig build -Dconfig=tests/sandbox/config.sandbox.zig` so the
// resulting binary talks to atty-guard at the production socket
// path even when the developer's own config has it disabled.
//
// Kept minimal — only security_guard is wired in. Other modules
// (guardrail / atuin / history / llm) stay off so scenarios don't
// have to fight unrelated side effects.
const atty = @import("atty");

pub const modules = .{
    atty.modules.security_guard.configure(.{
        .enabled = true,
        .skip_in_incognito = false,
        .daemon_socket_path = "/run/atty-guard/atty-guard.sock",
        .daemon_timeout_ms = 500,
    }),
};
