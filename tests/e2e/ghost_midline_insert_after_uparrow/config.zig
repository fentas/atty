//! ghost_midline_insert_after_uparrow — Arrow-Up history recall +
//! Left back into the line + a typed space mid-line must NOT cause
//! the ghost overlay to paint over the right-side text. The mid-line
//! splice in `LineState.append` keeps the cursor at `cursor_pos < len`
//! after the insert, so `cursor_moved` stays true and `renderGhost`
//! suppresses the overlay.
//!
//! Modules: guardrail (proxy default) + history. The history module
//! is what would surface a ghost suggestion if the cursor + line
//! state ever wrongly cleared; with the splice in place no candidate
//! ever reaches `renderGhost`.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-ghost-midline",
        .format = .plain,
        .capacity = 32,
    }),
};
