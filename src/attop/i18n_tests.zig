const std = @import("std");
const testing = std.testing;
const i18n = @import("i18n.zig");
const home = @import("home.zig");
const uds = @import("uds.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

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

test "resolve honors env precedence (ATTOP_LANG > LC_ALL > LANG)" {
    defer {
        _ = unsetenv("ATTOP_LANG");
        _ = unsetenv("LC_ALL");
        _ = unsetenv("LANG");
    }
    _ = unsetenv("ATTOP_LANG");
    _ = unsetenv("LC_ALL");

    // LANG only (full locale → prefix).
    _ = setenv("LANG", "de_DE.UTF-8", 1);
    try testing.expectEqualStrings(i18n.de.protected, i18n.resolve().protected);

    // LC_ALL overrides LANG (POSIX).
    _ = setenv("LC_ALL", "en_US.UTF-8", 1);
    try testing.expectEqualStrings(i18n.en.protected, i18n.resolve().protected);

    // ATTOP_LANG overrides both, and accepts a full locale too.
    _ = setenv("ATTOP_LANG", "de_DE.UTF-8", 1);
    try testing.expectEqualStrings(i18n.de.protected, i18n.resolve().protected);

    // An unsupported locale falls back to English.
    _ = setenv("ATTOP_LANG", "fr", 1);
    try testing.expectEqualStrings(i18n.en.protected, i18n.resolve().protected);
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
