# security guard — design + status

Status: **All V1 + V2 slices shipped (atty side + sidecar + ONNX SLM + eBPF + OSV + AtomMatcher + atom fetcher + threat-level accumulator + opt-in auto-Block).** The implementation-status table below is the authoritative record; the design-rationale sections that follow describe what each slice DOES, in the order they shipped. Treat any "Next" / "queued" wording further down as historical context for that slice — not as current roadmap.

## Implementation status

| Slice  | What lands                                                                              | PR    | Status         |
|--------|-----------------------------------------------------------------------------------------|-------|----------------|
| V1     | `src/modules/security_guard.zig` — Tier-1 in-proc patterns + trust cache + confirm UX. | #104  | ✅ merged       |
| V2-A   | `atty-guard/` Rust sidecar — UDS server, JSON-line protocol, Tier-1 mirror, threat map. | #105  | ✅ merged       |
| V2-D   | `src/modules/security_guard/uds_client.zig` — atty queries the sidecar before in-proc.  | #106  | ✅ merged       |
| V2-E   | Hardened system-daemon unit (`atty:atty`) + idempotent installer.                       | #108  | ✅ merged       |
| V2-C-trait | `Tier2Backend` trait + `StubBackend` + `HeuristicBackend` (+ `--tier2` flag).        | #109  | ✅ merged       |
| V2-B-skel | eBPF LSM + execve tracepoint kernel C + Rust loader skeleton.                         | #110  | ✅ merged       |
| atty-side | PID-tree threat marking + 🛡 statusbar indicator (`Context.shell_pid`).               | #112  | ✅ merged       |
| V2-B-impl | libbpf-rs LSM attach + BPF map write-through.                                         | #113  | ✅ merged       |
| Data file | Shared `flagged_npm.txt` + scoped-pkg `@` fix + Shai-Hulud seeds.                     | #114  | ✅ merged       |
| Updates   | `flagged_urls.txt` matcher + bundle/sign update-channel design.                       | #115  | ✅ merged       |
| V2-C-onnx | Configurable ONNX SLM via tract — SecureBERT 2.0 / Qwen2.5-Coder.                     | #116  | ✅ merged       |
| AF_ALG    | eBPF `sys_enter_socket` tracepoint — copy.fail-class kernel-LPE detector.             | #117  | ✅ merged       |
| V2-F      | Live OSV.dev lookup for `npm install <pkg>` Tier-1 misses.                            | #118  | ✅ merged       |
| V2-G      | AtomMatcher — Aho-Corasick over `flagged_atoms.txt` for thousand-scale patterns.       | #119  | ✅ merged       |
| V2-H      | Sliding-context-window for SLM — `OnnxBackend` gets ±N bytes around the AC hit.        | #120  | ✅ merged       |
| V2-I      | Baked-in atom fetcher — periodic refresh of `atoms.system.txt` (runtime overlay; bundled `flagged_atoms.txt` stays compile-time embedded). One-shot `--update-atoms-now` + cron-style `--atoms-update-interval`. GTFOBins shipped first.                  | #121  | ✅ merged       |
| V2-I-2    | Sigma source (sanitized) — extend the V2-I fetcher with the SigmaHQ Linux rule corpus. (LOLBAS prototyped + dropped: Windows-native, not useful for Linux shells.) | #125  | ✅ merged       |
| V2-J      | Threat-level accumulator — multi-hit Tier-1 + Tier-2 SLM combined via independent-probability math; multi-atom commands surface a higher combined confidence. | #126  | ✅ merged       |
| V2-J-2    | Auto-Block escalation — opt-in TOML knob `[accumulator] block_threshold` lets the accumulator escalate Warn → Block when combined confidence reaches the configured value AND ≥ 2 distinct signals fired; atty side renders a red `REFUSED` line + clears readline instead of prompting. | #127  | ✅ merged       |

The MVP behaviour (Tier-1 + trust cache + confirmation banner) is fully usable today, with or without the sidecar. V2-G+H+I are the pattern-matching scale + intelligence-freshness improvements that close the gap between curated bundles and live disclosures.

### What V2-G brings (this PR)

