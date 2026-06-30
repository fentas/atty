//! atty_demo:mouse_links — click a path:line token in output to open it in
//! $EDITOR. NOT a regression test. EDITOR=echo so the click shows the resolved
//! editor command running instead of launching a real editor in the recording.
const atty = @import("atty");

pub const modules = .{
    atty.modules.mouse_links.configure(.{ .editor = "echo" }),
};

pub const mouse: atty.Mouse = .{ .enabled = true };

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
