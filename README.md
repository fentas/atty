<h3 align="center">
	<img width="240" alt="atty" src="./logo.svg">
</h3>

<p align="center">
	<a href="https://github.com/fentas/atty/stargazers">
		<img alt="Stargazers" src="https://img.shields.io/github/stars/fentas/atty?style=for-the-badge&logo=starship&color=C9CBFF&logoColor=D9E0EE&labelColor=302D41"></a>
	<a href="https://github.com/fentas/atty/releases/latest">
		<img alt="Latest release" src="https://img.shields.io/github/v/release/fentas/atty?style=for-the-badge&logo=github&color=F2CDCD&logoColor=D9E0EE&labelColor=302D41"/></a>
	<a href="https://github.com/fentas/atty/actions/workflows/ci.yml">
		<img alt="CI" src="https://img.shields.io/github/actions/workflow/status/fentas/atty/ci.yml?style=for-the-badge&logo=github&logoColor=D9E0EE&labelColor=302D41&color=A6E3A1&label=ci"></a>
	<a href="https://atty.sh">
		<img alt="atty.sh" src="https://img.shields.io/badge/site-atty.sh-89DCEB?style=for-the-badge&logo=googlechrome&logoColor=D9E0EE&labelColor=302D41"></a>
	<a href="https://ziglang.org/">
		<img alt="Zig 0.16" src="https://img.shields.io/badge/zig-0.16.0-F2CDCD?style=for-the-badge&logo=zig&logoColor=D9E0EE&labelColor=302D41"></a>
</p>

&nbsp;

<p align="left">

`atty` is a **Suckless-style PTY proxy** in Zig. It sits between your terminal emulator (Ghostty, Alacritty, kitty…) and your shell, and composes its middleware — autosuggestions, a dangerous-command guardrail, LLM command generation, click-to-open paths/URLs, an optional eBPF security sidecar — **at compile time** instead of loading plugins at runtime. Edit `src/config.zig`, recompile. That is the entire configuration model.

No runtime config file. No plugin loader. No daemon you didn't ask for. Disabled modules contribute **zero bytes** to the binary, and the per-keystroke hot path does **zero heap allocation**. The result is a single musl-static binary with no runtime dependencies — the published image is ~14 MB.

</p>

It does, roughly, four things:

