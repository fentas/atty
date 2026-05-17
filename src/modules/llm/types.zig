//! Public types for the LLM module's compile-time configuration.
//! Lives in its own file so a `Config` import doesn't drag in the
//! comptime `configure()` return type — keeps the dependency graph
//! between sibling submodules acyclic.

/// Policy for honouring the LLM's `open_chat` advisory flag —
/// when the dialog reply suggests the user follow up in the chat
/// overlay. See `Config.overlay_open_policy`.
pub const OverlayOpenPolicy = enum {
    /// Auto-open the overlay on every `open_chat: true` reply.
    always,
    /// Latch a hint so the user knows the LLM wants to chat;
    /// they decide whether to Alt+C. **Default.**
    notify,
    /// Ignore the flag; only user-initiated Alt+C opens the
    /// overlay.
    never,
};

/// What happens when the user presses Enter on a line that starts
/// with `Config.prefix` (`#: ` by default). See `Config.enter_action`.
pub const EnterAction = enum {
    /// No-op — Enter on `#: …` does nothing. User must press
    /// Alt+A / Alt+S / Alt+Shift+S explicitly to fire the LLM.
    /// **Default** — defends against accidental LLM calls when
    /// typing comments at the prompt.
    none,
    /// Same effect as Alt+A — single-prompt, no dialog loop. The
    /// LLM returns one command and atty injects it for the user
    /// to review + Enter to run.
    single,
    /// Same effect as Alt+S — multi-turn dialog with OSC 133
    /// output capture between exec steps. Requires the shell to
    /// emit OSC 133 markers.
    dialog,
    /// Same effect as Alt+Shift+S — dialog mode + auto-submit
    /// each suggested command after `auto_delay_ms`. Any
    /// keystroke during the delay aborts the auto-submit.
    auto,
};

