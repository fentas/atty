---
layout: default
title: mouse_links module
module_default: false
permalink: /modules/mouse_links/
---

# `mouse_links` module — click a file path → `$EDITOR <path>`

Wires a left-click on a path token in compiler / grep / ls output to a `$EDITOR +LINE 'path'\n` injection into the shell's input stream. Captures terminal output into a per-module ring (SGR + OSC stripped), maps screen (row, col) → captured row via a monotonic write counter, and uses the pure path detector at [`src/modules/mouse_links/path_detect.zig`](https://github.com/fentas/atty/blob/master/src/modules/mouse_links/path_detect.zig).

Detected path shapes:
- `:LINE` and `:LINE:COL` suffixes (compiler-error format)
- `~/`, `./`, `../` prefixes
- Quoted paths with internal spaces (`"src/with space/x.md":5`)
- Bracket wrappers (matched `( [ < {`)
- Common compiler punctuation (`,`, `.`, `;`, `:` after the path)
- Known bare filenames (`Makefile`, `README.md`, `Cargo.toml`, etc.)

## Trust posture

`$EDITOR` is trusted: the shell tokenises the injection so `EDITOR="code --wait"` works while `EDITOR="vim ; rm -rf"` is the user's footgun. Streaming-line capture only — TUIs like vim / htop run in the alt-screen where atty's mouse intercept is gated off (the shell owns input).

## Configuration

Requires `mouse.enabled = true` in the user's config to pull the proxy's SGR-1006 click stream:

```zig
pub const mouse: atty.Mouse = .{ .enabled = true };

pub const modules = .{
    atty.modules.mouse_links.configure(.{}),
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{}),
};
```

## See also

- [`mouse_urls`]({{ '/modules/mouse_urls/' | relative_url }}) — sibling for URL clicks
- [Writing a module]({{ '/modules/' | relative_url }}) — framework docs
- Source: [`src/modules/mouse_links/`](https://github.com/fentas/atty/tree/master/src/modules/mouse_links)
