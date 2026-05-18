# atty-guard

Sidecar daemon for atty's `security_guard` module. **Shipping today (V2-A + V2-D):** UDS RPC server, JSON-line protocol, Tier-1 regex classifier mirroring atty's in-proc patterns, in-memory PID → threat-level map. **Coming next:** V2-B adds the eBPF LSM hook backstop (replaces the in-memory map with a `BPF_MAP_TYPE_HASH`), V2-C wires the encoder-SLM Tier-2 classifier (SecureBERT-class, ONNX-INT8, ≤15 ms/inference).

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
# atty-guard: listening on /run/user/1000/atty-guard.sock
```

CLI flags:
- `--socket <path>` — override the bind path. Default: `$XDG_RUNTIME_DIR/atty-guard.sock`, falling back to `/tmp/atty-guard-<uid>.sock` if `XDG_RUNTIME_DIR` is unset.
- `-v` / `--verbosity <0|1|2>` — quiet / info (default) / debug.

The socket file is created with mode `0600` so co-tenant users on the same host can't probe the classifier.

### systemd user unit (recommended)

```ini
# ~/.config/systemd/user/atty-guard.service
[Unit]
Description=atty security guard sidecar
After=default.target

[Service]
ExecStart=%h/.local/bin/atty-guard
Restart=on-failure
RestartSec=2
# Lock down — daemon does no FS writes, no network, needs only the socket.
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
RestrictAddressFamilies=AF_UNIX

[Install]
WantedBy=default.target
```

```sh
systemctl --user enable --now atty-guard
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

## Tier-2 stub

The encoder-SLM classifier is currently a stub that always returns `Safe` with 0.0 confidence. V2-C will replace it with an ONNX runtime + a quantized SecureBERT-class model. The protocol surface is stable — adding Tier-2 doesn't change request/response shapes, only the verdict distribution.

## Tests

```sh
cargo test
```

Runs the regex matcher unit tests plus 6 integration tests that spin up a server thread on a tmp socket, round-trip a few requests, and shut down on drop.

## Security model

- The daemon runs as your user — no `CAP_BPF` required for V2-A.
- The socket is `0600`, so only your user can connect.
- No network sockets; no file writes outside the UDS path.
- No persistence — restart loses the threat map (intentional for V2-A; V2-B's BPF map becomes the source of truth).

## Roadmap

| Stage | Lands                                                   | Status         |
|-------|---------------------------------------------------------|----------------|
| V2-A  | This crate — UDS + Tier-1 + in-mem threat map.          | ✅ shipped (#105) |
| V2-D  | atty-side UDS client — atty queries this daemon.        | ✅ shipped (#106) |
| V2-B  | `aya-rs` LSM hook + ringbuf consumer + BPF threat map.  | ⏳ next        |
| V2-C  | ONNX SLM in `classifier::tier2` (SecureBERT-class).     | ⏳ after V2-B  |
| V2-E  | Auto-launch from atty + systemd-user unit packaging.    | ⏳             |