/// One entry in `Config.models`. `name` is required (it's what the
/// HTTP request body sends as `"model":"…"`); everything else is
/// optional with `null` = "fall back to the matching `Config.*`
/// default." This struct is intentionally extensible — adding a new
/// optional field stays backwards-compatible with existing user
/// configs.
///
/// Usage in a user config:
/// ```
/// const qwen_coder: atty.modules.llm.Model = .{
///     .name = "qwen3-coder:30b",
///     // history_turns_max omitted → ring default
/// };
/// const gemma: atty.modules.llm.Model = .{
///     .name = "gemma3:4b",
///     .history_turns_max = 3,   // small context window
/// };
/// // …
/// .models = &.{ qwen_coder, gemma }
/// ```
pub const Model = struct {
    /// Model identifier sent in the request body's `"model"` field.
    /// Required; the comptime check in `configure()` errors on empty
    /// names. Examples: `"llama3:8b"`, `"qwen3-coder:30b"`,
    /// `"gpt-5-mini"`.
    name: []const u8,
    /// Trim the conversation to at most this many turns when
    /// sending to THIS model. Useful for small-context models that
    /// can't fit the default ring (`Config.history_turns_max`).
    /// `null` means use the ring's full population. Hard-capped at
    /// the ring capacity — values larger than
    /// `Config.history_turns_max` have no effect.
    history_turns_max: ?usize = null,
};

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
    /// wrap-around. First entry is the default at startup. Empty
    /// (default) → use the single `model` field above.
    ///
    /// Each entry is a `Model` struct so per-model knobs (context
    /// window, future temperature/top_p, …) travel with the name
    /// as one unit. Bare strings won't compile; declare each model
    /// as `.{ .name = "..." }` at minimum.
    ///
    /// Example:
    /// ```
    /// .models = &.{
    ///     .{ .name = "qwen3-coder:30b" },
    ///     .{ .name = "gemma3:4b", .history_turns_max = 3 },
    ///     .{ .name = "llama3:70b" },
    /// },
    /// ```
    models: []const Model = &.{},
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
    /// System-role TASK FRAMING. The default depends on
    /// `with_explanation`: with → "one-line explanation + fenced
    /// command"; without → "exactly one command, no extras."
    /// Override to tune for your model's idiosyncrasies. When you
    /// override AND set `with_explanation = false`, also drop the
    /// fence/explanation guidance from your prompt or atty will
    /// happily render whatever prose it sees in the hint row.
    ///
    /// **Note:** atty prepends an invariant `atty_preamble` (host-
    /// environment context + meta-question routing) regardless of
    /// this override. The effective prompt sent to the LLM is
    /// `atty_preamble ++ "\n\n" ++ this`. The preamble exists so
    /// user customisation can't accidentally strip the framing
    /// the rest of atty's UI depends on. If you need full control,
    /// build atty with the preamble emptied at source.
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
    /// 256-colour foreground for the AI / DIALOG / AUTO icon glyphs
    /// in the status bar. Picked so the icon reads as "marked"
    /// without competing with the surrounding dim prose for
    /// attention. Default 141 = soft mauve — distinct from the
    /// statusbar's gray dim and visible on both light and dark
    /// terminal themes. Set to `null` to inherit the bar's
    /// dim-gray styling (legacy look).
    statusbar_icon_color: ?u8 = 141,
    /// 256-colour foreground for the keyboard-shortcut tokens
    /// (`Alt+A`, `Alt+S`, etc.) in the AI-mode status hint.
    /// Default 14 = bright cyan, paired with a bold weight so
    /// the keys jump out of the surrounding dim prose at a
    /// glance. Set to `null` to inherit the bar's styling.
    statusbar_shortcut_color: ?u8 = 14,
    /// How atty responds when the LLM emits `"open_chat": true` in
    /// a dialog reply. The flag is advisory — the model signals
    /// that the user would benefit from following up in the chat
    /// overlay, but the user keeps final control via this policy.
    ///
    /// - `.always` — auto-open the overlay on the LLM's request
    /// - `.notify` (default) — latch a hint "LLM wants to chat —
    ///   Alt+C to open"; user decides whether to act
    /// - `.never` — ignore the flag entirely; only user-initiated
    ///   Alt+C opens the overlay
    overlay_open_policy: OverlayOpenPolicy = .notify,
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
    /// **Footprint note** (approximate, default-config in
    /// parens): per-attach memory has three pieces.
    /// - Heap (via `Runtime` directly): `captured_output_bytes`
    ///   (16 KB) + `last_assistant_json` (`max_response_bytes`,
    ///   4 KB).
    /// - Heap (via the `Shared` block): `req_buf`
    ///   (`max_prompt_bytes`, 2 KB) + `res_buf`
    ///   (`max_response_bytes`, 4 KB) + `body_buf`
    ///   (`body_buf_bytes`, 32 KB).
    /// - Inline on `Runtime`: `inject_buf` + `pending_command`
    ///   (each `max_response_bytes`, 8 KB total).
    /// Default config: ~58 KB heap + 8 KB inline per instance.
    /// Sizes scale with whichever knob you bump.
    captured_output_bytes: comptime_int = 16 * 1024,
    /// Maximum conversation turns kept in memory. FIFO truncation
    /// when exceeded — older turns drop first.
    history_turns_max: comptime_int = 8,
    /// Bytes of allocated content per turn (capped so an LLM that
    /// vomits 50 KB of "thinking" output can't OOM the runtime).
    /// Truncated at this length; the model loses the tail of a
    /// pathological response.
    max_turn_bytes: comptime_int = 4 * 1024,
    /// Auto-confirm delay (ms) for the `Alt+Shift+S` auto-exec
    /// path: how long the proxy waits between an LLM-injected
    /// command landing at the prompt and the auto-submitted Enter.
    /// The window doubles as the abort opportunity — any keystroke
    /// during the delay disarms the timer and leaves the command
    /// editable. 800 ms is long enough to spot something obvious;
    /// shorten if you trust the model more, lengthen if you want
    /// more hesitation.
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
    /// Behaviour of the bare Enter key when the line starts with
    /// `prefix`. Default `.none` — Enter is a no-op in AI mode and
    /// the user must press Alt+A / Alt+S / Alt+Shift+S explicitly.
    /// This defends against accidental LLM calls when the user
    /// types a `#: …` comment intending to actually commit it.
    /// Flip to `.single` / `.dialog` / `.auto` to bind Enter to the
    /// corresponding action — useful for muscle-memory users who
    /// preferred the pre-Alt-key trigger flow.
    enter_action: EnterAction = .none,
    /// How many times atty will ask the LLM to retry when its
    /// dialog reply fails to parse as the JSON envelope. Models
    /// sometimes drift into prose, wrap the JSON in stray fences
    /// the strip-pass misses, or omit required fields; atty echoes
    /// the bad reply back + sends a corrective user turn explaining
    /// what was wrong. After this many attempts the dialog aborts
    /// with the parse-fail error so a consistently misbehaving
    /// model can't trap the loop forever. Default 2 — empirically
    /// enough for most models to self-correct once shown their
    /// mistake; raise if you're on a particularly stubborn model.
    /// Set to 0 to disable retry (revert to the pre-retry abort
    /// behaviour).
    dialog_parse_retry_max: u8 = 2,
    /// Persist the LLM chat history to a file on disk so it
    /// survives across atty sessions. Default OFF.
    ///
    /// When enabled:
    ///   • At attach: load the LAST `history_turns_max` turns from
    ///     `chat_persist_path` into the in-memory ring (so chat
    ///     scrollback + dialog context pick up where the previous
    ///     session left off).
    ///   • On every `pushTurn`: append the new turn as one NDJSON
    ///     line to the file.
    ///   • On `dialogReset` (`.done` / `Ctrl+Shift+X`): in-memory
    ///     ring clears, FILE is preserved.
    chat_persist_enabled: bool = false,
    /// Path to the chat-history file. Used only when
    /// `chat_persist_enabled = true`. Empty string + enabled →
    /// atty picks `${XDG_DATA_HOME}/atty/chat.jsonl` (or
    /// `${HOME}/.local/share/atty/chat.jsonl` if XDG isn't set).
    ///
    /// **Tilde NOT expanded**: write the full path or use `$HOME`
    /// at config-write time. The path is opened with `O_APPEND |
    /// O_CREAT`; parent directories ARE created when atty owns the
    /// default path, but a user-supplied path expects the directory
    /// to already exist.
    ///
    /// **File format**:
    /// ```
    /// {"kind":"user","content":"list zig files"}
    /// {"kind":"assistant_exec","content":"{...JSON envelope...}"}
    /// {"kind":"observation","content":"main.zig\nbuild.zig"}
    /// ```
    /// One turn per line. `kind` ∈ {`user`, `assistant_exec`,
    /// `observation`}. Unknown kinds are silently skipped on load
    /// (forward-compat for future Turn taxonomy).
    chat_persist_path: []const u8 = "",
    /// Soft cap on the persistence file's size, in bytes. When the
    /// file grows past this AND a new turn is being appended, atty
    /// rewrites the file in place keeping only the most recent
    /// content (tail-truncation that preserves whole NDJSON lines).
    /// `0` (the default) disables rotation — the file grows
    /// unbounded.
    ///
    /// Typical value: 8 MB (`8 * 1024 * 1024`) — about ~20k average
    /// turns at 400 B/turn. The rotation uses a tmp+rename atomic
    /// swap so a crash mid-rewrite leaves the original intact.
    chat_persist_max_bytes: usize = 0,
    /// Inline chat panel — how many rows the panel claims above
    /// the statusbar when `Alt+C` opens it. The bottom row is the
    /// input prompt (`> _`), the rows above it scroll back through
    /// recent turns. Bumped to 10 by default — enough to read the
    /// last assistant response (often 4-6 wrapped lines on a typical
    /// 80-col terminal) plus the user turn that prompted it, leaving
    /// room for the input row + a leading divider. Tune down for
    /// tiny terminals or up for a wider history view. Minimum 3 —
    /// less than that and there's no scrollback at all.
    inline_chat_rows: u16 = 10,
};
