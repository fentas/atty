---
layout: default
title: guardrail module
permalink: /modules/guardrail/
module_default: true
---

# `guardrail` module
{:.no_toc}

> **Status:** enabled by default. Source: [`src/modules/guardrail.zig`](https://github.com/fentas/atty/blob/master/src/modules/guardrail.zig)

Confirmation prompt for dangerous commands.

* TOC
{:toc}

### How it works

When the user presses Enter:

1. Match the current line against a configurable rule list. Each rule
   carries a `Match` (substring / prefix / glob), an `AuthorMask`
   (user / llm gate), and a `Behavior` (`.confirm`, `.confirm_once`,
   `.block`, `.warn`).
2. First matching rule wins, in declaration order.
3. `.confirm` swallows the Enter, prints a banner, enters "armed"
   state. Next Enter passes through; non-Enter keystroke disarms.
4. `.confirm_once` works like `.confirm` but the confirmation
   persists for the rest of the session (per rule).
5. `.block` replaces the Enter with Ctrl+U (clears the typed line)
   and prints a banner; the command can never run.
6. `.warn` prints a banner and forwards the Enter — useful when you
   want an audit trail without friction.

The banner tags the author: `atty guardrail: <reason> [user|llm]`.

### Default rules

Author-aware: model-suggested destructive commands are stricter than
user-typed ones. The exact root-path `rm -rf /` and the classic fork
bomb are `.block` for both authors. Most others differentiate:

| Pattern                       | User behavior | LLM behavior |
|-------------------------------|---------------|--------------|
| `rm -rf /` (exact glob)       | `.block`      | `.block`     |
| `:(){ :&#124;:& };:` (substring) | `.block`   | `.block`     |
| `rm -rf ~` (substring)        | `.confirm`    | `.block`     |
| `rm -rf` (substring)          | `.confirm`    | `.block`     |
| `sudo mkfs` (prefix)          | `.confirm` †  | `.block`     |
| `sudo dd ` (prefix)           | `.confirm` †  | `.block`     |
| `sudo ` (prefix)              | `.confirm`    | `.confirm`   |
| `mkfs` (prefix)               | `.confirm`    | `.block`     |
| `dd ` (prefix)                | `.confirm`    | `.block`     |
| `&#124; sh` (substring)       | `.confirm`    | `.confirm`   |
| `&#124; bash` (substring)     | `.confirm`    | `.confirm`   |
| `chmod 777 /` (substring)     | `.confirm`    | `.confirm`   |

† User-typed `sudo mkfs …` / `sudo dd …` match the explicit user rules
no earlier than the generic `sudo` rule (which also `.confirm`s), so
the visible behavior is the same; the explicit `sudo-mkfs-llm` /
`sudo-dd-llm` rules exist to shadow the generic `sudo` rule for the
LLM path under first-match-wins ordering.

### Custom rules

Two knobs:

- **`extra_rules`** — your rules are *prepended* to whatever
  `rules` resolves to (defaults to the shipped `default_rules`).
  Under first-match-wins your entries check first, so this is the
  right place to declare stricter overrides (`.block` a pattern the
  defaults only `.confirm`) or whitelists (a `.warn` rule that
  matches before the default `.block` would). Empty default = use
  `rules` only. **Use this for the common "I just want to add a
  couple more rules" case.**
- **`rules`** — full replacement list. Defaults to the shipped
  `default_rules`. Set this when you want a minimal custom policy
  tailored to your environment and explicitly *not* the defaults.
  Setting both `rules` and `extra_rules` is supported (extras
  prepend to your custom list).

```zig
// Common case: extend the defaults.
pub const Guardrail = atty.modules.guardrail.configure(.{
    .extra_rules = &.{
        .{
            // user-only — without the explicit mask this would also
            // match llm-authored commits, and because first-match
            // wins, the llm-only block below would be unreachable.
            .name = "git-force-push-user",
            .match = .{ .substring = "git push --force" },
            .reason = "force-pushing to a shared branch",
            .authors = .{ .user = true, .llm = false },
            .behavior = .confirm_once,
        },
        .{
            .name = "git-force-push-llm",
            .match = .{ .substring = "git push --force" },
            .reason = "force-pushing (llm)",
            .authors = .{ .user = false, .llm = true },
            .behavior = .block,
        },
    },
    .warning_style = atty.style.presets.danger,   // bold red
});

// Rare case: replace defaults entirely.
pub const MinimalGuardrail = atty.modules.guardrail.configure(.{
    .rules = &.{
        .{ .name = "rm-rf-root",
           .match = .{ .glob = "rm -rf /" },
           .reason = "rm -rf on root",
           .behavior = .block },
    },
});
```

`warning_style` takes an `atty.Style` — same type the ghost overlay
uses, so a single palette can drive the whole proxy. Default style
is `.{ .dim = true, .italic = true }`.

### Limitations

- The match runs against our line model, which approximates what
  the user typed. **Vi-mode `hjkl` navigation desyncs the model
  silently** — atty doesn't see the vi-mode/insert-mode distinction
  on stdin (`hjkl` are plain printable bytes), so the line model
  appends them while the shell's readline treats them as cursor
  moves and emits `\x1b[D` / `\x1b[B` / `\x1b[A` / `\x1b[C` back
  through the master fd. OSC 133 sync doesn't recover this either
  because the `syncFromCapture` gate requires either the line
  model to be `uncertain` or the captured input to be at least
  as long as the model — neither holds in this case.
  Practical consequence: in vi-normal navigation, the guardrail's
  matcher reads a partially-wrong buffer; pathological typed
  content (substring matching a tripwire pattern that the user
  never actually executed) could trigger a false positive on
  Enter. The conservative fix would be probing `set -o` at attach
  to detect vi-mode + short-circuit guardrail there; currently
  it's a documented edge case.
- Substring matches are literal — there's no regex engine. If you
  need one, write a new module; do **not** add it here. A
  pathological regex on the input hot path would be a strict
  regression.

