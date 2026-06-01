---
layout: default
title: mouse_urls module
module_default: false
permalink: /modules/mouse_urls/
---

# `mouse_urls` module — click a URL → opener with a trust gate

Sibling of [`mouse_links`]({{ '/modules/mouse_links/' | relative_url }}) for URLs. Detects `https://`, `http://`, `ftp(s)://`, `ssh://`, `git://`, `file://` with path / query / fragment / userinfo / IPv6 literals.

Rejects:
- URLs without a host (`file:///etc/passwd`)
- URLs in unknown schemes (`javascript://`)
- Emails

Default opener is `xdg-open`; spawn uses a double-fork + `setsid` so atty doesn't accumulate zombies.

## Trust modes

| Mode | Behaviour |
|---|---|
| `.never` | Click is a no-op + status hint. Paranoid posture for shared / multi-tenant hosts. |
| `.whitelist_only` (default) | Opens if host matches `url_whitelist` (exact or `*.example.com` suffix) OR a host previously session-trusted via `.ask_each`. Silent + hint otherwise. The session-trust set is never populated in this mode itself — only the static `url_whitelist` adds. |
| `.ask_each` | Banner `open <host>? [y]es / [a]llow / [t]rust / cancel`. `[a]` session-trusts; `[t]` session-trusts AND surfaces `sudo atty-guard urls allow <host>` guidance (the daemon's `urls_allow` RPC requires EUID 0, so atty can't write it directly). |

## Ordering

Place `mouse_urls` BEFORE `guardrail` in the modules tuple so the banner's `y`/`a`/`t` keystrokes beat guardrail's own armed-banner consumption:

```zig
pub const mouse: atty.Mouse = .{ .enabled = true };

pub const modules = .{
    atty.modules.mouse_urls.configure(.{
        .mode = .ask_each,
        .url_whitelist = &.{ "github.com", "*.github.com", "docs.zig.dev" },
    }),
    atty.modules.mouse_links.configure(.{}),
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{}),
};
```

## See also

- [`mouse_links`]({{ '/modules/mouse_links/' | relative_url }}) — sibling for file-path clicks
- [Writing a module]({{ '/modules/' | relative_url }}) — framework docs
- Source: [`src/modules/mouse_urls/`](https://github.com/fentas/atty/tree/master/src/modules/mouse_urls)
