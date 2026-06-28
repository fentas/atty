//! attop configuration — committed template (dwm `config.def.h` style).
//!
//! `build.zig` copies this to `config.zig` (gitignored) on first build;
//! edit THAT for your overrides — `git pull` then won't fight your edits.
//! This is the Suckless-extensible surface attop mirrors from atty: there
//! is no runtime plugin loader. To add / remove / reorder a dashboard
//! panel, edit the `panels` tuple below and recompile.
//!
//! A panel is any type with the hook shape documented in `panel.zig`
//! (`Runtime` + `attach` + `title` + `navKey` + `render`, plus optional
//! `onKey` / `onTick` / `footerHint` / `wantsFocusAtStart`). Write your own
//! in a new file and drop it into the tuple — same contract as the proxy's
//! `modules`.

const home = @import("home.zig");
const guard = @import("guard.zig");
const fleet = @import("fleet.zig");
const setup = @import("setup.zig");
const help = @import("help.zig");

/// The dashboard panels, left-to-right in the tab bar. Focus starts on the
/// first panel whose `wantsFocusAtStart` votes yes (Setup, when the stack
/// isn't ready) — otherwise the first panel.
pub const panels = .{
    home.Panel,
    guard.Panel,
    fleet.Panel,
    setup.Panel,
    help.Panel,
};