- `aho-corasick` crate compiled at startup from a new `flagged_atoms.txt` data file (one atom per line, comment + blank-line stripping).
- Single DFA scans the typed command in O(n) regardless of atom count — scales to thousand-pattern corpora.
- Atom hits reuse `Category::CurlPipeSh` as the verdict bucket today; the verdict reason carries the actual atom string so the banner is still informative. A dedicated `Category::AtomMatch` is queued for the protocol bump that adds the V2-J accumulator's combined score.
- Runs AFTER the precise regex Tier-1 as a broad-signal fallback: high-confidence verdicts (curl|sh = 1.0, flagged-URLs = 0.9, npm = 1.0, bash -c base64 = 1.0) win; the AtomMatcher's medium-confidence 0.6 Warn only fires when nothing more specific matched. Inverting this would silently demote the strongest signals we have.
- Same data-file pattern as `flagged_npm.txt` / `flagged_urls.txt` on the Rust side (`include_str!`). The Zig in-proc security_guard reads its own pattern set today; a Zig-side AtomMatcher reading the same `flagged_atoms.txt` via `@embedFile` is queued for V2-J when the in-proc corpus grows past linear-scan range.

### What V2-H brings (next)

- `OnnxBackend::classify` accepts an optional hint offset (the AC match position from V2-G).
- When set, extracts `[-64, +256]` chars around the hit, tokenises ONLY that window, dropping the prompt-chrome prefix.
- ~3-5× token reduction on long pipeline-stuffed commands; brings Qwen2.5-Coder-1.5B inference comfortably under the 50 ms UDS-client timeout.
- No-hint fallback path keeps the existing whole-command tokenisation for clean commands.

### What V2-I brings (after V2-H)

- Daemon CLI surface: `atty-guard --update-atoms-now` (one-shot
  refresh + exit) + `atty-guard --atoms-update-interval 6h`
  (background cron-style refresh thread).
- Source selection via `--atoms-sources gtfobins,sigma` (default
  = the full enabled set):
  - **GTFOBins** (`functions.shell` from per-binary YAML manifests).
  - **Sigma rules** (sanitized — `CommandLine|contains` selections
    from the SigmaHQ Linux corpus).
- Sources NOT in the fetcher:
  - **OSV** is a separate live-lookup feature (`osv-live`) that
    runs per-classify, not a bulk dump. Different code path.
  - **LOLBAS** was prototyped and dropped — Windows-native, didn't
    surface Linux shell IOCs in practice.
- Atomic tmp+rename install into `$STATE_DIRECTORY/atoms.system.txt`
  (default `/var/lib/atty-guard/atoms.system.txt`); ownership-gated
  load on the daemon side.
- Feature-gated `atoms-fetch` so a build without the network deps
  still ships.

After V2-G/H/I land, the threat-level accumulator across the AC + precise + SLM tiers becomes the natural follow-up (V2-J).

### What V2-J brings (#126)

