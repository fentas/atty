//! ghost_midline_insert_after_uparrow — Arrow-Up history recall +
//! Left back into the line + a typed space mid-line must NOT cause
//! the ghost overlay to paint over the right-side text. The line
//! model is `uncertain` AND `cursor_moved` after the space; both gate
//! ghost paint independently in `renderGhost`.
//!
//! Only the history module is enabled so the snapshot grid carries
//! the prompt + the recalled line and nothing else.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-ghost-midline",
        .format = .plain,
        .capacity = 32,
    }),
};
