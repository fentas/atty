const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-ghost-wrap-history",
        .format = .plain,
        .capacity = 32,
    }),
};
