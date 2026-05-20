---
layout: default
title: LLM module
---

# LLM module — `#: <prompt>` for shell-command generation
{:.no_toc}

* TOC
{:toc}

Type `#: list all .zig files modified in the last week` at the
shell prompt and press **`Alt+A`**. atty wipes the typed line and
injects the LLM-generated command into the readline buffer. You
hit Enter to actually run it (or edit it / `Ctrl+C` to discard).

Three action keys, each with its own follow-up flow:

| Key           | Mode                                   |
|---------------|----------------------------------------|
| `Alt+A`       | single command, no follow-up           |
| `Alt+S`       | multi-turn dialog with OSC 133 capture |
| `Alt+Shift+S` | dialog + auto-submit each step         |

> **Why not `Enter`?** Pressing Enter on `#: …` is a **no-op by
> default** (`enter_action = .none`) — defense against accidental
> LLM calls when you just want to type a comment. Set
> `Config.enter_action = .single` (or `.dialog` / `.auto`) to
> bring back the pre-Alt-key trigger flow if you preferred it.

## Quickstart

Add the module to your `src/config.zig` tuple and rebuild:

```zig
const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.atuin.configure(.{}),
    atty.modules.history.configure(.{}),
    atty.modules.llm.configure(.{
        .provider = .{ .http = .{ .api_base = "http://localhost:11434/v1" } },
        .model = "qwen3-coder",
    }),
};
```

That's enough for a local Ollama install — the module short-
circuits to inert mode (no worker thread spawned) when no
endpoint is configured, so the rest of your shell experience is
untouched.

### Or use Claude Code (`claude -p`)

If you have the Claude Code CLI installed and authenticated, swap
the HTTP provider for a subprocess provider — atty shells out per
request, the CLI handles auth out of its own login state, no env
vars to wire.

The fastest path is a preset:

```zig
.provider = atty.modules.llm.providers.claude_sonnet_4_6,
```

Available preset constants (all under `atty.modules.llm.providers`):

| Preset                 | Notes                                                            |
|------------------------|------------------------------------------------------------------|
| `claude_sonnet_4_5`    | Sonnet 4.5 — solid default for shell-command work.               |
| `claude_sonnet_4_6`    | Sonnet 4.6 — the current Sonnet recommended for most agent flows.|
| `claude_opus_4_7`      | Opus 4.7 — biggest model. Slower + pricier, best for hairy prompts. |
| `claude_haiku_4_5`     | Haiku 4.5 — small + cheap. Fast single-line `#:` flow.           |
| `claude_default`       | Let the CLI pick whichever model your `claude config` selected. |
| `openai`               | Hosted OpenAI (`https://api.openai.com/v1`, reads `$OPENAI_API_KEY`). Pair with `Config.model = "gpt-4o-mini"` or similar. |
| `ollama`               | Local Ollama on `localhost:11434` — same as the default HTTP behavior, exposed as a constant for symmetry. |

For something the presets don't cover, drop down to the factory:

```zig
.provider = atty.modules.llm.providers.claudeCode(.{
    .model = "claude-sonnet-4-6",
    .extra_argv = &.{ "--permission-mode", "acceptEdits" },
}),
```

The factory is shorthand for:

```zig
.provider = .{ .subprocess = .{
    .argv = &.{ "claude", "-p", "--output-format", "json", "--model", "claude-sonnet-4-6" },
    .prompt_via = .final_arg,
    .output = .{ .json_field = "result" },
    .timeout_ms = 60_000,
}},
```

