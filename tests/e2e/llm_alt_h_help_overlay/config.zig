//! llm_alt_h_help_overlay — `Alt+H` latches the help overlay
//! (model + cycle position + endpoint) as a transient hint.
//!
//! Two configured models so the cycle indicator (`2/2`) shows.
//! Inert endpoint so the overlay reports `(inert — no endpoint)`,
//! matching the path most CI / scenario runs will hit (no real
//! HTTP). Real-endpoint behaviour is manually verified.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.llm.configure(.{
        // Empty api_base inside ProviderEntry → inert transport;
        // the overlay still surfaces the cycle indicator (`2/2`).
        .providers = &.{
            .{ .name = "model-alpha", .config = .{ .http = .{ .model = "model-alpha" } } },
            .{ .name = "model-beta", .config = .{ .http = .{ .model = "model-beta" } } },
        },
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
