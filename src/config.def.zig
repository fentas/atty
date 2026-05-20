//! atty configuration — the Suckless config.h equivalent.
//!
//! Edit this file. Recompile. That is the entire configuration model.
//!
//! Every subsystem is a struct with per-field defaults in
//! `src/defaults.zig`. Declare only the fields you want to override —
//! the rest fall through to the type's defaults, and new fields added
//! upstream flow in automatically. `git pull` rarely conflicts here.
//!
//! Track your config outside the repo with
//! `-Dconfig=/path/to/mine.zig` (or `make CONFIG=/path/to/mine.zig build`).

const atty = @import("atty");

// ───── Modules ──────────────────────────────────────────────────────────
//
// Order = priority. Short-circuiting modules first (Guardrail). The
// default tuple is dependency-free: { guardrail, history }. The
// history module reads/writes your shell's own ~/.bash_history /
// ~/.zsh_history — no `atuin` binary required.
//
// Want atuin instead of (or alongside) history? Uncomment and edit:
//
// pub const modules = .{
//     atty.modules.guardrail.configure(.{
//         // .behavior is per-rule:
//         //   .confirm       (default) press Enter again to confirm
//         //   .confirm_once  same, then never asks again this session
//         //   .block         banner + clear line; command can't run
//         //   .warn          banner + forward (audit, no friction)
//         // .authors restricts a rule to user-typed or llm-injected
//         // commits (default = both).
//         //
//         // `extra_rules` PREPENDS to whatever `rules` resolves
//         // to (defaults to the shipped `default_rules` unless
//         // you also override `rules`). Under first-match-wins
//         // your rules check first. Use this for the common
//         // "I just want a couple more rules" case.
//         // .extra_rules = &.{
//         //     .{ .name = "git-force", .match = .{ .substring = "git push --force" },
//         //        .reason = "force-pushing", .behavior = .confirm_once },
//         // },
//         //
//         // `rules` REPLACES the entire default list — use when you
//         // want a minimal custom policy.
//         // .rules = &.{
//         //     // `.glob` anchors to both ends — only the literal
//         //     // `rm -rf /` matches, so `rm -rf /home/x` falls
//         //     // through to a broader rule below.
//         //     .{ .name = "rm-rf-root", .match = .{ .glob = "rm -rf /" },
//         //        .reason = "rm -rf on root", .behavior = .block },
//         //     .{ .name = "rm-rf-llm", .match = .{ .substring = "rm -rf" },
//         //        .reason = "rm -rf (llm)",
//         //        .authors = .{ .user = false, .llm = true },
//         //        .behavior = .block },
//         // },
//         //
//         // .warning_style = atty.style.presets.danger,
//     }),
//     atty.modules.atuin.configure(.{
//         // .suggestion_ttl_ms = 0,        // 0 = fish-style, no fadeout
//         // .sync_after_records = 10,
//         // .sync_interval_ms = 60_000,
//         // .delete_scope = .exact,       // .exact / .prefix /
//         //                                // .full_text / .fuzzy —
//         //                                // controls Ctrl+Shift+D's
//         //                                // reach into atuin. Default
//         //                                // .exact uses atuin fuzzy +
//         //                                // `^line$` anchors so only
//         //                                // the typed line is removed.
//         // .tag_llm_author = true,        // opt-in: pass
//         //                                // `--author atty:llm` on
//         //                                // LLM-injected commits.
//         //                                // Requires atuin v18.3+.
//         // .author_tag_prefix = "atty",   // shared-DB disambiguator;
//         //                                // e.g. "ws01" if multiple
//         //                                // hosts sync to the same
//         //                                // atuin account.
//     }),
//     atty.modules.history.configure(.{}),  // optional fallback after atuin
// };
//
// LLM-powered command generation. Type `#: <prompt>` + Enter and the
// module replaces the typed line with the model's response. Needs an
// OpenAI-compatible chat endpoint at $LLM_API_BASE (falls back to
// $OLLAMA_HOST + "/v1"). Optional $LLM_API_KEY for hosted services.
// `#` is the shell's comment character so a missed dispatch is a
// silent no-op, not an executed command.
//
// pub const modules = .{
//     atty.modules.guardrail.configure(.{}),
//     atty.modules.atuin.configure(.{}),
//     atty.modules.history.configure(.{}),
//     atty.modules.llm.configure(.{
//         // .prefix = "#: ",          // trigger; default
//         // .model = "llama3:8b",     // model name
//         // .shell = null,            // null → derive from $SHELL
//         // .system_prompt = "...",   // override the system message
//         // .with_explanation = true, // ask for + render one-line summary
//         //                           //   above the status bar
//         // .context_env_vars = &.{   // env vars exposed to the model
//         //     "PATH_BASE",          //   alongside the prompt — one-line
//         //     "PROJECT",            //   "KEY=value, …" appended to the
//         // },                        //   user message
//         //                           // ⚠ DO NOT list secret-bearing vars
//         //                           //   here (AWS_ACCESS_KEY_ID, GH_TOKEN,
//         //                           //   anything *_TOKEN / *_KEY / *_SECRET).
//         //                           //   The values ship verbatim to the
//         //                           //   model — local Ollama is OK, hosted
//         //                           //   APIs are not.
//         // .system_context = .{      // auto-detected env (default ON)
//         //     .enabled = true,      //   master switch
//         //     .os = true,           //   /etc/os-release + uname → static
//         //     .pwd = true,          //   bash's cwd via OSC 7 / subprocess
//         //     .git = true,          //   branch from <cwd>/.git/HEAD
//         // },                        //   (works in worktrees + submodules)
//         //                           // Suppressed entirely when atty is in
//         //                           // incognito mode (Ctrl+Shift+I).
//         // .inline_chat_rows = 10,   // Alt+C panel height in rows (>=3)
//         // .chat_persist_enabled = true,
//         //                           // Persist chat history across atty
//         //                           // sessions. NDJSON, one turn/line.
//         // .chat_persist_path = "",  // Empty → atty picks
//         //                           // $XDG_DATA_HOME/atty/chat.jsonl
//         //                           // (fallback $HOME/.local/share/atty/).
//         //                           // Override for per-project log files.
//         // .chat_persist_max_bytes = 8 * 1024 * 1024,
//         //                           // Soft cap. When exceeded atty
//         //                           // tail-truncates at a line boundary
//         //                           // on the next append (atomic
//         //                           // tmp+rename). 0 = no cap.
//     }),
// };

