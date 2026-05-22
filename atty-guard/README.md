# atty-guard

Sidecar daemon for atty's `security_guard` module. **What's shipped today:**

- **V2-A** UDS RPC server, JSON-line protocol, atty:atty system-user post-#140.
- **V2-D** Tier-1 regex classifier mirroring atty's in-proc patterns, with multi-hit V2-J threat accumulator + opt-in V2-J-2 auto-Block escalation.
- **V2-B** eBPF LSM hook + execve/AF_ALG tracepoints (opt-in via `--features ebpf` + `install.sh --with-ebpf`). Replaces the in-memory PID map with a `BPF_MAP_TYPE_HASH` so kernel-side checks see the same threat state.
- **V2-C** Tier-2 ONNX SLM classifier (opt-in via `--features tier2-onnx`, pure-Rust `tract-onnx` backend, SecureBERT 2.0 / Qwen2.5-Coder INT8).
- **V2-F** Live OSV.dev lookup for `npm install <pkg>` (opt-in via `--features osv-live`).
- **V2-I** Atom corpus auto-update from GTFOBins + SigmaHQ (opt-in via `--features atoms-fetch`, with opt-in operator pinning at `/etc/atty-guard/atoms.pins.toml` — see [docs/security-guard-updates.md](../docs/security-guard-updates.md)).

See [docs/security-guard-design.md](../docs/security-guard-design.md) in the atty repo for the three-component architecture.

## Build

```sh
cd atty-guard
cargo build --release
```

The release binary lands at `target/release/atty-guard` (~2 MiB; uses libc + serde + regex).

## Run

```sh
./atty-guard
# atty-guard: listening on /run/atty-guard/atty-guard.sock
```

