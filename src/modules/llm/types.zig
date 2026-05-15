//! Public types for the LLM module's compile-time configuration.
//! Lives in its own file so a `Config` import doesn't drag in the
//! comptime `configure()` return type — keeps the dependency graph
//! between sibling submodules acyclic.

/// Compile-time configuration for the LLM module. Every field has a
/// reasonable default; override only what your endpoint / model /
/// shell needs.
pub const Config = struct {
    /// Trigger prefix. When the committed line starts with this
    /// AND the user pressed Enter, the rest of the line becomes
    /// the prompt body. Default `#: ` — comment-safe in bash/zsh
    /// so a missed dispatch is a silent no-op, not an executed
    /// command.
    prefix: []const u8 = "#: ",
    /// LLM model identifier passed in the request body.
    ///
    /// **Selection precedence** (matches `triggerSinglePrompt`):
    /// 1. If `cfg.models.len > 0` → use `cfg.models[idx]` where
    ///    `idx = current_model_idx` when in range, else `0`
    ///    (defensive fallback — `Alt+M` wraps so out-of-range
    ///    shouldn't happen; if it does we use the first entry,
    ///    NOT `cfg.model`).
    /// 2. If `cfg.models` is empty → use this `cfg.model`.
    ///
    /// So this field is the SINGLE-MODEL fallback only — once
    /// `cfg.models` is set, this value is unreachable. Kept for
    /// backward compat with configs that pre-date `models[]`.
    model: []const u8 = "llama3:8b",
    /// Configured model list — `Alt+M` cycles through this with
    /// wrap-around. First entry is the default at startup.
    /// Empty (default) → use the single `model` field above.
    /// Example: `&.{ "qwen3-coder", "gpt-5-mini", "llama3:70b" }`.
    models: []const []const u8 = &.{},
    /// Shell name for the user-prompt template. `null` → derive
    /// from `$SHELL` basename at attach time.
    shell: ?[]const u8 = null,
    /// Hardcoded API base URL — wins over both env vars when
    /// non-empty. Use this when you want a stable endpoint baked
    /// into your config and don't want to depend on shell env
    /// state (atty inherits env at fork time, so a misconfigured
    /// `.bashrc` can leave the module inert even though the
    /// endpoint is reachable). The string is used verbatim except
    /// for the trailing-slash normalisation `doRequest` applies
    /// before appending `/chat/completions`. Empty default = "use
    /// env vars below".
    api_base: []const u8 = "",
    /// Env-var name holding the API base URL. Read at attach,
    /// consulted only when `api_base` is empty.
    api_base_env: []const u8 = "LLM_API_BASE",
    /// Fallback env-var (typical Ollama setup). When this is read
    /// AND it doesn't already end in `/v1`, we append it. Only
    /// consulted when both `api_base` and `$api_base_env` are
    /// empty.
    api_base_fallback_env: []const u8 = "OLLAMA_HOST",
    /// Env-var holding the API key. Optional — when unset we send
    /// no `Authorization` header (local servers usually accept
    /// unauthenticated requests).
    api_key_env: []const u8 = "LLM_API_KEY",
    /// When true, ask the model for a one-line explanation followed
    /// by the command in a fenced block. atty surfaces the
    /// explanation in the statusbar's hint row while the command
    /// is injected for review. Drives `system_prompt`'s default.
    /// Disable for terse single-command responses (matches the
    /// pre-explanation behaviour).
    with_explanation: bool = true,
    /// System-role message. The default depends on
    /// `with_explanation`: with → "one-line explanation + fenced
    /// command"; without → "exactly one command, no extras."
    /// Override to tune for your model's idiosyncrasies. When you
    /// override AND set `with_explanation = false`, also drop the
    /// fence/explanation guidance from your prompt or atty will
    /// happily render whatever prose it sees in the hint row.
    system_prompt: []const u8 = "",
    /// Environment variables exposed to the model alongside the
    /// user's prompt. Each named var is read at attach time and
    /// (if set, non-empty) joined into a one-line `KEY=value`
    /// context block appended to the user message. Empty default
    /// = no context. `PATH_BASE` is the canonical example — a
    /// project's "what does this user mean by 'here'" anchor.
    context_env_vars: []const []const u8 = &.{},
    /// When true, change the terminal cursor's colour while the
    /// user is typing a prompt that starts with `prefix`. atty
    /// emits OSC 12 (set cursor colour) on transition into match,
    /// OSC 112 (reset to default) on transition out. Reliable
    /// signal that doesn't depend on knowing the prompt's column.
    /// All modern terminals honour OSC 12 (Ghostty, kitty, iTerm,
    /// VS Code's terminal, WezTerm).
    prefix_signal_cursor: bool = true,
    /// Cursor colour to set while the prefix is matched. Accepted
    /// formats follow OSC 12: a named colour (`cyan`, `lightblue`,
    /// …) or `#RRGGBB` / `rgb:RR/GG/BB`. Whatever your terminal
    /// understands.
    prefix_signal_cursor_color: []const u8 = "cyan",
    /// When true, the LLM module's `statusText` returns
    /// `prefix_signal_status_text` while the prefix is matched
    /// (in addition to the existing `🧠 thinking…` indicator
    /// during in-flight requests). Visible in the bottom status
    /// bar — secondary signal alongside the cursor colour.
    prefix_signal_status: bool = true,
    /// Status-bar text shown while the prefix is matched. Defaults
    /// to a sparkle so it pops against the bar's other segments.
    prefix_signal_status_text: []const u8 = "\u{2728} prompt",
    /// Per-request timeout in ms. Stored for future use; not yet wired
    /// to the HTTP client — requests may block indefinitely on a slow
    /// or unreachable endpoint until the OS TCP timeout fires.
    timeout_ms: u32 = 30_000,
    /// Maximum response size we'll store. The model may emit more;
    /// we truncate.
    max_response_bytes: comptime_int = 4096,
    /// Maximum prompt-body size (line.len - prefix.len). Larger
    /// inputs are ignored — likely paste / file content, not a
    /// natural-language task.
    max_prompt_bytes: comptime_int = 2048,
    /// Maximum bytes of a serialized dialog-request JSON body
    /// (`{model, messages: [system, …]}`). Sized to fit
    /// `history_turns_max` × typical assistant + observation pairs
    /// with comfortable headroom. The trigger site that builds the
    /// body errors if this is exceeded — the LLM call is aborted
    /// with a "context too large, try Ctrl+Shift+X" hint.
    ///
    /// **Footprint note**: this buffer lives in `Shared` (which is
    /// heap-allocated by `attach`), so growing it doesn't bloat
    /// `Runtime` itself, but it does add `body_buf_bytes` to the
    /// module's per-instance heap usage at attach time.
    body_buf_bytes: comptime_int = 32 * 1024,
    /// Bytes of `;C` → `;D` captured output kept per execution
    /// step. Truncates with `…[truncated …]…` when exceeded so the
    /// LLM still gets the head + tail of the output. The cap is a
    /// memory bound, not a correctness bound — most commands fit
    /// in <1 KB.
    ///
    /// **Footprint note**: `captured_output` and
    /// `last_assistant_json` are heap-allocated in `attach`
    /// (freed in `detach`). Two `max_response_bytes`-sized
    /// buffers — `inject_buf` and `pending_command` — remain
    /// inline on Runtime; `body_buf` (`body_buf_bytes`) lives on
    /// the heap-allocated `Shared`. Per-attach memory adds up to
    /// `captured_output_bytes + max_response_bytes + body_buf_bytes`
    /// on the heap, plus `max_response_bytes * 2` still inline on
    /// Runtime itself.
    captured_output_bytes: comptime_int = 16 * 1024,
    /// Maximum conversation turns kept in memory. FIFO truncation
    /// when exceeded — older turns drop first.
    history_turns_max: comptime_int = 8,
    /// Bytes of allocated content per turn (capped so an LLM that
    /// vomits 50 KB of "thinking" output can't OOM the runtime).
    /// Truncated at this length; the model loses the tail of a
    /// pathological response.
    max_turn_bytes: comptime_int = 4 * 1024,
    /// Reserved auto-confirm delay (ms) for the auto-exec
    /// (`Alt+Shift+S`) path: how long the proxy should wait between
    /// an LLM-injected command landing at the prompt and the
    /// auto-submitted Enter, leaving a window for the user to abort
    /// with Ctrl-C. Currently unread — the auto-exec action handler
    /// is a stub that prints "auto exec coming in a follow-up" —
    /// kept here so the knob is configurable the moment the path is
    /// wired (no defaults bump or config migration required).
    auto_delay_ms: u32 = 800,
    /// Fixture-driven LLM responses for e2e tests. When non-empty,
    /// the worker bypasses HTTP entirely and returns the next slice
    /// from this list (wrapping around if requests exceed the list
    /// length). Each slice is the RAW assistant-message content —
    /// for dialog requests, that's the JSON envelope
    /// `{"action":..., "command":..., …}`; for single requests it's
    /// the bare command. The wrap-around behaviour means a fixture
    /// list of `&.{ "{\"action\":\"done\"}" }` will end any dialog
    /// loop on the first reply. Stays empty in production builds.
    fixture_responses: []const []const u8 = &.{},
    /// System prompt for dialog mode (Alt+S). Distinct from
    /// `system_prompt` (single-prompt mode) because dialog mode
    /// requires a strict JSON envelope rather than the
    /// "explanation + fenced command" format. Override only if
    /// you're using a model that struggles with the default
    /// prompt — most modern instruction-tuned models follow it
    /// cleanly.
    ///
    /// **Comptime only**: the override resolves at `configure`
    /// time (mirroring `system_prompt`). There is no runtime
    /// fallback; recompile to change it.
    dialog_system_prompt: []const u8 = "",
};