// ───── security_guard ───────────────────────────────────────────────────
//
// Pre-Enter intercept for high-risk command shapes:
//   - `curl|sh` (and `wget`/`fetch` variants piped to a shell)
//   - `npm install <flagged-pkg>` (tiny hardcoded bad-pkg list)
//   - `bash -c "<long base64>"` payloads
//
// On match: Enter is swallowed, a banner explains what was matched, and
// the next keystroke decides: `y` allow once, `a` allow always (this
// session), `t` trust permanently (SHA-256 of category+match persisted
// to the daemon's per-UID `commands.trusted.txt`), `B` block host
// forever (session), anything else cancels (Ctrl+U clears readline).
//
// Off by default — opt in by adding `atty.modules.security_guard` to
// `modules` AND setting `.enabled = true`. See
// `docs/security-guard-design.md` for the V2 sidecar (atty-guard +
// eBPF + encoder SLM) roadmap.
//
// pub const modules = .{
//     atty.modules.security_guard.configure(.{ .enabled = true }),
//     atty.modules.guardrail.configure(.{}),
//     atty.modules.history.configure(.{}),
// };
//
// // Skip the static-pattern check in incognito mode, or point at an
// // `atty-guard` sidecar daemon:
// // atty.modules.security_guard.configure(.{
// //     .enabled = true,
// //     .skip_in_incognito = false,  // protect EVERYWHERE; incognito
// //                                  // only stops *recording*.
// //     // Opt into the V2 atty-guard sidecar. When set + reachable,
// //     // every Enter queries the daemon BEFORE in-proc patterns; any
// //     // I/O error falls back to the V1 static rules and latches the
// //     // session into in-proc-only mode. Build atty-guard from the
// //     // `atty-guard/` Rust crate at the repo root.
// //     .daemon_socket_path = "",       // e.g. "/run/atty-guard/atty-guard.sock"
// //                                     // (the post-#140 system-daemon path;
// //                                     // user must be in the `atty` group)
// //     .daemon_timeout_ms = 50,        // per-classify keystroke budget
// // }),

// ───── Proxy ────────────────────────────────────────────────────────────
//
// pub const proxy: atty.Proxy = .{
//     .tick_interval_ms = 50,                // default 100
// };

// ───── Ghost overlay ────────────────────────────────────────────────────
//
// `atty.Style` is the shared styling primitive (ghost overlay,
// statusbar segments, guardrail warning, …). Presets in
// `atty.style.presets`, or write literals:
// `.{ .dim = true, .italic = true, .fg = 244 }`.
//
// pub const ghost: atty.Ghost = .{
//     .style = atty.style.presets.muted_italic,
//     // Multi-row pick list below the prompt. 0 disables (default);
//     // 3 shows the next three matches after the inline ghost. Bound
//     // to Ctrl+1..Ctrl+9 (kitty kbd) and Esc+1..Esc+9 (legacy /
//     // Alt+digit fallback). Dynamic — scrolls the prompt up to make
//     // room when needed, releases on line clear.
//     // .list_count = 3,
//     // .list_style = atty.style.presets.muted,
// };