Any prompt-in / text-out CLI follows the same pattern. For
[simonw/llm](https://github.com/simonw/llm):

```zig
.provider = .{ .subprocess = .{
    .argv = &.{ "llm", "-m", "gpt-4o-mini" },
    .prompt_via = .stdin,
    .output = .raw,
}},
```

## OSC 133 — required for dialog / auto modes

Dialog (`Alt+S`) and auto (`Alt+Shift+S`) modes need OSC 133
prompt markers so atty knows where command output begins / ends.
Single mode (`Alt+A`) works without them.

```sh
# in your ~/.bashrc:
eval "$(atty init bash)"

# or ~/.zshrc:
eval "$(atty init zsh)"
```

**Gotcha — `.bashrc` is load-bearing.** The init snippet does
`exec atty bash` at the top to re-launch your shell under atty.
`exec` **replaces** the current shell, so any function
definitions / `PROMPT_COMMAND` wiring the snippet ALSO sets are
discarded along with it. The canonical flow expects the new atty
bash to re-read `.bashrc` (interactive shells do), which re-runs
the eval; this time `ATTY=1` skips the exec and the OSC 133
setup applies in-place.

If you run `eval "$(atty init bash)"` **manually** from a fresh
shell without it in your rc, the new atty session won't have
OSC 133 hooks — you'll see the `exec mode needs OSC 133` error
on Alt+S. Two fixes:

1. Add the eval line to `.bashrc` (canonical), OR
2. After landing in the atty session, run `eval "$(atty init
   bash)"` **a second time** — `ATTY=1` is now set, exec gets
   skipped, OSC 133 setup runs in your current shell.

Sanity-check with `eval "$(atty doctor)"` — colour-coded
pass/fail for every step of the integration chain.

## How a prompt flows

1. **You type** `#: list zig files` then press **`Alt+A`**.
2. **`onAction`** in the module sees the `llm_exec_single`
   action, checks `ai_mode_active` (line starts with `#: `), and
   queues `\x15` (Ctrl+U) on `pending_injection`. The proxy
   drains that to the shell on the next `pollShellInput` tick,
   wiping the typed `#: …` text. (Setting
   `Config.enter_action = .single` re-binds the legacy
   `#:<Enter>` trigger to the same code path — same result,
   different entry point.)
3. **A worker thread** wakes on a condvar, POSTs to
   `${api_base}/chat/completions` with the prompt body, parses the
   `choices[0].message.content` from the response.
4. **`pollShellInput`** on the next tick surfaces the parsed
   command bytes. The proxy writes them to `pty.master` as if
   you'd typed them; readline echoes; you see the suggested
   command at the prompt.
5. **You review + hit Enter** (or edit, or Ctrl+C to discard).
   Normal shell behaviour from here on — the LLM module is out
   of the way.

When `with_explanation = true` (the default), the model also
emits a one-sentence summary of what the command does; atty
parses it out of the response and shows it in the statusbar's
hint row above the prompt.

## Endpoint resolution (HTTP provider)

When `Config.provider` is `.{ .http = ... }` (the default), the
endpoint is discovered in this priority order — first non-empty wins:

1. `Config.provider.http.api_base` (static, baked into your `config.zig`)
2. `$LLM_API_BASE` (env var; name configurable via
   `Config.provider.http.api_base_env`)
3. `$OLLAMA_HOST` (Ollama-native fallback; `/v1` is suffixed
   automatically if absent — Ollama's `/v1/*` mirror is
   OpenAI-compatible while its native API isn't)

The static form is the most robust because it doesn't depend on
shell-env state at fork time — a misconfigured `.bashrc` or a
launcher that strips env can leave the env-var paths silently
inert. With the static form, the endpoint is whatever your
compiled binary says it is.

Authentication: `$LLM_API_KEY` (name configurable via
`Config.provider.http.api_key_env`) becomes a `Bearer <key>`
header when set. Empty / unset → no `Authorization` header sent.

When `Config.provider` is `.{ .subprocess = ... }`, none of the
above applies — the CLI tool handles its own endpoint and auth.
atty just spawns it per request.

Trailing slashes are normalised on all three paths so
`http://localhost:11434/v1/` and `http://localhost:11434/v1` both
resolve cleanly.

## Context injection

`Config.context_env_vars` exposes additional env vars to the
model alongside the prompt. Each named var is read at attach time
and (if set, non-empty) joined into a one-line context block
appended to the user message:

```zig
atty.modules.llm.configure(.{
    .context_env_vars = &.{ "PATH_BASE", "PROJECT" },
}),
```

The model sees:

    Generate a bash command to: list zig files

    Context: PATH_BASE=/opt/foo, PROJECT=acme

Empty / unset env vars are skipped. The whole `Context:` line is
omitted when none of the named vars are set, so you don't get an
empty context dangling on the prompt.

CWD / git-root context isn't implemented yet — both need
child-PID tracking via `/proc/<shell_pid>/cwd` (or OSC 7) to
follow the shell as the user `cd`s, which is a separate piece of
infrastructure.

## Transparent failure — error notifications

Silent failure on a typed prompt is the worst possible UX — the
line vanishes and the user doesn't know whether the model is
slow, the endpoint is down, or atty was never going to handle it.
Every failure path latches an `error` notification (muted red +
⚠ glyph, above the status bar):

| Latched message                                        | Cause                                                                          |
|--------------------------------------------------------|--------------------------------------------------------------------------------|
| `no endpoint set — export $LLM_API_BASE or …`          | Module attached but `api_base` resolved empty. Synchronous, fires on `onInput`.|
| `request failed (endpoint unreachable?)`               | `client.fetch` errored — DNS, connect refused, network unreachable.            |
| `HTTP <status>`                                        | Endpoint responded with non-2xx. 404 commonly means the configured model name doesn't match anything served. |
| `couldn't extract a command from the response`         | HTTP 200 but the response shape didn't parse — the model returned only prose, only comments, or unparseable JSON. |

`Config.statusbar.error_ttl_ms` controls how long the
notification stays visible (60 s default). The hint slot (used
for explanations) is suppressed while an error is active and
resurfaces once the error TTL expires.

## Live signals while typing

While you're mid-typing a `#: …` prompt — before you hit Enter —
atty already knows the LLM is the route. Two signals fire on the
prefix match:

- **Cursor colour** (`prefix_signal_cursor`, `prefix_signal_cursor_color`):
  on the edge into match, atty emits OSC 12 to set the terminal
  cursor to the configured colour (cyan by default). On the edge
  out (backspace past the prefix, or line cleared after Enter),
  OSC 112 resets to default. All modern terminals honour OSC 12 /
  112 — Ghostty, kitty, iTerm, WezTerm, VS Code.
- **Status segment** (`prefix_signal_status`, `prefix_signal_status_text`):
  the module's `statusText` returns `✨ prompt` (configurable) in
  the bottom status bar while the prefix matches. Suppressed
  during an in-flight request — the `🧠 thinking…` indicator
  takes precedence.

Both are opt-out — set the bool config to `false` to disable.

## History integration

Because `onInput` returns `.replace_commit` (not plain
`.replace`), the proxy fires `dispatchLineCommit` on the typed
`#: list zig files` line. atuin and the bundled history module
both record it. Next time you start typing `#: l…`, ghost-suggest
surfaces your prior prompts the same way it surfaces any normal
command — Right / End / Ctrl+F to accept, multi-row pick list if
configured. Ctrl+Shift+D's `delete_history_match` works on the
prompt too.

## Chat surfaces

Two parallel UIs render the same conversation ring — pick the one that fits the moment.

- **`Alt+C` — inline chat panel.** Reserves N rows above the statusbar (default 10) for a slim chat strip. The shell stays visible above the panel; cursor focus moves into the panel's input row. For casual back-and-forth while still watching command output scroll above.
- **`Alt+Shift+C` — full chat overlay.** Takes over the screen via alt-screen swap. Bigger view of the conversation history, structured assistant rendering, more room. For focused review of long sessions.

Both share the same `turns[]` ring + dialog state, so an `action=exec` envelope returned while either surface is open injects the suggested command at the user's shell prompt. The two surfaces are mutually exclusive — opening one closes the other so cursor focus is unambiguous.

## Keybindings

Press **`Alt+H`** any time to scroll the full cheat-sheet into shell history. The shipped LLM bindings (registered on the module via `default_bindings`, so they only fire when the LLM module is enabled):

| Key             | Action                                                    |
|-----------------|-----------------------------------------------------------|
| `Alt+A`         | Single-shot prompt (one command, no dialog).              |
| `Alt+S`         | Dialog mode (multi-turn exec/observe loop).               |
| `Alt+Shift+S`   | Auto-exec (dialog + auto-confirm each step).              |
| `Alt+M`         | Cycle through `config.models`.                            |
| `Alt+C`         | Toggle inline chat panel.                                 |
| `Alt+Shift+C`   | Toggle full-screen chat overlay.                          |
| `Alt+H`         | Show this cheat-sheet (LLM-mode hint when in `#: `).      |
| `Ctrl+Shift+X`  | Cancel any active exec / dialog / auto.                   |

Override any of these by listing a different `bytes` for the same `action` in `Keymap.bindings` — the user list wins via first-match.

## Configuration reference

### Core

| Field                         | Default                                  | What it does                                                                          |
|-------------------------------|------------------------------------------|---------------------------------------------------------------------------------------|
| `prefix`                      | `"#: "`                                  | Trigger. `#` is a shell comment so missed dispatches are silent no-ops, not executed. |
| `model`                       | `"llama3:8b"`                            | Single-model fallback. Used when `models` is empty.                                   |
| `models`                      | `&.{}`                                   | List of `Model` structs (see below). `Alt+M` cycles through them.                     |
| `shell`                       | `null`                                   | Shell name for the user-prompt template. `null` → basename of `$SHELL`.               |
| `provider`                    | `.{ .http = .{} }`                       | Transport: `.http` (OpenAI-compatible) or `.subprocess` (CLI tool). See below.        |
| `with_explanation`            | `true`                                   | Ask model for an explanation + fenced command; show explanation in the hint row.      |
| `system_prompt`               | `""`                                     | Override the canned system prompt. Empty → canned prompt for the `with_explanation` mode. |
| `dialog_system_prompt`        | `""`                                     | Override the dialog-mode JSON-envelope system prompt. Empty → canned.                  |
| `context_env_vars`            | `&.{}`                                   | Env vars whose values get appended to the user message as `Context: KEY=value, …`.    |
| `enter_action`                | `.none`                                  | What Enter on `#: …` does. `.none` (default), `.single`, `.dialog`, `.auto`.          |
| `auto_delay_ms`               | `800`                                    | Auto-exec confirm delay (ms) for `Alt+Shift+S`. Any keystroke aborts.                 |
| `history_turns_max`           | `8`                                      | Ring capacity. The model sees at most this many recent turns per request.             |
| `dialog_parse_retry_max`      | `2`                                      | How many times atty re-prompts the model when a JSON envelope fails to parse.         |

### Provider — HTTP variant fields

Available as `Config.provider.http.<field>`:

| Field                         | Default            | What it does                                                                          |
|-------------------------------|--------------------|---------------------------------------------------------------------------------------|
| `api_base`                    | `""`               | Static endpoint URL. Wins over env vars when non-empty.                               |
| `api_base_env`                | `"LLM_API_BASE"`   | Env-var name for the primary endpoint.                                                |
| `api_base_fallback_env`       | `"OLLAMA_HOST"`    | Env-var name for the Ollama-native fallback (`/v1` auto-suffixed).                    |
| `api_key_env`                 | `"LLM_API_KEY"`    | Env-var name for the optional `Authorization: Bearer …` token.                        |

### Provider — subprocess variant fields

Available as `Config.provider.subprocess.<field>`:

| Field          | Default        | What it does                                                                                   |
|----------------|----------------|------------------------------------------------------------------------------------------------|
| `argv`         | (required)     | Program + leading args. atty appends the rendered prompt as the final argv slot (default).     |
| `prompt_via`   | `.final_arg`   | `.final_arg` = append prompt to argv; `.stdin` = pipe prompt via stdin (close stdin = EOF).    |
| `output`       | `.raw`         | `.raw` = stdout text IS the response; `.{ .json_field = "name" }` = parse stdout as JSON, take the named top-level string field. |
| `timeout_ms`   | `30_000`       | Wall-clock timeout (currently advisory — enforcement lands in a follow-up).                    |

The `atty.modules.llm.providers.claudeCode(...)` factory returns a
pre-shaped subprocess provider for `claude -p --output-format
json`.

### Chat surfaces

| Field                         | Default                                  | What it does                                                                          |
|-------------------------------|------------------------------------------|---------------------------------------------------------------------------------------|
| `inline_chat_rows`            | `10`                                     | Rows the Alt+C inline panel claims above the statusbar. Minimum 3 (comptime-checked). |
| `overlay_open_policy`         | `.notify`                                | What to do when the model emits `"open_chat": true`. `.always` / `.notify` / `.never`. |

### Persistence — survive across sessions

| Field                         | Default                                  | What it does                                                                          |
|-------------------------------|------------------------------------------|---------------------------------------------------------------------------------------|
| `chat_persist_enabled`        | `false`                                  | Master switch. Default off — chat lives in RAM only.                                  |
| `chat_persist_path`           | `""`                                     | NDJSON file path. Empty + enabled → `${XDG_DATA_HOME}/atty/chat.jsonl` (fallback `${HOME}/.local/share/atty/chat.jsonl`); parent directory is auto-created. |
| `chat_persist_max_bytes`      | `0`                                      | Soft cap. When the file grows past this, atty rewrites it tail-truncated at a line boundary (atomic tmp+rename) on the next append. `0` disables rotation. |

### Visual signals

| Field                         | Default                                  | What it does                                                                          |
|-------------------------------|------------------------------------------|---------------------------------------------------------------------------------------|
| `prefix_signal_cursor`        | `true`                                   | Emit OSC 12 / 112 cursor-colour transitions while prefix matches.                     |
| `prefix_signal_cursor_color`  | `"cyan"`                                 | OSC 12 colour. Named (`cyan`) or `#RRGGBB` / `rgb:RR/GG/BB`.                           |
| `prefix_signal_status`        | `true`                                   | Show `prefix_signal_status_text` in the status bar while prefix matches.              |
| `prefix_signal_status_text`   | `"✨ prompt"`                            | Status-bar text shown during a prefix match.                                          |

### Buffer sizes (tune for big models)

| Field                         | Default                                  | What it does                                                                          |
|-------------------------------|------------------------------------------|---------------------------------------------------------------------------------------|
| `timeout_ms`                  | `30_000`                                 | Stored; not yet wired into `client.fetch` (deferred to a follow-up).                  |
| `max_response_bytes`          | `4096`                                   | Cap on the parsed command size.                                                       |
| `max_prompt_bytes`            | `2048`                                   | Cap on prompt-body size. Longer inputs ignored as "likely paste, not a task."         |
| `max_turn_bytes`              | `4096`                                   | Cap on the bytes stored per ring entry. Longer turns truncate.                        |

### `Model` struct (entries in `models`)

```zig
.models = &.{
    .{ .name = "qwen3-coder:30b" },
    .{ .name = "gemma3:4b", .history_turns_max = 3 },  // small-context trim
    .{ .name = "llama3:70b" },
},
```

| Field                | Default  | What it does                                                                       |
|----------------------|----------|------------------------------------------------------------------------------------|
| `name`               | required | Model identifier sent in the HTTP request body's `"model"` field.                  |
| `history_turns_max`  | `null`   | Per-model trim — only the last N turns get sent to this model. Useful for mixing a 32k-token coder model with a small 4-bit local model in the same `Alt+M` cycle. `null` means "use the full ring." |

## Security notes

- **C0 + C1 + DEL controls are stripped** from the parsed command
  before it touches the PTY. Includes UTF-8-encoded C1 (`0xC2`
  `0x80..0x9F` for U+0080..U+009F) — a model that emits CSI
  (U+009B) followed by a payload would otherwise inject a real
  terminal escape sequence the user never typed.
- **CR is dropped specifically** in the JSON-escape decode path
  *and* in the sanitiser. Writing `\r` to the PTY acts as Enter,
  so a hostile model that returned `cmd1\rcmd2` would have
  auto-executed `cmd1` without review. The double-strip is
  defence in depth.
- **The prefix is shell-safe.** `#: …` is a `#` comment in
  bash / zsh / sh. If the module is misconfigured or returns
  no command, the shell silently ignores the typed line — it
  doesn't try to execute `:` as a command-not-found.

## Shutdown semantics

The worker thread is `t.detach()`'d on atty exit rather than
joined. If the worker is mid-request (slow endpoint, OS TCP
timeout), joining would hang atty's exit for tens of seconds.
The OS reaps the thread at process exit; the heap allocations
the worker references (Shared / api_base / api_key / shell /
context_blob) are deliberately leaked. Inert-mode runtimes (no
worker spawned)
clean up synchronously since there's nothing to race against.
A proper timeout on `client.fetch` is the long-term fix; see
`timeout_ms` in the config table.