- `AtomMatcher::find_all` — walks every non-overlapping atom hit in a command, not just the first. With the GTFOBins + Sigma corpus (#125) a single command realistically carries 2-5 atoms.
- `Tier1::classify_all` — collects EVERY signal that fired (regex layers + flagged-URL substrings + npm + bash-c-base64 + all atom hits) instead of returning the first match.
- Independent-probability accumulator: `p_combined = 1 - prod(1 - p_i)`. Three atoms at 0.6 each combine to 0.936; a single regex hit at 1.0 stays 1.0. Saturates toward 1.0 monotonically as more signals fire.
- SLM second-stage gating moved to `combined_conf < 0.9` — when Tier-1 already has enough signal we skip the ~50 ms SLM call.
- Verdict policy in Phase 1: no auto-`Block` escalation. The accumulator boosts the confidence NUMBER while the verdict still comes from the primary hit. Auto-block lands in V2-J-2.
- Banner reason for multi-hit: `"N signals fired: <reason1>; <reason2>; ..."` — each layer's attribution preserved.

### What V2-J-2 brings (this PR)

- Opt-in TOML knob:

  ```toml
  [accumulator]
  block_threshold = 0.95
  ```

  When set, the accumulator escalates `Warn` → `Block` if the combined confidence reaches `block_threshold` **AND** at least 2 distinct signals fired. Default `None` = no auto-block (preserves V2-J Phase 1 behaviour exactly).

- The minimum-hit-count guard (`hits.len() >= 2`) is **non-configurable** on purpose: a single regex hit at confidence 1.0 (e.g. `curl … | sh`) always stays `Warn`, so users keep the [y]/[t]/cancel choice for unambiguous-but-legitimate shapes like the canonical install-script pattern.

- Recommended values when opting in:
  - `0.95`: ≥ 5 atoms OR atom + high-conf SLM. Low false-positive risk.
  - `0.99`: practically requires 8+ atoms OR multiple high-conf rules. Very low false-positive risk.

- Input validation: `Classifier::with_block_threshold` only accepts `(WARN_THRESHOLD, 1.0]` and finite values. Out-of-range or NaN inputs degrade to `None` with a stderr warning at daemon start. A threshold at-or-below the Warn floor would auto-Block every multi-hit indiscriminately (defeats the [y]/[t]/cancel intent), so the strict lower bound rejects e.g. `block_threshold = 0.5`.

- **atty side — actually refuses on Block.** `src/modules/security_guard.zig::queryDaemon` branches on verdict before arming: Safe → forward, Warn → arm the `[y]/[t]/cancel` banner (unchanged), **Block → write a red `REFUSED — <reason>` line, mark the shell PID Critical via `setThreatLevel`, and signal the caller to clear readline (`Ctrl+U` via `.replace = "\x15"`).** No follow-up keystroke; the user types something fresh. Trust-cache hits short-circuit BOTH paths so previously-trusted exact matches still bypass even with auto-Block enabled — operators who want auto-Block to override prior trust must clear the trust file. Render style is `Config.refused_style` (bold red 8-color by default; distinct from `warning_style`'s dim italic).

## TL;DR — three-component architecture

Per external review (2026-05-18): the system is **three** cooperating pieces with a hard kernel/user-space split. No custom kernel module — eBPF LSM hooks handle the kernel side.

```
              ┌──────────────────────────────────────────────────────────┐
              │                       USER SPACE                          │
              │                                                          │
   keystrokes │   ┌─────────────────┐   ringbuf    ┌─────────────────┐  │
  ────────────┼──▶│   atty (PTY     │◀────────────▶│  atty-guard     │  │
              │   │   proxy + ctx)  │   UDS RPC    │  (Rust/Go SLM   │  │
              │   │                 │              │   daemon)        │  │
              │   │  threat-level   │              │                  │  │
              │   │  state machine  │              │  Tier 1: regex   │  │
              │   │                 │              │  Tier 2: ONNX-   │  │
              │   │  marks PIDs as  │              │  SLM (~5ms)      │  │
              │   │  high-risk in   │              │                  │  │
              │   │  eBPF map       │              │                  │  │
              │   └────────┬────────┘              └────────▲─────────┘  │
              │            │ PID → threat level             │            │
              │            ▼                                │            │
              │   ┌─────────────────────────────────────────┴────────┐   │
              │   │           lsm/bprm_check_security             │   │
              │   │             tracepoint sys_enter_execve           │   │
              │   ╞══════════════════════════════════════════════════╡   │
              ├───┤             KERNEL SPACE (eBPF)                  ├───┤
              │   │                                                  │   │
              │   │  - intercept every execve from atty's child tree │   │
              │   │  - check eBPF hash map: parent PID high-risk?    │   │
              │   │  - LOW:  log to ringbuf, async path              │   │
              │   │  - HIGH: synchronous hold, return EPERM if SLM   │   │
              │   │          says block                              │   │
              │   └──────────────────────────────────────────────────┘   │
              └──────────────────────────────────────────────────────────┘
```

**Why three components instead of one daemon:**

1. **atty (PTY proxy, Zig)** — sees the user's intent at the typed-line level (pipes, redirections, full command structure) before the kernel gets it. Decides the *threat level* per-command from a deterministic state machine. Pushes that decision into an eBPF hash map keyed by PID.
2. **eBPF LSM (kernel, no custom module)** — backstops the PTY blind spot. When `npm install` forks a `postinstall` script that spawns a reverse shell, that shell never goes through atty's PTY — but its execve goes through the kernel's `bprm_check_security` LSM hook. The eBPF program attaches via `SEC("lsm/bprm_check_security")`, checks the parent PID against atty's high-threat map, and routes accordingly: log async OR hold sync.
3. **atty-guard (user-space daemon, Rust/Go)** — runs the ONNX-compiled SLM. eBPF can't run an SLM (verifier rejects floating-point + >512B stack + bounded instruction count). Daemon reads the ringbuf, runs Tier 1 regex first, falls through to Tier 2 SLM. Replies sync (for sync-mode commands) or async-flags via D-Bus / notify-send.

**Why this hybrid is the right shape:** the PTY proxy's threat-level state machine selects the inspection mode dynamically. A `git status` runs through the async path with zero added latency. An `npm install` flips that PID's tree to synchronous-block mode, so every child process is gated through the SLM. Best of both worlds — fast normal path, hard wall when context goes risky.

## Threat-level matrix (PTY proxy state machine)

The PTY proxy escalates the threat level based on the typed line BEFORE the kernel sees it. This decision then propagates to eBPF via the PID map.

| Trigger category               | Examples                                            | Threat level | Inspection mode                |
|--------------------------------|-----------------------------------------------------|--------------|--------------------------------|
| Benign / standard              | `ls`, `grep`, `cd`, `git log`, `vim`, `cat`         | Low          | Asynchronous / passive         |
| Interpreted code execution     | `python -c …`, `perl -e …`, `node -e …`, `awk 'BEGIN{system(…)}'` | High | Sync (block & analyze)         |
| Blind piping                   | `curl … \| sh`, `wget -O- … \| bash`                | Critical     | Sync (block & analyze)         |
| Supply-chain operations        | `npm install`, `pip install`, `cargo build`, `go get` | High        | Sync watch on child processes   |
| Obfuscation signatures         | `base64 -d`, `xxd -r`, nested `$(…)`, `eval $IFS…`  | Critical     | Sync (block & analyze)         |
| Privileged escalation          | `sudo`, `doas`, `su`                                | Escalate     | Inherit child threat level     |
| Container / VM escape vectors  | `docker run --privileged`, mount calls              | Critical     | Sync                           |

When a command from a higher-threat category fires, the proxy marks both the parent PID **and the whole future child PID tree** as high-risk in an eBPF map (`BPF_MAP_TYPE_HASH`). The eBPF LSM program reads that map on every subsequent `execve` and applies the matching mode.

## The two modes spelled out

### Async — low threat, default

PTY proxy passes the line through immediately, ringbuf'd to atty-guard for after-the-fact audit. eBPF logs the execve, does not block. The SLM may still flag it 5ms later — daemon responds via `kill -9` to the PID or namespaces it. Acceptable trade: an exploit gets a few milliseconds of runtime before being killed. Zero perceptible latency on the happy path.

### Sync — high/critical threat

eBPF LSM hook **stalls** the execve syscall: submits the command to the ringbuf, then blocks until atty-guard replies. Daemon runs Tier 1 (regex/YARA) → Tier 2 (SLM). Outcomes:
- **green light** → kernel allows the syscall.
- **red light** → kernel returns `-EPERM`; userland sees a "permission denied" with an atty-issued explanation in the statusbar.
- **escalate** → prompt the user via overlay; require MFA or `[a]llow once`.

Cost: ~5–15ms per execve in this mode. Acceptable for the deliberately-risky commands; the user already knows they're doing something dangerous when running `curl … | bash`.

## Edge cases the architecture has to handle

### 1. Terminal escape sequence obfuscation

An attacker can write `rm -rf /; echo<BS><BS><BS>safe` so the raw PTY stream contains `rm -rf /` but the visible line says `safe`. atty's PTY proxy must read the **cooked** post-escape-processing line (which it already does via `line_state` + OSC 133 `;A`/`;B` capture), not the raw keystroke bytes. Pin this contract in tests.

### 2. Non-PTY bypass (reverse shell over socket)

If an attacker gets a foothold and runs commands via a socket without a PTY allocation, atty's proxy can't see them. The eBPF backstop catches this: any process whose ancestor chain does NOT include atty's PID gets the **untrusted-by-default** treatment — all execves routed to sync inspection until proven safe.

### 3. PID-tree explosion on `make -j`

A user running `make -j32` legitimately spawns thousands of processes. Default-low for `make` keeps them async. But if the user typed `make -j32` inside a session already marked high (e.g. inside an `npm install` postinstall), the eBPF map still flags the children. The state machine needs to recognise this case so build jobs don't melt the SLM with 32× parallel inferences.

### 4. atty-guard down / not installed

The PTY proxy's Tier 1 (in-proxy regex / pattern matchers) still runs. eBPF without the daemon falls back to **log-only** (the ringbuf has nothing to read it, so kernel never blocks). System remains usable; security degrades gracefully to "atty proper's static patterns only." Same as if the user opted not to install atty-guard at all.

### 5. State sharing between proxy and daemon

Two viable shapes:
- **Single combined process**: atty + atty-guard as one binary. Easier state sharing (in-memory). Breaks the suckless ethos. Larger binary. Heavier teardown.
- **Separate processes** with UDS RPC (our current lean): cleaner failure isolation, daemon can be upgraded independently, classifier can run in its own namespace / seccomp jail. Adds IPC round-trip cost (~50µs — negligible).

Open question: who owns the eBPF map ownership/lifetime? Proposed: **atty-guard** owns the map (created on daemon start, persists across atty sessions). atty's PTY proxy queries the daemon over UDS for a "set threat level for PID X" RPC. Keeps the eBPF lifecycle in one place.



## Motivation

Supply-chain attacks are increasingly mundane and high-blast-radius:

- **Shai-Hulud**-style npm worms — compromised packages pull credentials + republish themselves.
- `curl … | sh` installers — common pattern, attacker-controlled servers can return arbitrary code; no audit trail.
- typosquatted packages — `npm install requests` (no such pkg, attacker registers `requests` to ship malware).
- `bash -c "<base64>"` in pasted commands — opaque payload, often LLM-suggested or copy-pasted from compromised docs.
- build-time Rust / Go / npm scripts running with full user privileges.

atty sits between the terminal and the shell — it sees **every keystroke before the shell** and **every byte the shell outputs**. That's the right place for a tripwire because:

- pre-exec intercept is possible (block before Enter reaches the shell).
- post-exec process tracking already exists (`subprocess_tracker` via OSC 133 `;C`).
- existing modules (`guardrail`, `llm`) already supply the building blocks.

## Threat surface atty can plausibly defend against

| Attack class                          | atty visibility           | Plausible response               |
|---------------------------------------|---------------------------|----------------------------------|
| `curl … \| sh` from attacker URL      | command pre-Enter         | fetch URL, LLM-review body, gate |
| `npm install <typosquat>`             | command pre-Enter         | local bad-pkg list + LLM         |
| package manager arbitrary `postinstall` | post-Enter, post-fork    | SIGSTOP child + LLM + resume     |
| `bash -c "<base64>"`                  | command pre-Enter         | decode + LLM-review              |
| `pacman -U <url>`                     | command pre-Enter         | URL allowlist                    |
| Compromised build-time script         | shell output (limited)    | LLM-review on output keywords    |

Out of scope (atty isn't an EDR):

- post-execution network calls
- kernel-level / syscall-level tampering
- credentials theft from outside the shell

## Two-tier design

### Tier 1 — static fast-path (extends `src/modules/guardrail.zig`)

Pattern match the typed line in `onInput` before Enter reaches the shell.

```zig
// pseudocode in modules/security.zig
pub fn onInput(rt, ctx, input) !Action {
    if (!containsEnter(input)) return .forward;
    const line = ctx.line.current();
    if (matches_curl_pipe_sh(line)) return triggerConfirm(rt, .curl_pipe_sh, line);
    if (matches_unsafe_install(line)) return triggerConfirm(rt, .unsafe_install, line);
    if (matches_base64_bash_c(line)) return triggerConfirm(rt, .opaque_bash_c, line);
    return .forward;
}
```

- `.replace_commit = "\x15"` to abort the input + render a confirmation overlay (same trick guardrail uses).
- Confirmation overlay shows: what was matched, what category, "[y]es / [n]o / [t]rust this URL / [a]nalyze with LLM".

Patterns live in `src/defaults.zig` as a struct, user-overridable in `src/config.zig` — the project's standard config pattern.

### Tier 2 — encoder SLM classifier (NOT a generative LLM)

Per external review (Gemini, 2026-05-16): a generative LLM here would be the wrong tool. Generative models produce text token-by-token at 100ms–2s latency — unusable inline. The right architecture is an **encoder-only Small Language Model** (SecureBERT 2.0 / CodeBERT family) with a binary classification head outputting Safe/Harmful in **2–15ms** on CPU.

Inputs to the classifier:

- typed command + parsed args (after tokenization-preserving-shell-metachars; see below)
- (for `curl|sh`) the fetched URL body content
- (for `bash -c "<b64>"`) the decoded payload

The classifier returns a probability + binary label. Surfaces:

- safe (high confidence) → silently allow.
- suspicious (low confidence either way) → statusbar segment + `notify-send` + overlay with the matched pattern from Tier 1.
- harmful (high confidence) → block hard; override requires explicit `[a]llow once` action.

**Latency-driven architectural consequence**: at 2–15ms per inference, Tier 2 becomes viable INLINE (pre-Enter), not just on-match. The "fast path skip" gate from earlier drafts may not be needed.

### Tier 2 deployment options (one of the harder questions)

atty is one Zig binary. Bundling an ONNX runtime + a ~50MB quantized model breaks the suckless single-binary ethos and balloons distribution to ~150MB. Three deployment shapes worth considering:

1. **Static rules only in atty proper; `atty-guard` is a separate binary.** atty's security module queries `atty-guard` via Unix domain socket / localhost. User installs the guard separately if they want Tier 2. Preserves "atty is one binary, end of." Probably the right call.
2. **Embed ONNX runtime in atty.** Binary size ~150MB, slow first-startup as model loads. Violates the ethos.
3. **HTTP call to a hosted classifier endpoint.** Privacy concern; introduces network dependency. Hard no for security tooling.

Lean toward (1).

### Optional Tier 3 — post-exec freeze (deferred)

For commands that escape Tier 1+2 (e.g. classifier sidecar down, or running inside an unrecognised subprocess that pre-exec analysis can't see), use OSC 133 `;C` to capture the newly-spawned PID and `SIGSTOP` it while the classifier catches up. Resume on verdict.

Pros: lossless coverage. Cons: ugly UX, racy with the shell's job control.

Defer until Tier 1+2 prove themselves.

## Hooks to use

Already-defined module hooks (see `src/module.zig`):

- `onInput(rt, ctx, input) !Action` — pre-Enter intercept, return `.replace_commit = "\x15"` to abort.
- `onLineCommit(rt, ctx, line)` — post-Enter, line is committed to shell (analysis ride-along).
- `onTick(rt, ctx, elapsed_ms)` — drain LLM verdicts that arrived during the tick.
- `provideGhostText` / `statusText` — surface verdicts visually.

New hooks possibly needed:

- `onSubprocessStart(rt, ctx, pid, name)` — currently only `subprocess_tracker` consumes `;C` edges internally; we'd need a fan-out for the security module to receive them. (Or just bolt onto the existing tracker.)

## Data engineering (the hard part — most of the work lives here)

CVE entries are textual descriptions of bugs, not executable payloads. The model needs to be trained on actual command-line shapes. Sources to compose the dataset:

- **Exploit repositories** — raw payloads from Exploit-DB, Metasploit modules, SecLists. Patterns of reverse shells (`nc -e /bin/sh`), web delivery (`curl … | sh`), memory dumps, kernel exploits.
- **LOLBAS / GTFOBins** — "living off the land" patterns where attackers misuse benign binaries (`certutil.exe` on Windows for arbitrary download; `find -exec` / `awk system()` / `vim -c '!cmd'` on Linux). The actual GTFOBins YAML is grabbable.
- **Synthetic translation via generative LLM** — for each CVE description, prompt a generative model offline to produce ~50 plausible attacker CLI invocations that would exploit it. Doesn't have to be perfect — it's training data variety, not ground truth.
- **Benign baseline** — large corpus of normal sysadmin shell history. Without this the classifier flags every `sudo apt update` as malicious. Sources: GitHub dotfiles repos with bash_history, the `awk`+`grep`+`find` examples from man pages, atty's own (with explicit opt-in) anonymised history corpus.

The labelling is binary {safe=0, malicious=1}. The variety in the training data matters more than the absolute count.

## Tokenization (don't drop the shell metacharacters)

Standard NLP tokenizers (BPE, WordPiece) often strip or merge punctuation. For shell-payload classification, `|`, `;`, `&`, `$`, `\`, `<`, `>`, backticks, redirections are vital signals — they ARE the attack syntax in many cases. Either:

- Use a tokenizer that preserves all printable ASCII as distinct tokens (custom whitespace + char-level for shell metachars).
- Pre-normalize: deobfuscate Base64 (recursively, with bounds), `eval`-wrapping, `\$IFS`-tricks, character-insertion tricks (`c^m^d`), env-var slicing, before tokenization.

The pre-normalization step itself is its own small project (essentially a partial shell parser that doesn't execute).

## Existing infrastructure to lean on

- **`guardrail` module** — same pattern of pre-Enter pattern match + Ctrl+U abort + overlay confirm. Security module should look architecturally similar.
- **`llm` module** — worker thread + mailbox + async verdict surfacing + sanitized env handling (`llm/env.zig` from PR #49) + dialog state machine for confirmation flows.
- **`subprocess_tracker`** — already knows when a recognised launcher started + which kind (`ssh`/`docker exec`/`kubectl exec`/`sudo`/`su`/none).
- **OSC 133** — `;A`/`;B`/`;C`/`;D` give us prompt/command/exit boundaries.
- **`ctx.incognito`** — gate LLM submission so opted-out sessions stay local.

## Config sketch

```zig
// src/defaults.zig — add a new subsystem
pub const Security = struct {
    enabled: bool = false,                       // off by default; opt-in
    static_patterns: bool = true,
    llm_review: enum { off, on_match, always } = .on_match,
    fetch_curl_pipe_sh_body: bool = true,        // network call before exec
    notify_via_libnotify: bool = true,           // notify-send on flag
    trust_cache_path: []const u8 = "~/.cache/atty/security_trust.txt",
    bad_packages_path: []const u8 = "~/.cache/atty/bad_packages.json",
    incognito_disables_llm: bool = true,
};

pub const security: Security = .{};
```

## Open questions

1. **~~Pre-exec latency tolerance~~** — RESOLVED. Encoder SLM at 2–15ms is well below Enter-press perception threshold. Always-on classification is viable.
2. **Curated bad-pkg list source**: GitHub's advisory DB? OSV? A maintained file in the atty-guard repo? Update frequency?
3. **`curl|sh` URL fetch**: atty proper, or atty-guard? Privacy: the requester's IP hits the URL.
4. **Trust cache format**: per-URL-hash like ssh known_hosts? Per-domain? Expiration?
5. **False-positive UX**: a single false-positive a day is roughly equal to a single missed real attack. Calibrate during the beta.
6. **Sidecar vs in-atty SLM** (RESOLVED — sidecar). Confirms the binary-size + ethos argument.
7. **Endpoint vs centralized**: from external review — atty IS the endpoint. Centralized would mean a remote classifier service, which we've ruled out for privacy. Final answer: **endpoint-only, local sidecar**.
8. **Tier 3 (SIGSTOP) plumbing**: only viable if atty knows the child's PID — which it does (from `pty.spawn`), but `;C`-launched grandchildren are harder. Use process groups + pgid?
9. **Sandboxing**: atty's network code (if any) would be new attack surface. Push as much as possible into the sidecar where it can be sandboxed independently (seccomp, namespaces).
10. **`history` module interaction**: should flagged commands be recorded? Yes with a `security_verdict` flag, so users can audit past close-calls. atuin tags could carry the verdict.
11. **Model deployment freshness**: a static model trained at release goes stale as new attack patterns emerge. atty-guard needs a model-update mechanism — signed model bundles fetched via the user's standard package manager? Released alongside atty's release cadence?

## MVP scope (V1 in atty proper)

The smallest useful subset that ships as part of atty:

- **Tier 1 only**, **opt-in** via `config.security.enabled = true`.
- Three patterns: `curl … | sh`, `npm install <pkg>` (with hardcoded tiny bad-pkg list), `bash -c "<long-b64>"`.
- Overlay confirmation with `[y]/[n]/[t]rust`.
- Trust cache: simple line-delimited file of SHA-256 of "category + matched-substring".
- No SLM, no network fetch, no SIGSTOP.

This is one new module (`src/modules/security.zig`) + a new subsystem in `defaults.zig` + tests for the matchers. ~300 LOC ballpark.

## V2 — separate `atty-guard` daemon + eBPF backstop (encoder SLM)

Separate repo / binary, NOT bundled with atty. **Two new pieces ship together** because the eBPF program needs a user-space partner to reach the SLM:

- **`atty-guard`** — sidecar daemon listening on a Unix domain socket at `$XDG_RUNTIME_DIR/atty-guard.sock`. Loads the quantized encoder SLM (SecureBERT 2.0 / CodeBERT, INT8, ONNX runtime). Runs Tier 1 regex first, falls through to Tier 2 SLM. Exposes RPCs:
  - `classify(payload: str) → { label, confidence }`
  - `set_threat_level(pid: u32, level: enum) → ok`
  - `subscribe_ringbuf() → stream of execve events`
- **eBPF object** — shipped with `atty-guard`. Loads at daemon start via libbpf. Pins to `lsm/bprm_check_security` + `tracepoint:syscalls:sys_enter_execve`. Maps:
  - `BPF_MAP_TYPE_HASH` keyed by PID → threat level (written by atty via UDS, read by eBPF on every execve).
  - `BPF_MAP_TYPE_RINGBUF` → execve events to user space.
- **atty's role unchanged from V1** — Tier 1 pattern matchers stay in atty proper. atty queries `atty-guard` over UDS for Tier 2 (the existing query path) AND for setting PID threat level when high-risk commands fire.

Distribution: separate release, optional install. Rust or Go for the daemon (fast, low memory footprint; both have good libbpf bindings). atty proper stays pure Zig with zero ML / eBPF dependencies.

Why separate processes (the user-asked question):

- **Failure isolation** — atty-guard panicking on a malformed model file shouldn't crash the user's terminal session.
- **Cadence** — model retraining + redistribution happens independently of atty's release.
- **Privilege** — atty-guard needs CAP_BPF (and probably CAP_SYS_ADMIN on older kernels) to load LSM programs; atty itself does not. Splitting keeps the high-privilege surface tiny and auditable.
- **Sandboxing** — atty-guard can run under seccomp + a namespace; atty cannot (it needs to spawn the user's shell).

Why NOT bundled:

- Suckless ethos — atty is one Zig binary, end of.
- ONNX runtime + ~50MB model would balloon atty's distribution to ~150MB.
- eBPF tooling on the build path would tie atty to libbpf headers, kernel versions, BTF, etc.

## V3+ stretch

- **URL fetch** for `curl|sh` before classification.
- **OSV / GitHub Advisory DB** integration for package lookups.
- **`notify-send`** integration for desktop alerts.
- **Telemetry knob** (off by default) for the community to crowdsource bad patterns.
- **Tier 3 → subsumed by eBPF backstop** (V2). The eBPF LSM hook does what SIGSTOP-on-`;C` was meant to do, more cleanly, before the syscall completes. Keep the V1 SIGSTOP fallback as the "atty-guard is down" degradation mode.
- **Process-group threat propagation**: when atty marks a PID high-threat, automatically propagate to its `setpgid` group so even daemonised escapes (double-fork to PPID=1) stay flagged via the eBPF map.
- **MFA / hardware-key confirmation** on `Critical`-tier blocks — couple atty's overlay confirm with a yubikey touch for the highest-stakes cases.

## Anti-patterns (things to NOT build)

- Anything that requires running **atty** as root. (`atty-guard` is allowed to need CAP_BPF — that's why it's a separate binary.)
- A **custom kernel module**. eBPF LSM hooks cover the same ground without the stability / panic / version-skew risk.
- Hard-coded URLs / blocklists baked into the binary — must be configurable + updatable without recompile (counter to the suckless ethos, but security data is unavoidably time-sensitive).
- Telemetry that leaves the user's machine without explicit opt-in.
- ~~A separate daemon process~~ — *revised*: atty proper is one binary, end of. `atty-guard` IS a separate process by design (see V2). The reason isn't dogma — it's the BPF-privilege boundary, model footprint, and failure isolation.

## Prior art / inspiration

- **shadowtoes** / **safesh** — bash wrappers that warn on dangerous patterns. Limited because they live INSIDE the shell.
- **`Doppler` / `tg-safe-shell`** — env-scoped credential guards. Different surface but similar UX considerations.
- **macOS Gatekeeper** prompts — the model of "block, explain, allow override with reason". Worth aping.
- **Burp Suite intruder** confirmation dialogs — gold-standard pattern for "we've identified something risky, here's what we know".

## Design history — original "next step" plan

The text below was the V1 → V2 roadmap as written before the slices
shipped. The implementation-status table at the top of this document
is the authoritative current state; this section is preserved for
the design rationale (why each slice was queued in that order) but
the actual delivery shipped all of these and more.

**V2-B (now: #110 + #113 + #117 + #144):** `aya-rs` LSM hook + ringbuf consumer. Reasoning: the atty UDS surface is stable (#104→#105→#106 merged). Adding BPF on top doesn't churn the protocol; it just swaps the threat-map backing from `Mutex<HashMap>` to a real BPF map and adds an async ringbuf consumer to the daemon. Build path needs `CAP_BPF` + a recent kernel (5.15+ for the `lsm/bprm_check_security` hook) — only the user-installed sidecar gains those caps; atty itself stays unprivileged.

**V2-C (now: #109 + #116):** `Tier2Backend` trait in `classifier.rs` with an `Onnx` impl gated behind a Cargo feature flag. Model bundle distribution shipped via separate releases.

**V2-E (now: #108 + #140):** auto-launch from atty proper. Originally framed as a `systemd --user` unit; landed as a hardened system-daemon unit (`atty:atty`) so detection state lives outside the user's write reach.

## External input archive

- 2026-05-16: Gemini reframed Tier 2 from "generative LLM" to "encoder SLM classifier" (SecureBERT 2.0 / CodeBERT family) — 10–100× latency drop changes the architecture (inline becomes viable). Also recommended: synthetic translation of CVEs → CLI payloads, GTFOBins/LOLBAS scraping, shell-metacharacter-preserving tokenization, INT8 quantization + ONNX runtime for sub-15ms inference. Endpoint-deployment (not centralized) as the right shape for atty.
- 2026-05-18: Three-component split crystallised. **No custom kernel module** — eBPF LSM hooks (`lsm/bprm_check_security`, `tracepoint:sys_enter_execve`) cover the kernel-side interception cleanly. Reviewer's split:
  - `atty` (PTY proxy) sees command intent at typed-line time, decides threat level via deterministic state machine.
  - `atty-guard` (Rust/Go daemon) owns the eBPF map + ringbuf + ONNX SLM. eBPF can't host the SLM (verifier rejects FP / >512B stack / unbounded loops).
  - Hybrid async/sync mode selection driven by the PTY proxy's threat-level decision — low-risk commands stay async (zero perceptible latency); high-risk commands stall the execve syscall until the SLM verdicts.
  - PID-tree marking: `npm install`'s child process tree inherits high-threat status via the eBPF hash map, closing the PTY blind spot for `postinstall` payloads that fork detached processes.
  - Two backstop edges: terminal-escape obfuscation (use cooked line, not raw keystrokes) + non-PTY bypass (eBPF defaults processes-without-atty-ancestor to high-threat).
