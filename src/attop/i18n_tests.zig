const std = @import("std");
const testing = std.testing;
const i18n = @import("i18n.zig");
const home = @import("home.zig");
const uds = @import("uds.zig");

test "byLang maps en/de + rejects unknown" {
    try testing.expect(i18n.byLang("en") != null);
    try testing.expect(i18n.byLang("de") != null);
    try testing.expect(i18n.byLang("fr") == null);
}

test "langPrefix extracts the language code" {
    try testing.expectEqualStrings("de", i18n.langPrefix("de_DE.UTF-8"));
    try testing.expectEqualStrings("en", i18n.langPrefix("en"));
    try testing.expectEqualStrings("C", i18n.langPrefix("C"));
    try testing.expectEqualStrings("pt", i18n.langPrefix("pt_BR"));
    try testing.expectEqualStrings("de", i18n.langPrefix("de.UTF-8"));
}

test "the active locale drives the rendered prose" {
    const prev = i18n.active;
    defer i18n.active = prev; // isolate: other tests expect the en default
    const m = uds.Metrics{ .guard = .{ .profile = "session" } }; // protected

    i18n.active = i18n.de;
    var buf: [4096]u8 = undefined;
    const d = home.renderHome(&buf, m, 120, 40);
    try testing.expect(std.mem.indexOf(u8, d, "Gesch\u{00FC}tzt") != null); // Geschützt
    try testing.expect(std.mem.indexOf(u8, d, "Protected") == null);

    i18n.active = i18n.en;
    var buf2: [4096]u8 = undefined;
    const e = home.renderHome(&buf2, m, 120, 40);
    try testing.expect(std.mem.indexOf(u8, e, "Protected") != null);
}
