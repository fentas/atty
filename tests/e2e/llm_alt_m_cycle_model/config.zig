//! llm_alt_m_cycle_model — `Alt+M` rotates through `cfg.models` and
//! latches the new pick as a statusbar hint. Pinned because the
//! cycle mechanism is the foundation for Alt+H's help overlay
//! (which surfaces the current pick) and for the future exec-
//! dialog's per-call model resolution.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.llm.configure(.{
        // Inert (no HTTP) — the cycle and hint are pure runtime
        // state, no worker round-trip needed.
        .api_base = "",
        .models = &.{
            .{ .name = "model-alpha" },
            .{ .name = "model-beta" },
            .{ .name = "model-gamma" },
        },
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
