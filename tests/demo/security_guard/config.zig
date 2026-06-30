//! atty_demo:security_guard — the in-proc Tier-1 classifier flags a dangerous
//! command before it runs, with NO atty-guard daemon (daemon_socket_path empty
//! → the bundled pattern set runs in-process). NOT a regression test.
const atty = @import("atty");

pub const modules = .{
    atty.modules.security_guard.configure(.{ .enabled = true }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
