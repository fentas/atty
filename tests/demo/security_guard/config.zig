//! atty_demo:security_guard — the in-proc Tier-1 classifier flags a dangerous
//! command before it runs, with NO atty-guard daemon (daemon_socket_path empty
//! → the bundled pattern set runs in-process). NOT a regression test.
const atty = @import("atty");

pub const modules = .{
    atty.modules.security_guard.configure(.{
        .enabled = true,
        // No sidecar in the demo: empty path keeps Tier-1 in-process (explicit
        // so the demo is robust if the default ever changes).
        .daemon_socket_path = "",
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
