//! llm_esc_csiu_outside_ai_passes_through — pins the CSI-u Esc
//! cleanup gate from the UNCONSUMED side. The LLM module must be
//! loaded (so onAction is actually wired) but AI mode must NOT be
//! active when Esc fires; that way llm_exec_cancel returns false
//! and the proxy's matched_binding cleanup path runs.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.llm.configure(.{
        .provider = .{ .http = .{ .api_base = "http://localhost:0", .model = "fixture-model" } },
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
