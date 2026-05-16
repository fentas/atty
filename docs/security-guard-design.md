# security guard — rough outline

Status: **brainstorm**, not committed scope. To be revised together.

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

## V2 — separate `atty-guard` binary (encoder SLM)

Separate repo / binary, NOT bundled with atty:

- Sidecar daemon listening on a Unix domain socket at e.g. `$XDG_RUNTIME_DIR/atty-guard.sock`.
- Loads a quantized SecureBERT 2.0 / CodeBERT classifier (INT8, ONNX runtime).
- Exposes a single RPC: `classify(payload: str) -> { label, confidence }`.
- atty's Tier 1 module queries the socket if present; falls back to static-only if absent.
- Distribution: separate release, optional install. Pure Python initially (fast iteration); Rust/Zig port later if needed.

Why separate: keeps atty's binary small + suckless; keeps the ML pipeline iterable on its own cadence; lets users opt in without enlarging atty.

## V3+ stretch

- **URL fetch** for `curl|sh` before classification.
- **OSV / GitHub Advisory DB** integration for package lookups.
- **`notify-send`** integration for desktop alerts.
- **Telemetry knob** (off by default) for the community to crowdsource bad patterns.
- **Tier 3** SIGSTOP-on-`;C` for post-exec analysis when sidecar is slow/down.

## Anti-patterns (things to NOT build)

- Anything that requires running atty as root.
- Hard-coded URLs / blocklists baked into the binary — must be configurable + updatable without recompile (counter to the suckless ethos, but security data is unavoidably time-sensitive).
- Telemetry that leaves the user's machine without explicit opt-in.
- A separate daemon process — atty is one binary, end of.

## Prior art / inspiration

- **shadowtoes** / **safesh** — bash wrappers that warn on dangerous patterns. Limited because they live INSIDE the shell.
- **`Doppler` / `tg-safe-shell`** — env-scoped credential guards. Different surface but similar UX considerations.
- **macOS Gatekeeper** prompts — the model of "block, explain, allow override with reason". Worth aping.
- **Burp Suite intruder** confirmation dialogs — gold-standard pattern for "we've identified something risky, here's what we know".

## Next step

Talk through MVP scope. If we agree on Tier 1 only + three patterns + trust cache, that's a focused PR in the 200-400 LOC range.

Tier 2 (SLM sidecar) becomes a separate project / repo — `atty-guard` — with its own cadence and dependencies. Tracking issue or design doc once Tier 1 is in.

## External input archive

- 2026-05-16: Gemini reframed Tier 2 from "generative LLM" to "encoder SLM classifier" (SecureBERT 2.0 / CodeBERT family) — 10–100× latency drop changes the architecture (inline becomes viable). Also recommended: synthetic translation of CVEs → CLI payloads, GTFOBins/LOLBAS scraping, shell-metacharacter-preserving tokenization, INT8 quantization + ONNX runtime for sub-15ms inference. Endpoint-deployment (not centralized) as the right shape for atty.
