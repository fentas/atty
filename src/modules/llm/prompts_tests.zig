const std = @import("std");
const testing = std.testing;
const mod = @import("prompts.zig");
const types = @import("types.zig");

test "selectPrompt returns the right prompt per mode" {
    try testing.expectEqualStrings(mod.prompt_single, mod.selectPrompt(.single));
    try testing.expectEqualStrings(mod.prompt_dialog, mod.selectPrompt(.dialog));
    try testing.expectEqualStrings(mod.prompt_auto, mod.selectPrompt(.auto));
    try testing.expectEqualStrings(mod.prompt_chat, mod.selectPrompt(.chat));
}

test "every prompt mentions the fenced action protocol" {
    const all = [_][]const u8{ mod.prompt_single, mod.prompt_dialog, mod.prompt_auto, mod.prompt_chat };
    for (all) |p| {
        try testing.expect(std.mem.indexOf(u8, p, "```exec") != null);
    }
}

test "chat prompt explicitly permits no-fence replies" {
    try testing.expect(std.mem.indexOf(u8, mod.prompt_chat, "Pure prose is also a valid reply") != null);
}

test "auto prompt enumerates concrete destructive operations to refuse" {
    try testing.expect(std.mem.indexOf(u8, mod.prompt_auto, "rm -rf") != null);
    try testing.expect(std.mem.indexOf(u8, mod.prompt_auto, "force") != null);
    try testing.expect(std.mem.indexOf(u8, mod.prompt_auto, "DROP") != null);
}

test "single prompt has no question action mention" {
    try testing.expect(std.mem.indexOf(u8, mod.prompt_single, "```question") == null);
}

test "every prompt rule states action body is verbatim — no escaping" {
    const all = [_][]const u8{ mod.prompt_single, mod.prompt_dialog, mod.prompt_auto, mod.prompt_chat };
    for (all) |p| {
        try testing.expect(std.mem.indexOf(u8, p, "no escaping") != null);
    }
}
