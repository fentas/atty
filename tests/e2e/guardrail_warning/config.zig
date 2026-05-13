//! guardrail_warning — atty built with only the guardrail module
//! (no history, no statusbar) so the on-screen evidence we snapshot
//! is exactly the warning banner. No status bar means snapshot rows
//! are deterministic without timing the bar's repaint.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
};
