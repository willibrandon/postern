#!/usr/bin/env python3
"""Drive a postern binary through one LSP session over stdio.

Usage: stdio_smoke.py PATH_TO_POSTERN

Opens a broken postgresql.conf, expects diagnostics and a hover, then shuts
the server down. Exits non-zero when any step fails, so CI can run it on each
platform before the editor tests.
"""

import io
import json
import os
import subprocess
import sys
import tempfile
import time
from typing import Any

Message = dict[str, Any]

binary = sys.argv[1]
workdir = tempfile.mkdtemp()
path = os.path.join(workdir, "postgresql.conf")
with open(path, "w", encoding="utf-8") as handle:
    handle.write("port =\nshared_buffers = 128QB\nlisten_addreses = '*'\n")

process = subprocess.Popen(
    [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
)


def send(message: Message) -> None:
    stdin = process.stdin
    assert stdin is not None
    body = json.dumps(message).encode()
    stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    stdin.flush()


def receive(timeout: float = 60) -> Message:
    stdout, stderr = process.stdout, process.stderr
    assert stdout is not None and stderr is not None
    deadline = time.time() + timeout
    headers = b""
    while not headers.endswith(b"\r\n\r\n"):
        if time.time() > deadline:
            raise TimeoutError("no response from the server")
        chunk = stdout.read(1)
        if not chunk:
            error_output = stderr.read().decode(errors="replace")
            raise EOFError("server closed stdout; stderr: " + error_output[:2000])
        headers += chunk
    lengths = [
        h for h in headers.decode(errors="replace").split("\r\n") if h.lower().startswith("content-length")
    ]
    if not lengths:
        rest = stdout.read1(400) if isinstance(stdout, io.BufferedReader) else b""
        raise ValueError("header block without Content-Length: %r; following bytes: %r" % (headers, rest))
    body = stdout.read(int(lengths[0].split(":")[1]))
    try:
        return json.loads(body)
    except ValueError:
        raise ValueError("body is not JSON; headers %r body %r" % (headers, body[:400]))


def receive_response() -> Message:
    while True:
        message = receive()
        if message.get("method") == "window/logMessage":
            print("log:", message["params"]["message"])
            continue
        return message


uri = "file:///" + path.replace(os.sep, "/").lstrip("/")
send(
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "processId": os.getpid(),
            "rootUri": None,
            "capabilities": {},
            "clientInfo": {"name": "stdio_smoke"},
            "initializationOptions": {"pg": 16},
        },
    }
)
result = receive_response()["result"]
assert result["serverInfo"]["name"] == "postern", result
print("initialize:", result["serverInfo"])

send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
with open(path, encoding="utf-8") as handle:
    text = handle.read()
send(
    {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "postgresql-conf",
                "version": 1,
                "text": text,
            }
        },
    }
)
diagnostics = None
while diagnostics is None:
    message = receive()
    if message.get("method") == "textDocument/publishDiagnostics":
        diagnostics = message["params"]["diagnostics"]
    elif message.get("method") == "window/logMessage":
        print("log:", message["params"]["message"])
for diagnostic in diagnostics:
    print("diagnostic line %d: %s" % (diagnostic["range"]["start"]["line"] + 1, diagnostic["message"]))
assert any("listen_addresses" in d["message"] for d in diagnostics), diagnostics

send(
    {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "textDocument/hover",
        "params": {"textDocument": {"uri": uri}, "position": {"line": 1, "character": 3}},
    }
)
hover = receive_response()["result"]
assert "shared_buffers" in hover["contents"]["value"], hover
print("hover: ok")

# The requests below crashed 0.1.0 when a live server was reachable, because the
# oracle handed back {:ok, map} where the features expected the map.
hba_path = os.path.join(workdir, "pg_hba.conf")
with open(hba_path, "w", encoding="utf-8") as handle:
    handle.write("host all all 0.0.0.0/0 trust\nhost all all 10.0.0.0/8 scram-sha-256\n")
hba_uri = "file:///" + hba_path.replace(os.sep, "/").lstrip("/")
send(
    {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {"uri": hba_uri, "languageId": "pg-hba", "version": 1, "text": open(hba_path).read()}
        },
    }
)
hba_diagnostics = None
while hba_diagnostics is None:
    message = receive()
    if message.get("method") == "textDocument/publishDiagnostics" and message["params"]["uri"] == hba_uri:
        hba_diagnostics = message["params"]["diagnostics"]
    elif message.get("method") == "window/logMessage":
        print("log:", message["params"]["message"])
assert any("shadows it" in d["message"] for d in hba_diagnostics), hba_diagnostics
print("pg_hba diagnostics: ok")

requests: tuple[tuple[int, str, Message], ...] = (
    (10, "textDocument/inlayHint", {"textDocument": {"uri": hba_uri}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 2, "character": 0}}}),
    (11, "textDocument/codeAction", {"textDocument": {"uri": hba_uri}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}}, "context": {"diagnostics": []}}),
    (12, "textDocument/inlayHint", {"textDocument": {"uri": uri}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 3, "character": 0}}}),
    (13, "textDocument/codeAction", {"textDocument": {"uri": uri}, "range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 0}}, "context": {"diagnostics": []}}),
)
for request_id, method, params in requests:
    send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
    reply = receive_response()
    assert "error" not in reply, (method, reply)
    print("%s: ok (%d items)" % (method, len(reply.get("result") or [])))

# An editor that closes the pipe without sending exit must not leave a runtime behind.
second = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert second.stdin is not None and second.stdout is not None
body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"processId": os.getpid(), "rootUri": None, "capabilities": {}}}).encode()
second.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
second.stdin.flush()
second.stdout.read(20)  # wait until the server has answered something
second.stdin.close()
try:
    print("exit after stdin closed:", second.wait(timeout=10))
except subprocess.TimeoutExpired:
    second.kill()
    raise SystemExit("server kept running after its stdin closed")

send({"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": None})
receive_response()
send({"jsonrpc": "2.0", "method": "exit", "params": None})
code = process.wait(timeout=30)
print("exit code:", code)
sys.exit(0 if code == 0 else 1)
