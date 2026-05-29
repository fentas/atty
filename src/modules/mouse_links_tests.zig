//! Integration tests for `modules/mouse_links.zig`. Exercises the
//! output ring (ingest + SGR strip + click→row mapping) and the
//! onMouseClick → pollShellInput pipeline.

const std = @import("std");
const testing = std.testing;
const mod = @import("mouse_links.zig");
const m = @import("../module.zig");
const mouse = @import("../mouse.zig");
const dispatch = @import("../dispatch.zig");
const LineState = @import("../line_state.zig").LineState;

const configure = mod.configure;
const Config = mod.Config;

const test_io: std.Io = std.Io.failing;

test {
    _ = @import("mouse_links/path_detect.zig");
    _ = @import("mouse_links/inject.zig");
}

fn makeCtx(line: *LineState, scratch: *std.ArrayList(u8), term_rows: ?u16, term_cols: ?u16) m.Context {
    return .{
        .allocator = testing.allocator,
        .io = test_io,
        .line = line,
        .scratch = scratch,
        .is_tty = true,
        .terminal_rows = term_rows,
        .terminal_cols = term_cols,
    };
}

test "ingest captures plain lines and click resolves to path" {
    const Mod = configure(.{ .editor = "nvim" });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch, 24, 80);

    try Mod.onOutput(&rt, &ctx, "error here\nsrc/foo.zig:42: oops\n");

    // current_row == 2 after two \n's. visible_top = 0 (no scroll yet),
    // so click_row=2 → logical row 1 (the src/foo.zig line).
    const click: mouse.Event = .{
        .button = .left,
        .kind = .press,
        .col = 5,
        .row = 2,
        .mods = .{},
    };
    const act = try Mod.onMouseClick(&rt, &ctx, click);
    try testing.expectEqual(dispatch.MouseAction.consume, act);

    const payload = (try Mod.pollShellInput(&rt, &ctx)).?;
    try testing.expectEqualStrings("\x15nvim +42 'src/foo.zig'\n", payload);

    // Subsequent poll returns null.
    try testing.expect((try Mod.pollShellInput(&rt, &ctx)) == null);
}

test "SGR sequences are stripped before path detection" {
    const Mod = configure(.{ .editor = "vi" });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch, 24, 80);

    // Compiler error in bold red, then reset.
    try Mod.onOutput(&rt, &ctx, "\x1b[1;31msrc/foo.zig:7\x1b[0m: error\n");

    const click: mouse.Event = .{
        .button = .left,
        .kind = .press,
        .col = 3,
        .row = 1,
        .mods = .{},
    };
    const act = try Mod.onMouseClick(&rt, &ctx, click);
    try testing.expectEqual(dispatch.MouseAction.consume, act);

    const payload = (try Mod.pollShellInput(&rt, &ctx)).?;
    try testing.expectEqualStrings("\x15vi +7 'src/foo.zig'\n", payload);
}

test "non-left button is passthrough" {
    const Mod = configure(.{ .editor = "vi" });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch, 24, 80);
    try Mod.onOutput(&rt, &ctx, "src/foo.zig\n");

    for ([_]mouse.Button{ .right, .middle, .wheel_up, .wheel_down }) |btn| {
        const click: mouse.Event = .{
            .button = btn,
            .kind = .press,
            .col = 3,
            .row = 1,
            .mods = .{},
        };
        try testing.expectEqual(
            dispatch.MouseAction.passthrough,
            try Mod.onMouseClick(&rt, &ctx, click),
        );
    }
}

test "drag and release are passthrough" {
    const Mod = configure(.{ .editor = "vi" });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch, 24, 80);
    try Mod.onOutput(&rt, &ctx, "src/foo.zig\n");

    for ([_]mouse.Kind{ .drag, .release }) |k| {
        const click: mouse.Event = .{
            .button = .left,
            .kind = k,
            .col = 3,
            .row = 1,
            .mods = .{},
        };
        try testing.expectEqual(
            dispatch.MouseAction.passthrough,
            try Mod.onMouseClick(&rt, &ctx, click),
        );
    }
}

test "click on row with no path is passthrough" {
    const Mod = configure(.{ .editor = "vi" });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch, 24, 80);
    try Mod.onOutput(&rt, &ctx, "no path here\n");

    const click: mouse.Event = .{
        .button = .left,
        .kind = .press,
        .col = 3,
        .row = 1,
        .mods = .{},
    };
    try testing.expectEqual(
        dispatch.MouseAction.passthrough,
        try Mod.onMouseClick(&rt, &ctx, click),
    );
}

test "click respects statusbar reserve area" {
    const Mod = configure(.{ .editor = "vi" });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = test_io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = true,
        .terminal_rows = 24,
        .terminal_cols = 80,
        .statusbar_reserve = 2,
    };
    try Mod.onOutput(&rt, &ctx, "src/foo.zig\n");

    // Click on the bottom-most row (24) is in the reserved area
    // — should be passthrough even though a path was captured.
    const click_in_reserve: mouse.Event = .{
        .button = .left,
        .kind = .press,
        .col = 3,
        .row = 24,
        .mods = .{},
    };
    try testing.expectEqual(
        dispatch.MouseAction.passthrough,
        try Mod.onMouseClick(&rt, &ctx, click_in_reserve),
    );

    // Click on the path's row (1) is OK.
    const click_on_path: mouse.Event = .{
        .button = .left,
        .kind = .press,
        .col = 3,
        .row = 1,
        .mods = .{},
    };
    try testing.expectEqual(
        dispatch.MouseAction.consume,
        try Mod.onMouseClick(&rt, &ctx, click_on_path),
    );
}

