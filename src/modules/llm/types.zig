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

/// Auto-detected system context — toggleable per-source. The
/// values atty gathers from each source land in the system prompt
/// under a `System:` heading so the model can pick the right
/// package manager / cwd-relative path / branch-aware advice.
///
/// **What each source provides:**
///   - `os`: `/etc/os-release` PRETTY_NAME + `uname -srm`.
///     Resolved ONCE at attach (cached on Runtime).
///   - `pwd`: current working directory at REQUEST time. Sourced
///     from atty's subprocess tracker (which follows OSC 7 / `;C`
///     edges) so it reflects bash's view, not atty's own cwd.
///   - `git`: `<cwd>/.git/HEAD` parsed for the current branch (or
///     abbreviated commit hash if detached). No `git status`
///     subprocess — atty never blocks on the user's `.git` size.
///
/// Defaults: all on. Disable any source by setting the matching
/// field to `false`. Disable ALL by setting `enabled = false`.
pub const SystemContext = struct {
    /// Master switch. `false` → atty gathers NO auto-context;
    /// system prompt still gets `context_env_vars` (user-listed).
    enabled: bool = true,
    /// Include OS pretty-name + kernel + arch.
    os: bool = true,
    /// Include current working directory.
    pwd: bool = true,
    /// Include git branch when `<cwd>/.git/HEAD` is readable.
    /// No subprocess fired — pure file read.
    git: bool = true,
};

/// LLM transport choice. The HTTP variant calls an OpenAI-compatible
/// `/chat/completions` endpoint (Ollama, llama.cpp, OpenAI, anything
/// that speaks the OpenAI wire format). The subprocess variant
/// spawns a CLI tool (`claude -p`, `llm`, `mods`, …) — the prompt
/// goes in via stdin or as the final argv slot, the response comes
/// back on stdout.
///
/// Default is `.{ .http = .{} }` so existing configs that don't
/// touch `.provider` keep the original behavior.
pub const Provider = union(enum) {
    http: HttpProvider,
    subprocess: SubprocessProvider,
};

/// Dispatch mode — which atty key binding triggered the request.
/// Used by `ProviderEntry.for_modes` to gate which provider serves
/// which binding. `Mode` and `RequestKind` (in worker.zig) overlap
/// but aren't identical: RequestKind distinguishes the worker's
/// request shape (`.single` vs `.dialog`), Mode distinguishes the
/// user-facing intent (Alt+A vs Alt+S vs Alt+Shift+S vs Alt+C).
pub const Mode = enum {
    single, // Alt+A — one-shot `#: prompt → cmd`
    dialog, // Alt+S — interactive exec/observe loop
    auto, // Alt+Shift+S — dialog + auto-confirm
    chat, // Alt+C / Alt+Shift+C — chat panel/overlay

    /// Map a worker `RequestKind` (single vs dialog) onto a Mode.
    /// Used by the worker dispatch when it needs to pick a provider
    /// — at the worker level there's no Alt+Shift+S vs Alt+S
    /// distinction (both are `.dialog` request kind), so the
    /// worker conflates `auto` and `chat` with `dialog` here.
    /// Per-mode resolution happens on the hook side where the
    /// trigger is known; the worker just needs a coarse "is this
    /// a dialog-shaped request" signal.
    pub fn fromRequestKind(kind: anytype) Mode {
        return switch (kind) {
            .single => .single,
            .dialog => .dialog,
        };
    }
};

/// Bitset over `Mode` — `ProviderEntry.for_modes` says which
/// dispatch modes a provider serves. Default is `.all` (every
/// mode); use the named constants for the common subsets.
pub const ModeMask = packed struct(u4) {
    single: bool = true,
    dialog: bool = true,
    auto: bool = true,
    chat: bool = true,

    /// Every mode (default).
    pub const all: ModeMask = .{};
    /// Only Alt+A one-shots.
    pub const single_only: ModeMask = .{ .single = true, .dialog = false, .auto = false, .chat = false };
    /// Alt+S, Alt+Shift+S, Alt+C / Alt+Shift+C — anything that
    /// runs through the dialog state machine.
    pub const dialog_only: ModeMask = .{ .single = false };
    /// Dialog + auto-confirm, but NOT the chat surface.
    pub const dialog_and_auto: ModeMask = .{ .single = false, .chat = false };

    pub fn matches(m: ModeMask, mode: Mode) bool {
        return switch (mode) {
            .single => m.single,
            .dialog => m.dialog,
            .auto => m.auto,
            .chat => m.chat,
        };
    }
};

