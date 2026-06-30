---
layout: default
title: security_guard module
module_default: false
permalink: /modules/security_guard/
---

# `security_guard` module

![atty security_guard: the in-proc Tier-1 classifier flags a `curl … | sh` remote-fetch-and-execute and arms a [y]/[a]/[t]/[B] banner before it runs — no daemon required]({{ '/assets/atty-security-guard.gif' | relative_url }})

A second module in the guardrail family. Where [`guardrail`]({{ '/modules/' | relative_url }}#minimal-example--upper) matches a comptime list of patterns with a fixed `confirm`/`block`/`warn` behaviour, `security_guard` aims at supply-chain / drive-by-install shapes (`curl … | sh`, `npm install <flagged-pkg>`, `bash -c "<long-b64>"`) and is engineered for opt-in plus a tightening V2 path:

| Layer  | What runs                                                                            |
|--------|--------------------------------------------------------------------------------------|
| V1     | In-proc Tier-1 patterns + per-user SHA-256 trust cache. `[y]es / [t]rust / cancel`.  |
| V2-A   | `atty-guard` Rust sidecar mirrors Tier-1; gains in-mem PID → ThreatLevel map.        |
| V2-D   | atty queries the sidecar over UDS before its own in-proc patterns. Graceful fallback.|
| V2-E   | `atty-guard/contrib/install.sh` + hardened `atty-guard.service` system daemon.       |
| V2-C   | Pluggable Tier-2: `--tier2 stub|heuristic|onnx` (regex / heuristic / ONNX SLM).      |
| V2-B   | eBPF LSM hook (`bprm_check_security`) + execve + AF_ALG tracepoints — shipped.       |
| V2-G/H/I | AtomMatcher (Aho-Corasick) + sliding window + atom fetcher (GTFOBins / sanitized Sigma). |
| V2-J   | Threat-level accumulator: independent-probability combine across Tier-1 + Tier-2.    |
| V2-J-2 | Opt-in auto-Block escalation. Daemon-`Block` verdict triggers a red `REFUSED` line + clears readline atty-side (no prompt). |

Default: disabled. Opt in via:

```zig
pub const modules = .{
    atty.modules.security_guard.configure(.{ .enabled = true }),
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{}),
};
```

Optional sidecar (after `atty-guard/contrib/install.sh`):

```zig
.security_guard.configure(.{
    .enabled = true,
    .daemon_socket_path = "/run/atty-guard/atty-guard.sock",
}),
```

The daemon runs as a system service under `atty:atty`. Your user account must be in the `atty` group to connect:

```sh
sudo usermod -aG atty $USER
# log out + back in (or `newgrp atty` for a single shell)
```

## Block-refuse path (V2-J-2)

When the daemon returns `Verdict::Block` — either via the auto-Block escalation knob (`[accumulator] block_threshold = 0.95` in TOML) or because the PID-tree threat map says this PID is already Critical — atty does NOT prompt. It writes a one-shot `REFUSED — <reason>` line styled by `Config.refused_style` (bold red 8-color default), marks the shell PID Critical, and clears readline (Ctrl+U). Trust-cache hits short-circuit BOTH the Warn-prompt path and the Block-refuse path so prior `[t]rust` choices survive.

## Warn-mode overlay

When the daemon runs `--ebpf-mode=warn`, daemon-side `Block` verdicts emit kernel ringbuf events (no EPERM) instead of killing the execve. atty's `WarnSubscriber` buffers them; the statusbar shows `⚠ N` and `Alt+Shift+W` dumps the buffer into scrollback + clears it (see [Operator workflow]({{ '/operator-workflow/' | relative_url }}#warn-mode---ebpf-modewarn)).

## See also

- [Architecture]({{ '/architecture/' | relative_url }}) — proxy + module dispatch + statusbar
- [Operator workflow]({{ '/operator-workflow/' | relative_url }}) — install path, atom corpus, eBPF setup
- [Writing a module]({{ '/modules/' | relative_url }}) — framework docs for hooks + module-tuple composition
- Source: [`src/modules/security_guard/`](https://github.com/fentas/atty/tree/master/src/modules/security_guard)
- Daemon: [`atty-guard/`](https://github.com/fentas/atty/tree/master/atty-guard)