CLI flags:
- `--socket <path>` — override the bind path. Default: `/run/atty-guard/atty-guard.sock` (created with the right `atty:atty` ownership by the systemd unit's `RuntimeDirectory=atty-guard`). For dev runs as a regular user, pass `--socket /tmp/atty-guard-dev.sock`.
- `-v` / `--verbosity <0|1|2>` — quiet / info (default) / debug.
- `--print-features` — emits one compiled Cargo feature per line, then exits. Used by `atty doctor` to detect eBPF / ONNX / OSV / atom-fetch support definitively.
- Subcommands `atoms` / `urls` / `session` / `trust` — sudo-mediated trust-state CLI. See `atty-guard --help`.

The socket is mode `0660`, `atty:atty` owned — users in the `atty` group connect; co-tenant users not in the group can't.

### system daemon (post-#140)

atty-guard runs as a dedicated `atty:atty` system user. `contrib/install.sh` (re-exec's under sudo automatically) creates the user/group, drops `contrib/atty-guard.service` into `/etc/systemd/system/`, populates `/var/lib/atty-guard/`, and `daemon-reload && enable --now`s the unit.

```sh
sudo ./contrib/install.sh
# or via the top-level Makefile:
sudo make install-guard [GUARD_FEATURES=tier2-onnx,osv-live,atoms-fetch,ebpf]
```

When `ebpf` is in `GUARD_FEATURES`, the installer drops in `/etc/systemd/system/atty-guard.service.d/ebpf.conf` (CAP_BPF + SystemCallFilter widening + `ExecStart=...--enable-ebpf`). Pass `--with-ebpf` directly to `install.sh` for the same effect; `--without-ebpf` removes the drop-in on a re-install.

WHY system daemon (not systemd-user, the original V2-D shape): atom + URL + trust state influences detection. A user-writable trust file is a DOS vector (a process running as `$USER` could poison atoms with common commands and force the operator to disable atty-guard). `atty:atty`-owned state under `/var/lib/atty-guard/` keeps mutations outside the user's reach; mutations go through `sudo atty-guard atoms/urls/...` so admin intent is required.

The unit ships full systemd hardening (`NoNewPrivileges`, `ProtectSystem=strict`, `RestrictAddressFamilies=AF_UNIX`, syscall filter, etc.). See `contrib/atty-guard.service` for the full list.

To talk to the daemon from your user account:

```sh
sudo usermod -aG atty $USER
# log out + back in (or `newgrp atty` for a single shell)
```

To uninstall:

```sh
sudo systemctl disable --now atty-guard
sudo rm -f /usr/local/bin/atty-guard /etc/systemd/system/atty-guard.service
sudo rm -rf /etc/systemd/system/atty-guard.service.d /var/lib/atty-guard
sudo userdel atty 2>/dev/null || true
sudo groupdel atty 2>/dev/null || true
```

### Manual run (for development / debugging)

```sh
./target/release/atty-guard -v 2     # verbose logging to stderr
```

## Protocol

JSON-line over the UDS — one request per `\n`-terminated line, one response per response line. Connections persist; pipeline requests with distinct `id`s and match replies.

### Requests

```jsonc
// Health probe.
{ "id": 1, "method": "health" }

// Classify a typed command.
{
  "id": 2,
  "method": "classify",
  "command": "curl https://x.com/install.sh | sh",
  "context": {
    "pid": 12345,        // optional — source shell PID
    "shell": "bash",     // optional — bash / zsh / fish / …
    "incognito": false   // optional — defaults false
  }
}

// Set a PID's threat level (atty calls this when the PTY proxy
// decides a typed line warrants high-risk inspection of children).
{ "id": 3, "method": "set_threat_level", "pid": 12345, "level": "high" }

// Read back a PID's current threat level.
{ "id": 4, "method": "get_threat_level", "pid": 12345 }
```

### Responses

```jsonc
// Health.
{ "id": 1, "type": "health", "version": "0.1.0" }

// Classify — Tier-1 hit.
{
  "id": 2,
  "type": "classify",
  "verdict": "warn",            // safe / warn / block
  "category": "curl_pipe_sh",   // none / curl_pipe_sh / npm_unsafe_install /
                                // bash_c_base64 / pid_high_threat
  "confidence": 1.0,
  "reason": "remote-fetch-and-execute (`curl … | sh`)",
  "matched": "curl https://x.com/install.sh | sh"
}

// set_threat_level / unknown.
{ "id": 3, "type": "ok" }

// get_threat_level.
{ "id": 4, "type": "threat_level", "level": "high" }

// Protocol error (invalid JSON, unknown method, …).
{ "id": 0, "type": "error", "message": "invalid request: missing field `command`" }
```

### Categories

| Category             | When it fires                                                                                                                  |
|----------------------|-------------------------------------------------------------------------------------------------------------------------------|
| `curl_pipe_sh`       | `curl`/`wget`/`fetch` piped into `sh`/`bash`/`zsh`/`fish`/`dash`/`ksh`.                                                          |
| `npm_unsafe_install` | `npm`/`pnpm`/`yarn` install of a name on the small hardcoded flagged list (Shai-Hulud, event-stream, ua-parser-js, …).         |
| `bash_c_base64`      | `bash`/`sh`/`zsh -c <quoted-arg>` where `<quoted-arg>` is ≥40 chars AND ≥90% base64 alphabet — the classic encoded-payload tell. |
| `pid_high_threat`    | Source PID is in the threat map at `high`/`critical`. Returned EVEN when Tier-1 says safe, so atty escalates.                  |

## Tier-2 backend

Tier-2 is pluggable behind the `Tier2Backend` trait. Two impls ship today; an `OnnxBackend` lands with V2-C. Pick with `--tier2 <name>`:

```sh
atty-guard --tier2 stub        # default — always Safe, no extra rules
atty-guard --tier2 heuristic   # additional regex rules beyond Tier-1
```

### `stub`

Returns `Safe` with 0.0 confidence — Tier-1 hits are the only signal that reaches atty. Default for clean opt-in.

### `heuristic`

Adds rules that don't fit Tier-1's "obvious shapes" surface:

| Match                                                            | Confidence | Reason                                                    |
|------------------------------------------------------------------|-----------:|-----------------------------------------------------------|
| `bash <(curl …)`, `sh <(wget …)`                                  | 0.85       | process-substitution wrapping of fetcher → shell          |
| `curl --insecure …` / `-k` / `wget --no-check-certificate …`     | 0.70       | fetcher disables TLS cert validation                      |
| `curl http://192.168.0.1/x.sh`                                    | 0.60       | fetcher targets a bare IP address (no domain)             |
| `chmod +x foo; ./foo`, `chmod +x foo && foo`                      | 0.75       | `chmod +x` followed by execution of the same file         |

All produce `Verdict::Warn` — atty's user still has the `[y]/[t]/cancel` choice, so a false positive only costs one keystroke. Pure CPU, ~µs latency, zero deps beyond `regex`.

### `onnx` (V2-C — shipped, opt-in via `--features tier2-onnx`)

Encoder-SLM Tier-2 classifier (SecureBERT 2.0 / Qwen2.5-Coder INT8) via pure-Rust `tract-onnx`. Latency target ≤ 15 ms/inference. Feature-gated so default builds skip the dep weight; see [docs/security-guard-slm.md](../docs/security-guard-slm.md) for the model loadout + config TOML shape.

## Tests

```sh
cargo test
```

Runs the regex matcher unit tests plus 6 integration tests that spin up a server thread on a tmp socket, round-trip a few requests, and shut down on drop.

## Security model

Current shape (post-#140 system-daemon install):

- **User/group**: dedicated system `atty:atty`, created by
  `contrib/install.sh`. No login shell, no home dir.
- **Socket**: `/run/atty-guard/atty-guard.sock`, mode `0660`,
  owned `atty:atty`. Users connect by joining the `atty` group
  (`sudo usermod -aG atty $USER` + re-login). Per-connection
  authorization via SO_PEERCRED reads the connecting peer's
  EUID at accept-time. Mutating RPCs that touch persistent
  state (`atoms add/remove`, `urls allow/block`, etc.) require
  EUID=0 — operators reach them via `sudo atty-guard ...`,
  which re-execs the CLI and connects back over the same
  socket with root credentials. Per-UID writes are scoped to
  the target UID's state directory regardless of who's root.
- **State**: persisted under `/var/lib/atty-guard/` —
  `commands.trusted.txt` (atom + URL trust hashes), plus
  per-UID `users/<uid>/atoms.user.txt` and
  `urls.decisions.txt`. All mutations go through the
  sudo-mediated CLI; the daemon itself enforces EUID=0 on
  the writes via SO_PEERCRED. The system atom corpus
  (`atoms.system.txt`) is ownership-gated at load: the daemon
  refuses to read it when metadata doesn't show `atty:atty`.
  Other state files rely on `0640` perms (atty:atty owned)
  plus SO_PEERCRED on the write path. State survives daemon
  restarts; PID-based threat marks do not (held in-memory
  only).
- **Network**: opt-in. Default build features `osv-live` +
  `atoms-fetch` need outbound HTTPS. The shipped systemd unit
  hard-locks the daemon out of the network (`PrivateNetwork=yes`,
  `RestrictAddressFamilies=AF_UNIX`); `install.sh` auto-installs
  a `network.conf` drop-in that lifts both when those features
  are detected via `--print-features`. Operators can opt out
  (`--without-network`) or override (`--with-network`).
- **eBPF**: opt-in via `--with-ebpf`. Drops in
  `AmbientCapabilities=CAP_BPF CAP_PERFMON`,
  `SystemCallFilter=bpf perf_event_open`, and
  `--enable-ebpf` on `ExecStart`. Without the feature compiled
  in OR without the drop-in, the daemon runs V2-A in-memory
  only (no kernel enforcement).
- **Single-instance**: BSD `flock` on `<socket>.lock` prevents
  a second daemon from clobbering the live one's socket.
- **Resource bounds**: server caps `max_concurrent_connections`
  (default 64) and `idle_read_timeout_secs` (default 30s).
  Configurable via `[server]` in the daemon's TOML config.

### History

The original V2-A daemon (PR #105) ran as the invoking user with
a `0600` socket, no persistence, and no network. PR #140 moved it
to a dedicated system user so the trust state lives outside the
user's write reach (a process running as `$USER` poisoning atom
files would otherwise be a DOS vector). PRs #141-#147 layered on
the sudo-mediated CLI for mutations, per-UID atom overlays, and
in-memory session trust mirrored to disk.

## Roadmap

| Stage | Lands                                                   | Status         |
|-------|---------------------------------------------------------|----------------|
| V2-A  | This crate — UDS + Tier-1 + in-mem threat map.          | ✅ shipped (#105) |
| V2-D  | atty-side UDS client — atty queries this daemon.        | ✅ shipped (#106) |
| V2-B  | `aya-rs` LSM hook + ringbuf consumer + BPF threat map.  | ⏳ next        |
| V2-C  | ONNX SLM in `classifier::tier2` (SecureBERT-class).     | ⏳ after V2-B  |
| V2-E  | Auto-launch from atty + system unit packaging.          | ✅ shipped (#140) |
