//! Discovery stub — `modules/llm.zig`'s tests live in two siblings
//! (`llm_parse_tests.zig` for build/extract/system_prompt/resolveApi,
//! `llm_status_tests.zig` for statusText + HTTP worker round-trips),
//! each under 700 LOC. This stub also cascades into the sibling
//! test files under `llm/` (paint, hooks, parse) so the existing
//! `unit_tests.zig` discovery chain stays a single hop deep.

const parse = @import("llm/parse.zig");

test {
    _ = parse;
    _ = @import("llm/paint_tests.zig");
    _ = @import("llm/paint_width.zig");
    _ = @import("llm/hooks_tests.zig");
    _ = @import("llm_parse_tests.zig");
    _ = @import("llm_status_tests.zig");
}