- **🛸 Autosuggestions** — fish-style dim/italic ghost text from your [Atuin](https://github.com/atuinsh/atuin) or shell-native history, served off a worker thread. Accept with `→`, a word at a time, or pick from a multi-row list.
- **🤖 LLM command mode** — type `#: deploy the staging stack`, press `Alt+A`, and the model writes the command onto your prompt for you to review. Or `Alt+S` for a multi-turn dialog that proposes → runs → reads the output → proposes again.
- **🛡 Safety rails** — a built-in guardrail that makes you confirm `rm -rf /`, `curl … | sh`, fork bombs, and friends. Plus an optional `atty-guard` sidecar with a tiered classifier, live CVE lookups, and eBPF kernel-side enforcement.
- **🖱 A nicer terminal** — click a `file:line` in compiler output to open it in `$EDITOR`; click a URL to open it (host-whitelisted); a DECSTBM status bar; incognito mode; OSC 133 awareness; the kitty keyboard protocol on by default.

It runs *alongside* your existing setup — a layer outside the shell, not a replacement for starship, oh-my-zsh, or atuin ([how they compare](https://atty.sh/faq/)).

<p align="center">
	<a href="https://atty.sh"><b>▶&nbsp; Watch the 30-second demo on atty.sh</b></a>
</p>

&nbsp;

#### Disclaimer

An LLM primarily generated this code, and it has not yet been fully reviewed by a human maintainer. It may contain bugs, security issues, or non-idiomatic patterns. The safety net is a large suite (**1,200+ unit tests** plus PTY integration and scripted-terminal end-to-end scenarios) and an adversarial review loop on every PR — but treat the security features as defense-in-depth, not a guarantee.

&nbsp;

### 🐚 What it feels like

```text
$ git switch feature/auth-refactor                 ← you typed "git switch f"; the rest is
             ^^^^^^^^^^^^^^^^^^^^^                    dim italic ghost text. Press → to accept.

$ #: find every file over 100MB under /var, newest first    ← type intent, press Alt+A
$ find /var -type f -size +100M -printf '%T@ %p\n' | sort -rn   ← atty writes the command; you review, then Enter

$ rm -rf /home/work/
! atty guardrail: rm -rf invocation [user]
        line: rm -rf /home/work/
        press Enter again to confirm, any other key to cancel.

$ curl https://sketchy.sh/install.sh | sh
✗ atty security_guard: REFUSED — remote-fetch-and-execute
        match: curl … | sh                          ← daemon Block verdict; readline cleared
```

A live, animated demo lives on [atty.sh](https://atty.sh).

&nbsp;

### 🚀 Install

Three paths. Pick the one that matches how much you want.

```bash
# 📦 Just the binary — no toolchain, no source, default modules.
#    Resolves arch, verifies sha256, chmods, hints at $PATH.
curl -fsSL https://bin.atty.sh | sh

# 🛠  The Suckless way — get the source, edit src/config.zig, compile.
#    Bootstraps Zig if you don't have it. Prompts before opening config.
curl -fsSL https://get.atty.sh | sh
```

Both install to `~/.local/bin/atty` and honor `INSTALL_DIR=…`. The binary installer also honors `ATTY_VERSION=…`; the source installer honors `ATTY_SRC=…`, `ATTY_NONINTERACTIVE=1`, and `REPO_URL=…`. Pre-built targets: `linux-x86_64`, `linux-aarch64` (musl-static). The source flow works anywhere Zig 0.16 does.

The two installers above ship the **proxy only**. For the full supply-chain protection — the `atty-guard` Rust daemon, the tiered classifier, eBPF LSM hooks, and the auto-updating threat-atom corpus — clone the repo and run:

```bash
sudo make install GUARD_FEATURES=tier2-onnx,osv-live,atoms-fetch,ebpf
```

That sets up the `atty:atty` system user, installs and starts the systemd unit, and drops in the eBPF override. Then `sudo usermod -aG atty $USER` and open a new shell. See [getting-started](https://atty.sh/getting-started/) for the per-flag breakdown and [operator-workflow](https://atty.sh/operator-workflow/) for verification + corpus management.

For containers:

```bash
docker pull ghcr.io/fentas/atty:latest   # multi-arch (amd64/arm64), musl-static
```

#### Make it your terminal's startup command

Ghostty (`~/.config/ghostty/config`):

```
# Ghostty starts atty, which then starts your shell.
command = atty bash
```

Pin the shell explicitly (`atty bash` / `atty zsh` / …) in your terminal config rather than relying on `$SHELL` — when the terminal is what spawns atty, the environment is minimal and `$SHELL` may not be set yet. Or invoke ad-hoc:

```bash
atty                       # spawn $SHELL through the proxy
atty bash                  # spawn bash explicitly
atty zsh -c 'echo hi'      # zsh -c 'echo hi'
```

The first non-flag positional is the shell binary; everything after it is passed verbatim — same convention as `env(1)`. Use `--` only if your shell's name starts with a dash.

#### Detecting atty from your shell

atty injects env vars into every spawned shell. Use them in your `.bashrc`/`.zshrc` to avoid double-wrapping:

```bash
# Wrap only if not already inside atty, and only if it's on PATH
# (so a missing install never locks you out of your shell).
if [[ -z "${ATTY}" ]] && command -v atty >/dev/null; then
    exec atty bash
fi
```

| Variable       | Value                                |
|----------------|--------------------------------------|
| `ATTY`         | `1`                                  |
| `ATTY_PID`     | pid of the atty proxy (parent)       |
| `ATTY_VERSION` | semver string (e.g. `0.1.0`)         |

&nbsp;

### 🛠 Configure

`atty` has no runtime config file. It uses the dwm `config.def.h` / `config.h` split:

- [`src/config.def.zig`](src/config.def.zig) — committed template with commented examples (atty maintains it).
- **`src/config.zig`** — *your* file. Gitignored. `build.zig` copies the template across on first build.
- [`src/defaults.zig`](src/defaults.zig) — the atty-shipped value for every knob.

Edit `src/config.zig`, recompile. Your edits never conflict on `git pull` because the file isn't tracked, and your config only contains what you override — every other knob falls through to `defaults.zig`, so new tunables added upstream just appear. Every subsystem (`proxy`, `ghost`, `terminal`, `keymap`, `statusbar`, `mouse`, `subprocess`) is a struct with per-field defaults; declare only the fields you want different.

```zig
const atty = @import("atty");

// Order = priority. The default tuple is dependency-free: { guardrail, history }.
pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.atuin.configure(.{
        .suggestion_ttl_ms  = 0,          // 0 = fish-style (no fade)
        .sync_after_records = 10,
    }),
    atty.modules.history.configure(.{}),  // shell-native fallback
};

// Tweak the ghost style; turn on a 3-row suggestion pick list (Ctrl+1..9).
pub const ghost: atty.Ghost = .{
    .style      = atty.style.presets.muted_italic,
    .list_count = 3,
};

// Rebind the accept key if Right / End / Ctrl+F isn't your taste.
pub const keymap: atty.Keymap = .{
    .bindings = &.{
        .{ .bytes = atty.keymap.key("Tab"), .action = .ghost_accept },
    },
};
```

Track a config outside the repo with `zig build -Dconfig=/path/to/mine.zig` (or `make CONFIG=/path/to/mine.zig build`).

&nbsp;

### 🧩 Modules

| Module | Status | What it does |
|--------|--------|--------------|
| [`guardrail`](src/modules/guardrail.zig)       | **default** | Confirm / block / warn on dangerous lines (`rm -rf /`, `dd`, `mkfs`, `curl\|sh`, fork bombs). Per-rule behavior; author-aware (treats user-typed vs LLM-injected lines differently). |
| [`history`](src/modules/history.zig)           | **default** | Ghost suggestions + recording straight to your shell's own `~/.bash_history` / `~/.zsh_history`. No daemon, no extra binary. |
| [`atuin`](src/modules/atuin.zig)               | opt-in | Fish-style autosuggestions from your [Atuin](https://github.com/atuinsh/atuin) DB via a worker thread; records on Enter; newest-first. |
| [`llm`](src/modules/llm/)                       | opt-in | `#: intent` → command, single-shot or multi-turn dialog. Local Ollama, agentic CLIs (Claude/Gemini), or any OpenAI-compatible endpoint. |
| [`security_guard`](src/modules/security_guard/)| opt-in | Pre-Enter classifier for high-risk shapes (`curl\|sh`, bad npm packages, base64 payloads); standalone or as a client to the `atty-guard` daemon. |
| [`mouse_links`](src/modules/mouse_links/)      | opt-in | Left-click a `path:line` token in output → `$EDITOR +LINE 'path'` injected into your prompt. |
| [`mouse_urls`](src/modules/mouse_urls/)        | opt-in | Left-click a URL → open in the browser, gated by a per-host trust posture (`never` / `whitelist_only` / `ask_each`). |

Ordering matters: short-circuiting modules (guardrail, and `mouse_urls` in `ask_each` mode) go first; place `mouse_urls` **before** `guardrail` so its banner keys win. `mouse_links` / `mouse_urls` need `mouse.enabled = true`. Every option is documented inline in [`config.def.zig`](src/config.def.zig) and on [atty.sh/modules](https://atty.sh/modules/).

<details>
<summary><b>Popular combinations</b> — each block is a complete <code>src/config.zig</code> (pick one)</summary>

**Power user** — atuin suggestions + guardrail + LLM, with a status bar:

```zig
const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.atuin.configure(.{}),
    atty.modules.history.configure(.{}),     // local fallback
    atty.modules.llm.configure(.{
        // Local Ollama is auto-discovered ($LLM_API_BASE → $OLLAMA_HOST).
        // Or pin an agentic CLI preset:
        // .provider = atty.modules.llm.providers.claude_sonnet_4_6,
    }),
};
pub const statusbar: atty.StatusBar = .{ .enabled = true };
```

**Click-to-open** paths and URLs (note `mouse_urls` before `guardrail`):

```zig
const atty = @import("atty");

pub const mouse: atty.Mouse = .{ .enabled = true };
pub const modules = .{
    atty.modules.mouse_urls.configure(.{
        .mode = .whitelist_only,
        .url_whitelist = &.{ "github.com", "*.github.com", "docs.zig.dev" },
    }),
    atty.modules.mouse_links.configure(.{}),  // editor from $EDITOR / $VISUAL
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{}),
};
```

**Security stack** (needs the `atty-guard` daemon for full coverage):

```zig
const atty = @import("atty");

pub const modules = .{
    atty.modules.security_guard.configure(.{
        .enabled            = true,
        .daemon_socket_path = "/run/atty-guard/atty-guard.sock",
    }),
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{}),
};
```

</details>

&nbsp;

### 🤖 LLM command mode

Type your intent behind the `#: ` prefix (it's the shell comment character, so a missed dispatch is a silent no-op — never an executed command), then pick how you want it handled:

```text
$ #: roll back the last migration and re-seed the dev db
        └── Alt+A → one command on your prompt, you press Enter
        └── Alt+S → a dialog: atty proposes a step, runs it, reads the output, proposes the next
        └── Alt+Shift+S → same, but each step auto-runs after a short abort window
```

| Key | Mode |
|-----|------|
| `Alt+A` | **single** — turn the `#:` intent into one command on your line |
| `Alt+S` | **dialog** — multi-turn exec → observe → propose loop (uses OSC 133 to read command output) |
| `Alt+Shift+S` | **auto** — dialog that auto-runs each step |
| `Alt+C` / `Alt+Shift+C` | inline chat panel (shell stays visible) / full-screen chat overlay |
| `Alt+M` | cycle model / provider |
| `Alt+Shift+R` | recall a past dialog into the panel (opens the picker from the prompt) |
| `Alt+r` | *(in chat)* resend / regenerate the last prompt |
| `Alt+T` | *(in chat)* toggle auto-exec |
| `Alt+H` | LLM help |
| `Ctrl+Shift+X` | cancel the active LLM action |

*(in chat)* keys act on an open chat surface (`Alt+C` / `Alt+Shift+C`); the rest work straight from the prompt.

**Providers.** Three flavors, switchable per config (or per mode via `providers[]`, cycled with `Alt+M`):

```zig
// Local, zero-config — discovered via $LLM_API_BASE, then $OLLAMA_HOST + "/v1".
atty.modules.llm.configure(.{}),

// An agentic CLI you already have logged in (atty never sees the token):
atty.modules.llm.configure(.{ .provider = atty.modules.llm.providers.claude_sonnet_4_6 }),
atty.modules.llm.configure(.{ .provider = atty.modules.llm.providers.gemini_2_5_pro }),

// Hosted OpenAI (needs $OPENAI_API_KEY):
atty.modules.llm.configure(.{ .provider = atty.modules.llm.providers.openai }),
```

Presets ship for `claude_sonnet_4_6` / `claude_opus_4_7` / `claude_haiku_4_5` / `claude_default`, `gemini_2_5_pro` / `gemini_2_5_flash`, `openai`, `ollama` — or roll your own with the `claudeCode` / `geminiCli` / `simonwLlm` factories, or any prompt-in/text-out CLI via `.{ .subprocess = … }`. atty can hand the model lightweight context (OS, cwd, git branch — never secrets, suppressed in incognito). Full reference: [atty.sh/llm](https://atty.sh/llm/).

&nbsp;

### 🛡 Security: guardrail + the `atty-guard` sidecar

Two layers, both opt-in beyond the default guardrail.

**`guardrail`** (default) is a pure in-process, author-aware pattern check. Each rule's behavior is `confirm` (Enter again), `confirm_once`, `block`, or `warn`, and rules can be scoped to user-typed or LLM-injected lines. Add a couple with `.extra_rules`, or replace the whole policy with `.rules`.

**`atty-guard`** is a Rust system daemon (`atty:atty`, UDS, hardened systemd unit) that the `security_guard` module queries on every Enter, falling back to in-proc rules if it's unreachable. It backstops what the in-proc check can't do on its own and adds real threat intelligence:

- **Tiered classifier** — Tier-1 regex + an Aho-Corasick scan over a threat-**atom** corpus (GTFOBins + sanitized Sigma); optional Tier-2 SLM (ONNX: SecureBERT 2.0 / Qwen2.5-Coder, pure-Rust `tract`).
- **Multi-hit accumulator** — combines every signal that fires into one confidence score, so death-by-a-thousand-cuts attacks (Shai-Hulud-style) escalate; opt-in auto-**Block** above a threshold.
- **eBPF LSM** — a kernel-side `bprm_check_security` hook gates a flagged process's children at `execve` (configurable **enforcement depth**: `one_level` default / `ancestry` / `propagate_on_fork`; plus `AF_ALG` + `sched` fork/exit tracepoints), backstopping a payload that bypasses atty's readline. See the [threat model](https://atty.sh/operator-workflow/) for exactly what it does and doesn't stop, and [benchmarking](https://atty.sh/benchmarking/) for the per-mode overhead.
- **Security profiles** *(opt-in)* — by default detection is *proxy-only* (the commands you type). Set `[profile] mode` to watch the terminal's whole process subtree: `audit` surfaces flagged runtime execs that bypass the prompt (a compromised dependency spawning `… → exploit`), `session` also reactively kills them. See [security profiles](https://atty.sh/security-profiles/) for the ladder (`prompt`/`audit`/`session`/`strict`/`lockdown`/`smart`) and the honest detection-vs-prevention contract.
- **Live CVE lookups** — `npm install <pkg>` hits OSV.dev when the local list misses.
- **Auto-updating atoms + per-UID trust** — corpus refreshed from upstream (with opt-in commit pinning); trust decisions persist per user via a sudo-mediated CLI.

At the prompt you see one of three outcomes:

```text
Safe   → forwarded, no friction
Warn   → ! banner: [y]es once · [a]llow always · [t]rust · [B]lock host · any key cancels
Block  → ✗ red REFUSED line, readline cleared (and eBPF EPERMs its direct children)
```

Manage trust and atoms with `sudo atty-guard atoms|urls|session|trust …` (SO_PEERCRED-gated, per-UID), and dump buffered warn events to scrollback with `Alt+Shift+W`. Cargo features `tier2-onnx`, `osv-live`, `atoms-fetch` (the `make install-guard` default) and `ebpf` (opt-in) gate each capability. Setup + verification: [operator-workflow](https://atty.sh/operator-workflow/).

&nbsp;

### ⌨️ Keys, status bar & surfaces

Default global bindings (overridable in `config.keymap`):

| Key | Action |
|-----|--------|
| `→` / `End` / `Ctrl+F` / `Ctrl+Tab` | accept the ghost suggestion |
| `Ctrl+→` | accept one word of the suggestion |
| `Ctrl+1…9` / `Esc+1…9` | pick from the multi-row suggestion list (`ghost.list_count`) |
| `Ctrl+Shift+I` (or `Alt+i`) | toggle **incognito** — stops recording; suppresses LLM context |
| `Ctrl+Shift+D` | delete the highlighted history match |
| `Alt+Shift+W` | dump buffered security warnings to scrollback |

- **Status bar** (`statusbar.enabled`, off by default) reserves rows at the bottom via DECSTBM — it never slims the shell's reported size, so inner TUIs (nvim/lazygit/k9s) still size correctly. Modules contribute segments joined by ` │ `; incognito shows a 🔒.
- **Mouse** (`mouse.enabled`, off by default) emits the SGR-1006 DECSET trio and routes clicks to `mouse_links` / `mouse_urls`; once a TUI takes the alt-screen, atty steps out of the way so vim/htop keep their own mouse handling.
- **Kitty keyboard protocol** is on by default (disambiguate flag), so keys like `Ctrl+Shift+I` and the `Alt+letter` LLM bindings work on Ghostty/kitty/foot/WezTerm; legacy encodings are used as a fallback elsewhere.
- **OSC 133** prompt markers are auto-detected (closes the history-recall gap and powers LLM dialog output capture). Wire your shell with `eval "$(atty init bash)"`; diagnose with `eval "$(atty doctor)"`.

&nbsp;

### ✍️ Writing a module

A module is a Zig type — typically returned from `configure(comptime cfg) type` — implementing some subset of these hooks. Missing hooks are statically eliminated.

| Hook                 | Called when                                | Hot path |
|----------------------|--------------------------------------------|----------|
| `attach` / `detach`  | once at startup / shutdown                 | no       |
| `onInput`            | every keystroke from the user              | **yes**  |
| `onOutput`           | every chunk from the shell                 | **yes**  |
| `onLineCommit`       | Enter on a non-empty, certain line         | no       |
| `onTick`             | on `poll()` timeout (default 100 ms)       | no       |
| `onMouseClick`       | an SGR-1006 click event                    | yes      |
| `onAction`           | a keymap `Action` fires                    | yes      |
| `provideGhostText` / `provideGhostList` | atty wants an overlay / pick list | yes |
| `statusText`         | the status bar repaints                    | no       |

```zig
// Uppercase every keystroke.
pub fn configure(comptime _: Config) type {
    return struct {
        pub const Runtime = struct { buf: [256]u8 = undefined };
        pub fn attach(_: std.mem.Allocator) !Runtime { return .{}; }
        pub fn detach(_: *Runtime) void {}
        pub fn onInput(rt: *Runtime, _: *m.Context, in: []const u8) m.Error!m.Action {
            for (in, 0..) |b, i| rt.buf[i] = std.ascii.toUpper(b);
            return .{ .replace = rt.buf[0..in.len] };
        }
    };
}
```

Hot-path rules: no allocations, no blocking I/O (use a worker thread + cv-signalled mailbox, like atuin does). Full walkthrough: [docs/modules.md](docs/modules.md) / [atty.sh/modules](https://atty.sh/modules/).

&nbsp;

### 🧪 Build from source

```bash
mise use zig@0.16.0           # any Zig 0.16.0 install works
zig build                     # → ./zig-out/bin/atty
zig build test --summary all  # 1,200+ unit tests
zig build itest               # real-PTY integration tests
zig build e2e                 # scripted-PTY scenarios + visual grid diff
```

Or via Make (`make help` lists every target):

```bash
make build          # ReleaseSafe, atty + atty-guard
make test itest e2e
make install        # → ~/.local/bin/atty (+ guard with GUARD_FEATURES=…)
make link           # symlink ~/.local/bin/atty → ./zig-out for live dev
make docker         # local image
```

Releases are cut by release-please (merge the `chore(release):` PR → tag → CI cross-compiles musl x86_64 + aarch64 and pushes the multi-arch `ghcr.io/fentas/atty` image).

&nbsp;

### 🗺️ Documentation

Full docs live at **[atty.sh](https://atty.sh)**:

| | |
|---|---|
| [Getting started](https://atty.sh/getting-started/) | install paths, first config, the full security stack |
| [Architecture](https://atty.sh/architecture/) | the proxy loop, dispatcher, line-state model |
| [Modules](https://atty.sh/modules/) | per-module reference + how to write your own |
| [LLM mode](https://atty.sh/llm/) | `#:` flow, modes, providers |
| [Operator workflow](https://atty.sh/operator-workflow/) | `atty-guard` + atoms + eBPF + `atty doctor` |
| [FAQ](https://atty.sh/faq/) | how atty differs from oh-my-zsh / starship / atuin |

&nbsp;

### 🎯 Roadmap

- [x] ~~OSC 133 prompt-marker awareness~~ — shipped in `src/osc133.zig`; auto-detects `;A`/`;B`/`;C`/`;D` markers.
- [ ] Atuin daemon socket backend (replace the subprocess fallback once IPC stabilises)
- [ ] Bracketed-paste detection (suppress ghost text during a paste burst)
- [ ] Ring buffer for `onOutput` parsers that span read boundaries
- [ ] BSD / macOS support (currently Linux-only; the PTY dance needs Darwin glue)

&nbsp;

### 🤝 Contributing

PRs welcome. The flow is **feat/fix conventional-commit PR → release-please opens a release PR → merging it cuts a tag and ships binaries**. Details and PR-title rules in [CONTRIBUTING.md](CONTRIBUTING.md). Before pushing: `make fmt && make test`.

&nbsp;

### 📜 License

[MIT](LICENSE). Use it, ship it, fork it, sell it — keep the copyright notice intact.

&nbsp;

### ❤️ Gratitude

- [Atuin](https://github.com/atuinsh/atuin) — the history daemon this proxies for.
- [Suckless](https://suckless.org) — for the *config.h, recompile, ship* aesthetic this whole project apes.
- [GTFOBins](https://gtfobins.github.io) & [Sigma](https://github.com/SigmaHQ/sigma) — the threat-atom corpus atty-guard draws from.
- [Ghostty](https://ghostty.org), [Alacritty](https://alacritty.org), [kitty](https://sw.kovidgoyal.net/kitty/) — the terminals atty plays in front of.
- [Zig](https://ziglang.org) — for making `inline for` + `@hasDecl` a viable plugin model.
- README treatment and release flow lifted from [fentas/b](https://github.com/fentas/b).

&nbsp;

<p align="center">Copyright &copy; 2026-present <a href="https://github.com/fentas" target="_blank">fentas</a></p>
<p align="center"><a href="https://atty.sh"><img src="https://img.shields.io/static/v1.svg?style=for-the-badge&label=atty&message=.sh&logoColor=d9e0ee&colorA=302d41&colorB=89dceb"/></a></p>