/// Per-request provider pick. `name` is the entry's label;
/// empty string means "no entry name was set — derive a label
/// at the call site via `providerLabel(provider)` or similar".
/// The fallback / single-shorthand case always returns an empty
/// name. Lifetimes borrow from `cfg.providers` / `cfg.provider`
/// — both are comptime-static so the slice outlives the worker.
pub const ResolvedProvider = struct {
    provider: Provider,
    name: []const u8,
};

/// Best-effort human-readable label for a `Provider` when no
/// `ProviderEntry.name` is set. HTTP uses the model id;
/// subprocess uses argv[0]. Caller decides between this and a
/// configured `name` — pair with `resolveProviderForMode` for
/// the canonical "what should the statusbar/header show"
/// rendering.
pub fn providerLabel(p: Provider) []const u8 {
    return switch (p) {
        .http => |h| if (h.model.len > 0) h.model else "(http)",
        .subprocess => |s| if (s.argv.len > 0) s.argv[0] else "(subprocess)",
    };
}

/// Pick the provider that serves `mode` from `providers[]`,
/// preferring the entry at `current_idx` when its `for_modes`
/// covers the mode. Falls back to the first matching entry,
/// then to `fallback` (the single-provider shorthand) when
/// nothing matches. Empty `providers[]` always returns
/// `fallback`.
pub fn resolveProviderForMode(
    mode: Mode,
    providers: []const ProviderEntry,
    fallback: Provider,
    current_idx: usize,
) ResolvedProvider {
    if (providers.len == 0) return .{ .provider = fallback, .name = "" };
    if (current_idx < providers.len) {
        const entry = providers[current_idx];
        if (entry.for_modes.matches(mode)) {
            return .{ .provider = entry.config, .name = entry.name };
        }
    }
    for (providers) |entry| {
        if (entry.for_modes.matches(mode)) {
            return .{ .provider = entry.config, .name = entry.name };
        }
    }
    return .{ .provider = fallback, .name = "" };
}

/// Compatibility wrapper — collapses a `RequestKind` to its
/// `Mode` peer before resolution. Prefer
/// `resolveProviderForMode` when the trigger site knows whether
/// we're in `.auto` or `.chat`.
pub fn resolveProvider(
    req_kind: anytype,
    providers: []const ProviderEntry,
    fallback: Provider,
    current_idx: usize,
) ResolvedProvider {
    return resolveProviderForMode(Mode.fromRequestKind(req_kind), providers, fallback, current_idx);
}

/// One entry in `Config.providers[]`. Carries a `Provider` config
/// + metadata about which modes the entry serves + whether
/// `Alt+M` cycles to it.
pub const ProviderEntry = struct {
    /// Human-readable label — surfaced in the statusbar's hint
    /// row and the `Alt+M` cycle indicator. Empty = fall back to
    /// transport-derived label (HTTP shows model id; subprocess
    /// shows argv[0]).
    name: []const u8 = "",
    /// Transport configuration (HTTP or subprocess).
    config: Provider,
    /// Which dispatch modes this entry serves. Worker dispatch
    /// picks the first entry whose `for_modes.matches(mode)` is
    /// true, falling back to `Config.provider` if no entry
    /// matches.
    for_modes: ModeMask = .all,
    /// Whether `Alt+M` cycles to this entry. Set `false` for
    /// "pinned" entries (e.g. a haiku always for one-shots,
    /// never cycled to in dialog mode).
    cycleable: bool = true,
    /// Per-entry history-turns override. `null` = use
    /// `Config.history_turns_max`. Useful for small-context
    /// models — set a tighter cap on the entry that uses them.
    history_turns_max: ?usize = null,
};