test "no terminal_rows in ctx is passthrough" {
    const Mod = configure(.{ .editor = "vi" });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch, null, null);
    try Mod.onOutput(&rt, &ctx, "src/foo.zig\n");

    const click: mouse.Event = .{
        .button = .left,
        .kind = .press,
        .col = 3,
        .row = 1,
        .mods = .{},
    };
    try testing.expectEqual(
        dispatch.MouseAction.passthrough,
        try Mod.onMouseClick(&rt, &ctx, click),
    );
}

test "CR followed by shorter content truncates the stale tail" {
    // Locks the line_lens=new_col (overwrite) semantics — high-water-mark
    // would leak `wrongABC` → `xyzgABC` after `\r`.
    const Mod = configure(.{ .editor = "nvim" });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch, 24, 80);

    // `wrongabcdef` then CR back to start, then write `src/y.zig` (9
    // bytes, shorter than the 11 written before CR). The captured row
    // must be exactly `src/y.zig`, not `src/y.zigef`.
    try Mod.onOutput(&rt, &ctx, "wrongabcdef\rsrc/y.zig\n");

    const click: mouse.Event = .{
        .button = .left,
        .kind = .press,
        .col = 3,
        .row = 1,
        .mods = .{},
    };
    const act = try Mod.onMouseClick(&rt, &ctx, click);
    try testing.expectEqual(dispatch.MouseAction.consume, act);
    const payload = (try Mod.pollShellInput(&rt, &ctx)).?;
    try testing.expectEqualStrings("\x15nvim 'src/y.zig'\n", payload);
}

test "CR resets col within a row, BS rewinds one cell" {
    const Mod = configure(.{ .editor = "nvim" });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch, 24, 80);

    // Type "wrong", CR back to start, overwrite "src/x", then BS+y.
    try Mod.onOutput(&rt, &ctx, "wrong\rsrc/x\x08y.zig\n");

    const click: mouse.Event = .{
        .button = .left,
        .kind = .press,
        .col = 3,
        .row = 1,
        .mods = .{},
    };
    const act = try Mod.onMouseClick(&rt, &ctx, click);
    try testing.expectEqual(dispatch.MouseAction.consume, act);

    const payload = (try Mod.pollShellInput(&rt, &ctx)).?;
    try testing.expectEqualStrings("\x15nvim 'src/y.zig'\n", payload);
}

test "scrolled output — visible window maps to recent rows" {
    const Mod = configure(.{ .editor = "nvim", .ring_rows = 64 });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch, 24, 80);

    // 30 filler lines, then a path, then 22 more filler lines.
    // After 53 \n's: current_row=53. term_rows=24 → visible top is
    // logical row 30 (53 - 24 + 1 = 30). The path was emitted at
    // logical row 30. Click row 1 should map to it.
    var i: usize = 0;
    while (i < 30) : (i += 1) try Mod.onOutput(&rt, &ctx, "filler\n");
    try Mod.onOutput(&rt, &ctx, "src/scrolled.zig:99\n");
    i = 0;
    while (i < 22) : (i += 1) try Mod.onOutput(&rt, &ctx, "filler\n");

    const click: mouse.Event = .{
        .button = .left,
        .kind = .press,
        .col = 5,
        .row = 1,
        .mods = .{},
    };
    const act = try Mod.onMouseClick(&rt, &ctx, click);
    try testing.expectEqual(dispatch.MouseAction.consume, act);

    const payload = (try Mod.pollShellInput(&rt, &ctx)).?;
    try testing.expectEqualStrings("\x15nvim +99 'src/scrolled.zig'\n", payload);
}

test "pending injection blocks subsequent clicks until drained" {
    const Mod = configure(.{ .editor = "vi" });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch, 24, 80);
    try Mod.onOutput(&rt, &ctx, "src/a.zig\nsrc/b.zig\n");

    const click_a: mouse.Event = .{ .button = .left, .kind = .press, .col = 3, .row = 1, .mods = .{} };
    try testing.expectEqual(dispatch.MouseAction.consume, try Mod.onMouseClick(&rt, &ctx, click_a));

    // Second click while first is pending: passthrough (don't
    // overwrite the queued command).
    const click_b: mouse.Event = .{ .button = .left, .kind = .press, .col = 3, .row = 2, .mods = .{} };
    try testing.expectEqual(dispatch.MouseAction.passthrough, try Mod.onMouseClick(&rt, &ctx, click_b));

    // Drain.
    const payload = (try Mod.pollShellInput(&rt, &ctx)).?;
    try testing.expectEqualStrings("\x15vi 'src/a.zig'\n", payload);

    // Now a click works again.
    try testing.expectEqual(dispatch.MouseAction.consume, try Mod.onMouseClick(&rt, &ctx, click_b));
    const second = (try Mod.pollShellInput(&rt, &ctx)).?;
    try testing.expectEqualStrings("\x15vi 'src/b.zig'\n", second);
}

test "OSC sequences are stripped" {
    const Mod = configure(.{ .editor = "vi" });
    var rt = try Mod.attach(testing.allocator, test_io);
    defer Mod.detach(&rt, test_io);

    var line = LineState{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = makeCtx(&line, &scratch, 24, 80);

    // OSC 8 hyperlink syntax around a path.
    try Mod.onOutput(&rt, &ctx, "\x1b]8;;file:///src/foo.zig\x07src/foo.zig\x1b]8;;\x07\n");

    const click: mouse.Event = .{ .button = .left, .kind = .press, .col = 3, .row = 1, .mods = .{} };
    const act = try Mod.onMouseClick(&rt, &ctx, click);
    try testing.expectEqual(dispatch.MouseAction.consume, act);

    const payload = (try Mod.pollShellInput(&rt, &ctx)).?;
    try testing.expectEqualStrings("\x15vi 'src/foo.zig'\n", payload);
}
