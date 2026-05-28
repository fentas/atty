"""Raw atty-guard UDS protocol client for sandbox scenarios.

Daemon framing is newline-delimited JSON (server.rs:1177-1178): one
JSON request per line, one JSON response per line. We need a Python
client because scenarios drive RPCs (`set_threat_level`,
`get_threat_level`) that the CLI doesn't expose.
"""
from __future__ import annotations

import json
import socket
from pathlib import Path


DEFAULT_SOCKET = "/run/atty-guard/atty-guard.sock"


def call(method: str, *, socket_path: str = DEFAULT_SOCKET,
         timeout: float = 5.0, **params) -> dict:
    """Send one request, return the parsed response dict.

    Caller's UID is the socket's peer cred — `set_threat_level`
    + cross-UID reads gate on it, so wrap with `as_user` if the
    caller identity matters.
    """
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(timeout)
    try:
        s.connect(socket_path)
        req = {"method": method, **params}
        s.sendall((json.dumps(req) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        return json.loads(buf.decode())
    finally:
        s.close()