/// OpenAI-compatible chat-completions transport. Holds the
/// endpoint-discovery knobs that used to live directly on `Config`,
/// plus the model id (subprocess providers carry the model in
/// argv; HTTP carries it in the request body).
pub const HttpProvider = struct {
    /// Model identifier sent in the request body's `"model"`
    /// field. Comptime-validated non-empty for `cfg.providers[]`
    /// entries AND for the single-shorthand `cfg.provider` —
    /// an empty model would land as `"model":""` and route to an
    /// unintended default at the endpoint. Default value here
    /// satisfies the implicit `cfg.provider = .{ .http = .{} }`
    /// case for users who haven't configured anything.
    model: []const u8 = "llama3:8b",
    /// Hardcoded API base URL — wins over both env vars when
    /// non-empty.
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
    /// no `Authorization` header.
    api_key_env: []const u8 = "LLM_API_KEY",
};

/// CLI-tool transport. The prompt is delivered to the named
/// program either as the final argv slot or piped via stdin
/// (`.prompt_via`). The program's stdout is parsed either as
/// raw text (`.output = .raw`) or as JSON with a named field
/// extracted (`.output = .{ .json_field = "result" }`).
///
/// **Example — `claude -p --output-format json`** (Claude Code CLI):
/// ```zig
/// .provider = .{ .subprocess = .{
///     .argv = &.{ "claude", "-p", "--output-format", "json" },
///     .output = .{ .json_field = "result" },
/// }},
/// ```
/// (Or use the `providers.claudeCode(...)` factory for the same
/// shape with a model arg.)
pub const SubprocessProvider = struct {
    /// Program + leading args. atty appends the rendered prompt as
    /// the final argv slot (default) or pipes it via stdin
    /// — see `prompt_via`. `argv[0]` is resolved against `$PATH`
    /// the usual way (libc `execvp`).
    argv: []const []const u8,
    /// How to deliver the prompt to the subprocess. `.final_arg`
    /// works for CLIs that accept the prompt positionally; `.stdin`
    /// for tools that read from a pipe. Default `.final_arg`
    /// because that's what `claude -p` wants.
    prompt_via: PromptVia = .final_arg,
    /// Stdout parsing. `.raw` = the response is the stdout text,
    /// trimmed of trailing newlines. `.json_field` = parse stdout
    /// as JSON, extract the named top-level string field. Claude
    /// Code's `--output-format json` emits
    /// `{"type":"result","result":"…"}`, so use
    /// `.{ .json_field = "result" }`. `.json_stream` = newline-
    /// delimited JSON (`claude -p --output-format stream-json`):
    /// each line is parsed; intermediate events (system / assistant
    /// partials) are skipped, the value of the named field on the
    /// `type="result"` line is the final response.
    output: Output = .raw,
    /// Native CLI-side session continuation. `.none` (default)
    /// sends the full rendered conversation history with every
    /// request — works for any prompt-in / text-out CLI. `.continuation`
    /// captures a session id from the CLI's response (e.g.
    /// `claude --output-format stream-json`'s `session_id` field
    /// on its `type="system",subtype="init"` event) and reuses it
    /// via the configured argv flag on subsequent turns. The CLI
    /// then maintains the conversation; atty sends only the
    /// LATEST user turn each time.
    ///
    /// Off by default — opt-in because the user is delegating
    /// conversation memory to a process they didn't write.
    session: Session = .none,

    /// Wall-clock timeout in ms. A watchdog thread spawns
    /// alongside the child; on expiry it sends SIGKILL via
    /// `std.posix.kill` (bypassing `std.process.Child.kill`'s
    /// state mutation so it's safe to race with the main thread's
    /// read/wait). Generous default because Claude can take
    /// 5–15 s for non-trivial prompts; tighten for faster local
    /// CLIs. Set to 0 to disable the watchdog entirely.
    timeout_ms: u64 = 30_000,

    pub const PromptVia = enum { final_arg, stdin };

    pub const Output = union(enum) {
        raw,
        json_field: []const u8,
        /// Streaming variant — Claude Code's `--output-format
        /// stream-json` emits one JSON object per line. We skip
        /// any object whose `type` field isn't `"result"` and
        /// extract `<field>` (default `"result"`) from the
        /// terminating result event.
        json_stream: JsonStream,
    };

    pub const JsonStream = struct {
        /// Top-level field on the `type="result"` line to extract.
        field: []const u8 = "result",
    };

    pub const Session = union(enum) {
        none,
        continuation: Continuation,
    };

    pub const Continuation = struct {
        /// Argv flag for resuming a previously-captured session.
        /// `claude` uses `--resume <id>`; other CLIs may differ.
        flag: []const u8 = "--resume",
        /// JSON field on a stream event whose value is the
        /// session id. For claude's stream-json output the id
        /// lives on the `type="system",subtype="init"` line in
        /// the `session_id` field.
        id_field: []const u8 = "session_id",
        // NOTE on resume semantics: atty assumes the CLI re-applies
        // the original system prompt + conversation history when
        // invoked with `flag <id>`. claude does. CLIs whose
        // `--session <id>` carries only the history but not the
        // framing instructions would see naked user turns
        // (`renderLatestUserTurn` strips system + assistant content
        // on resumed turns). Verify your CLI's resume contract
        // before enabling.
    };
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
    /// Shell name for the user-prompt template. `null` → derive
    /// from `$SHELL` basename at attach time.
    shell: ?[]const u8 = null,
    /// Single-provider shorthand. Used when `providers` is empty.
    /// HTTP variant's `.model` field carries the model id;
    /// subprocess variants bake the model into argv.
    ///
    /// To dispatch different providers per mode (single → haiku,
    /// dialog → sonnet) populate `providers` instead — when
    /// non-empty it takes precedence over this field.
    provider: Provider = .{ .http = .{} },
    /// Per-mode provider array. When non-empty, takes precedence
    /// over `Config.provider`. First entry whose
    /// `for_modes.matches(current_mode)` is true serves the
    /// request. `Alt+M` cycles through entries where `cycleable`
    /// is true AND the entry's `for_modes` covers the current
    /// mode. See `ProviderEntry`.
    ///
    /// Example — haiku for one-shots, sonnet for dialog:
    /// ```zig
    /// .providers = &.{
    ///     .{ .name = "haiku",  .config = providers.claude_haiku_4_5,  .for_modes = .single_only },
    ///     .{ .name = "sonnet", .config = providers.claude_sonnet_4_6, .for_modes = .dialog_only },
    /// },
    /// ```
    providers: []const ProviderEntry = &.{},
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
    /// context block appended to the user message.
    ///
    /// Defaults skew toward "shell-task essentials that don't
    /// identify the user":
    ///   - `EDITOR` / `VISUAL` — picks the right `:wq` vs
    ///     `Ctrl+X` workflow for `git commit`, `crontab -e`, etc.
    ///   - `LANG` — locale-aware `sort` / `date` / `grep` output.
    ///   - `TERM` — terminal-capability awareness (kitty kbd,
    ///     truecolor, alt-screen support).
    ///   - `TZ` — timezone-aware date / scheduling suggestions.
    ///
    /// **The values land verbatim in the LLM request body** — so
    /// privacy depends on what's in this list, not which modes
    /// record locally (incognito only gates atuin/history, not
    /// the LLM payload). Tune to taste:
    ///   - Add `HOME` / `USER` / `PWD` for username- or path-aware
    ///     suggestions (self-hosted models only — these leak the
    ///     username to cloud endpoints).
    ///   - Add project-anchor vars like `PATH_BASE`.
    ///   - **Never list** credential-shaped vars (`*_API_KEY`,
    ///     `*_TOKEN`, `AWS_*`, `OPENAI_*`, …). atty does not
    ///     filter env-var contents — the responsibility is on the
    ///     config.
    ///
    /// Set to `&.{}` to send no env context at all.
    context_env_vars: []const []const u8 = &.{
        "EDITOR",
        "VISUAL",
        "LANG",
        "TERM",
        "TZ",
    },
    /// Auto-detected system context appended to the system prompt
    /// alongside `context_env_vars`. The shell's PS1 typically
    /// advertises this info (cwd, git branch, …) but the local
    /// model never sees PS1 — atty surfaces it directly so the
    /// model stops suggesting `apt` on Arch or `cd ~` when the
    /// user is already in their project.
    ///
    /// All sub-knobs default to `true`. Set the relevant one to
    /// `false` to opt out of a specific source (e.g. on a huge
    /// monorepo where reading `.git/HEAD` per-request is still
    /// fine but you want to skip the OS info because you've
    /// hand-tuned `system_prompt` already).
    system_context: SystemContext = .{},
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
    /// Show a compact discoverability hint in the statusbar when
    /// the LLM module is loaded but no AI mode is active (idle
    /// prompt, no `#:` typed). The hint reads
    /// `✨ Alt+C chat · Alt+S dialog · Alt+H help` — three keys
    /// users actually need to know to bootstrap. Without it a
    /// fresh shell shows only `atty │ atuin` and users never
    /// discover the LLM bindings (chicken-and-egg).
    ///
    /// Off-by-default users: set this to `false` to hide the hint;
    /// the more discoverable `Alt+H` cheat-sheet still works.
    show_idle_keys_hint: bool = true,
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
    /// Per-request timeout in ms for HTTP providers. The worker
    /// runs `client.fetch` on a sub-thread and polls completion
    /// against this deadline; on timeout the proxy gets back
    /// `HTTP request timed out (Nms)` so it clears `in_flight`
    /// and surfaces the diagnostic. The detached sub-thread keeps
    /// running in the background; it frees its own heap state
    /// when `client.fetch` eventually returns (typically when the
    /// OS TCP timeout fires). Until then the orphaned task holds
    /// ~`max_response_bytes * 16` bytes — repeated requests
    /// against a blackholed endpoint can accumulate several
    /// orphans before any of them complete. `0` disables the
    /// deadline (worker blocks on the OS TCP timeout).
    /// Subprocess providers have their own deadline at
    /// `SubprocessProvider.timeout_ms`, enforced via SIGTERM /
    /// SIGKILL on the child process group.
    timeout_ms: u32 = 30_000,
    /// Maximum response size we'll store. The model may emit more;
    /// we truncate. Bumped from the original 4 KB default because
    /// modern chat-mode responses (especially from smaller local
    /// models that tend to be verbose) routinely exceed 4 KB —
    /// the user-visible failure mode was a turn cutting off mid-
    /// sentence with no indicator. 16 KB fits most replies; bump
    /// further for models that emit walls of markdown.
    max_response_bytes: comptime_int = 16 * 1024,
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
    ///   (16 KB).
    /// - Heap (via the `Shared` block): `req_buf`
    ///   (`max_prompt_bytes`, 2 KB) + `res_buf` (dynamic — sized
    ///   to actual response; `max_response_bytes` is the soft DoS
    ///   cap) + `body_buf` (`body_buf_bytes`, 32 KB).
    /// - Inline on `Runtime`: `inject_buf` + `pending_command`
    ///   (each `max_response_bytes`, 32 KB total).
    /// Default config: ~50 KB heap + 32 KB inline per instance with
    /// no LLM reply in flight; +max_response_bytes (16 KB) on reply
    /// turns. Sizes scale with whichever knob you bump.
    captured_output_bytes: comptime_int = 16 * 1024,
    /// Maximum conversation turns kept in memory. FIFO truncation
    /// when exceeded — older turns drop first.
    history_turns_max: comptime_int = 8,
    /// Bytes of allocated content per turn (capped so an LLM that
    /// vomits 50 KB of "thinking" output can't OOM the runtime).
    /// Truncated at this length; the model loses the tail of a
    /// pathological response. Matches `max_response_bytes` so a
    /// single response that just barely fits in the worker buffer
    /// isn't then re-truncated at turn-storage time.
    max_turn_bytes: comptime_int = 16 * 1024,
    /// Auto-confirm delay (ms) for the `Alt+Shift+S` auto-exec
    /// path: how long the proxy waits between an LLM-injected
    /// command landing at the prompt and the auto-submitted Enter.
    /// The window doubles as the abort opportunity — any keystroke
    /// during the delay disarms the timer and leaves the command
    /// editable. 800 ms is long enough to spot something obvious;
    /// shorten if you trust the model more, lengthen if you want
    /// more hesitation.
    auto_delay_ms: u32 = 800,
    /// Auto-defocus the Alt+C inline chat panel when an
    /// `action=exec` command lands at the shell prompt during a
    /// dialog. The next keystroke (Enter) runs the command
    /// directly without a manual Alt+C toggle. Focus returns to
    /// chat when the shell returns to a new prompt (OSC 133 ;A).
    /// Off → user toggles focus manually.
    ///
    /// Skipped entirely in auto-mode (Alt+Shift+S) which already
    /// auto-confirms after `auto_delay_ms`, and in single-mode
    /// (Alt+A) which doesn't run with the chat panel open.
    inline_chat_autofocus_on_exec: bool = true,
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
    /// Persist each dialog session to its own NDJSON file under
    /// `chat_persist_dir`. Default ON.
    ///
    /// On `attach`: resolve the directory + ATOMICALLY reserve a
    /// unique session path via `O_CREAT|O_EXCL` — this leaves a
    /// 0-byte file on disk until either a turn appends to it OR
    /// the reservation gets `unlink`ed at rotation/detach time
    /// (cancel paths with no turns DO clean themselves up). Every
    /// `pushTurn` appends a JSONL line; every `dialogReset`
    /// flushes a captured conclusion record, drops the unused
    /// reservation if no record was written, and rotates to a
    /// fresh path for the next dialog.
    ///
    /// Files appear as `<chat_persist_dir>/YYYYMMDDTHHMMSS-XXXXXX
    /// .jsonl` — distinct per session so a recall picker (PR 2
    /// follow-up) can surface them as discrete artifacts.
    chat_persist_enabled: bool = true,
    /// Directory holding per-session NDJSON files. Empty string +
    /// `chat_persist_enabled = true` → atty picks
    /// `${XDG_STATE_HOME}/atty/dialogs/` (or
    /// `${HOME}/.local/state/atty/dialogs/` if XDG isn't set).
    ///
    /// **Tilde NOT expanded**: write the full path or use `$HOME`
    /// at config-write time. The directory tree is created with
    /// mode 0700 on first resolve.
    ///
    /// **File format** (one per session):
    /// ```
    /// {"kind":"user","content":"list zig files"}
    /// {"kind":"assistant_exec","content":"{...JSON envelope...}"}
    /// {"kind":"observation","content":"main.zig\nbuild.zig"}
    /// {"kind":"conclusion","content":"Listed 2 zig files."}
    /// ```
    /// `kind` ∈ {`user`, `assistant_exec`, `observation`,
    /// `conclusion`}. `parseLine` parses the three turn kinds;
    /// `parseRecord` additionally surfaces `conclusion` records
    /// for the recall picker's loader. Unknown kinds are silently
    /// skipped (forward-compat for future taxonomy).
    chat_persist_dir: []const u8 = "",
    /// Maximum number of persisted dialogs to retain on disk.
    /// `attach` calls `chat_persist.pruneOldest` against
    /// `chat_persist_dir` before reserving the new session — files
    /// past this count (newest-first by filename) get `unlink`ed.
    /// `0` disables the sweep (files accumulate unbounded). 100
    /// is enough for a few weeks of casual use without being so
    /// large that the recall picker becomes unscrollable.
    chat_persist_max_dialogs: usize = 100,
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
    /// Blank rows between the shell prompt and the inline panel's
    /// top divider. Default 1 keeps the prompt visually separated
    /// from the chat chrome instead of glued directly to the
    /// divider edge. The proxy reserves these rows on top of
    /// `inline_chat_rows`; the panel paint skips them so they stay
    /// empty. Set to 0 to abut the divider directly against the
    /// prompt; raise for more breathing room.
    inline_chat_top_gap: u16 = 1,

    /// Compact observation turns in the inline panel — show
    /// `[N line(s) · Alt+Shift+C to inspect]` instead of the
    /// verbatim command output. The full content is still in
    /// turns + reachable via Alt+Shift+C / scroll-back to the
    /// full-size overlay. Default true because long build/test
    /// output buries the conversation in the narrow inline
    /// window; set false to see verbatim output inline.
    /// Full-size overlay rendering is unaffected.
    inline_observation_compact: bool = true,
};
