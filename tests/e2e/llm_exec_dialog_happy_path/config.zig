//! llm_exec_dialog_happy_path — Alt+S drives a multi-turn dialog
//! against a fixture LLM. First fixture reply suggests a command
//! that emits OSC 133 `;C` / `;D` markers inline (so the e2e
//! harness doesn't need DEBUG-trap shell integration to observe
//! the cmd_start / cmd_end edges). Second reply ends the loop
//! with `action=done`.
//!
//! Pins the full state-machine walk: idle → generating →
//! suggesting → executing → capturing_output → observation_ready
//! → generating → done. Without this scenario the dialog loop
//! could rot silently across refactors — JSON shapes, OSC 133
//! edge handling, and the FIFO turn buffer all converge here.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.llm.configure(.{
        // Inert HTTP — fixture path bypasses doRequest entirely.
        // Set a non-empty api_base so the inert-mode guard doesn't
        // short-circuit Alt+S; the fixture cursor kicks in inside
        // the worker before any HTTP call.
        .api_base = "http://localhost:0",
        .model = "fixture-model",
        .fixture_responses = &.{
            // Step 1: exec a command that emits ;C + "ok" + ;D
            // inline via printf, so OSC 133 capture has something
            // to observe even though the shell itself isn't fully
            // OSC-133-integrated. JSON `\\033` decodes to a literal
            // backslash; bash + printf then interpret `\033` as ESC
            // at execution time. During the shell echo of the typed
            // line, atty sees literal characters (no raw ESC), so
            // the markers only fire after printf runs.
            \\{"action":"exec","command":"printf '\\033]133;C\\007ok\\033]133;D;0\\007'","description":"emit ok with markers"}
            ,
            // Step 2: ;D fired → onTick pushes observation + fires
            // a follow-up request → fixture returns done → dialog
            // resets, "✓ done" hint latches above the bar.
            \\{"action":"done","reason":"all set"}
            ,
        },
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
