# atty-guard

Sidecar daemon for atty's `security_guard` module. V2-A scope: UDS RPC server + Tier-1 regex classifier + in-memory PID threat map. V2-B (separate PR) adds the eBPF LSM hook backstop; V2-C wires the encoder-SLM Tier-2 classifier.

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

### `onnx` (V2-C, not in this PR)

Encoder SLM (SecureBERT-class quantized INT8) via the `ort` crate. Latency target ≤ 15 ms/inference. Will be feature-gated behind a Cargo feature so the default build stays small.

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

| Stage | Lands                                              | Status         |
|-------|----------------------------------------------------|----------------|
| V2-A  | This crate — UDS + Tier-1 + in-mem threat map.     | This PR.       |
| V2-B  | libbpf-rs LSM hook + ringbuf consumer + real map.  | Follow-up.     |
| V2-C  | ONNX SLM in `classifier::tier2`.                   | Follow-up.     |
| V2-D  | Auto-launch from `atty init` snippet; health-ping. | Follow-up.     |