// ───── Terminal protocol ────────────────────────────────────────────────
//
// Off by default. See defaults.zig — opt in only if you know what you
// want from the kitty keyboard protocol; some binding combinations
// (Ctrl+Shift+I) need it but it can break Ctrl+D/Ctrl+C in the shell
// until atty grows a CSI-u → legacy translator.
//
// pub const terminal: atty.Terminal = .{ .enable_kitty_keyboard = true };

// ───── Key bindings ─────────────────────────────────────────────────────
//
// Defaults: Right / End / Ctrl+F → ghost_accept, Alt+i → incognito_toggle.
// `atty.keymap.key("…")` resolves at compile time — typos error the
// build. See src/keymap.zig for supported names (Ctrl+Shift+Right,
// Alt+f, F1–F12, …).
//
// pub const keymap: atty.Keymap = .{
//     .bindings = &.{
//         .{ .bytes = atty.keymap.key("Ctrl+F"), .action = .ghost_accept },
//         .{ .bytes = atty.keymap.key("Alt+i"),  .action = .incognito_toggle },
//     },
// };

// ───── Bottom status bar ────────────────────────────────────────────────
//
// Reserves rows at the bottom of the terminal via DECSTBM. Modules can
// contribute segments via the optional `statusText` hook (joined with
// " │ "). Off by default — opt in if you want it.
//
// pub const statusbar: atty.StatusBar = .{
//     .enabled = true,
//     .reserve_rows = 2,                              // text row + 1 blank above
//     .style = atty.style.presets.muted,
//     .base_text = "atty",                            // proxy-level prefix
//     .incognito_style = .{ .dim = true, .fg = 1 },   // muted red 🔒 segment
// };

// ───── Subprocess context ──────────────────────────────────────────────────
//
// At every OSC 133 `;C` transition (requires shell integration:
// Ghostty's `shell-integration-features = osc-133`, ble.sh,
// zsh4humans, or VS Code's snippet), atty inspects the line you
// just committed. If it matches `ssh` / `mosh` / `kubectl exec` /
// `docker exec` / `lxc exec` / `incus exec` / `sudo bash|-s|-i` /
// `su`, atty pushes a frame onto an in-memory stack and tags
// subsequent recorded commits with an encoded `--cwd`. Unresolved
// path segments emit `?` rather than asserting a value we can't
// verify (atty doesn't read kubeconfig or capture local cwd via
// OSC 7 at depth==0 yet — both are known follow-ups):
//
//   ssh://user@host/<remote-cwd-or-?>
//   k8s://<context-or-?>/<ns-or-?>/<pod>/<remote-cwd-or-?>
//   docker://<container>/<remote-cwd-or-?>
//   container://<name>/<remote-cwd-or-?>
//   sudo:?          (today; sudo:<local-cwd> after local OSC 7 lands)
//   su:?            (bare su, no user)
//   su:<user>:?     (su with user, same TODO for local cwd)
//
// atuin's Ctrl+R `[ DIRECTORY ]` filter then scopes searches per
// remote target. Stack pops on `;D` so nested ssh chains work.
// History module ignores subprocess-typed commits — your
// `~/.bash_history` / `~/.zsh_history` stays free of unrunnable
// lines.
//
// pub const subprocess: atty.Subprocess = .{
//     // Fork `ssh -G <args>` to resolve aliases / Match blocks /
//     // ProxyJump from ~/.ssh/config. Disable if ssh isn't on
//     // $PATH, you don't want the (typically <100ms) latency, or
//     // you don't use ssh aliases.
//     // .use_ssh_g = true,
//     //
//     // Path to ssh used for -G resolution.
//     // .ssh_binary = "ssh",
//     //
//     // `→ ssh:user@host` segment in the status bar while
//     // a recognised subprocess is active.
//     // .show_in_statusbar = true,
//     //
//     // Style of the subprocess statusbar segment.
//     // .segment_style = .{ .dim = true, .fg = 6 },
//     //
//     // Per-target incognito list — commands typed at matching
//     // targets are dropped (same as a manual Ctrl+Shift+I). Match
//     // is on the resolved frame name (e.g. "prod@bastion",
//     // "prod/apps/db", "nginx", "sudo").
//     // .incognito_targets = &.{
//     //     "prod@bastion.example.com",
//     //     "prod/apps/db",
//     // },
// };
