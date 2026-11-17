#!/usr/bin/env python3
"""A stand-in app's MCP server (Streamable HTTP, JSON responses) on loopback.

Requires `Authorization: Bearer <token>`. Tools: `echo` returns text and
`swatch` returns a small PNG image. Every request is logged as a JSON line.
Usage: fake-mcp.py <port> <token> <log-file>
"""
import base64, json, struct, sys, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, TOKEN, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]

def png(w=8, h=8, rgb=(47, 95, 122)):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")

TOOLS = [
    {"name": "echo", "description": "Echo text back.", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
    {"name": "swatch", "description": "Return a colour swatch image.", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}},
]

def handle(msg):
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        result = {"protocolVersion": msg["params"].get("protocolVersion", "2025-06-18"), "capabilities": {"tools": {}}, "serverInfo": {"name": "app-fake", "version": "0"}}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        name, args = msg["params"]["name"], msg["params"].get("arguments", {})
        if name == "echo":
            result = {"content": [{"type": "text", "text": "echo: " + str(args.get("text"))}]}
        elif name == "swatch":
            result = {"content": [{"type": "text", "text": "A fjord-blue swatch."}, {"type": "image", "mimeType": "image/png", "data": base64.b64encode(png()).decode()}]}
        else:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "unknown tool"}}
    elif mid is None:
        return None
    else:
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": method}}
    return {"jsonrpc": "2.0", "id": mid, "result": result}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.send_error(405)
    def do_DELETE(self): self.send_response(200); self.end_headers()
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        authorized = self.headers.get("Authorization") == f"Bearer {TOKEN}"
        with open(LOG, "a") as log:
            log.write(json.dumps({"authorized": authorized, "body": json.loads(body or b"null")}) + "\n")
        if not authorized:
            return self.send_error(401)
        msg = json.loads(body)
        replies = [r for r in (handle(m) for m in (msg if isinstance(msg, list) else [msg])) if r]
        if not replies:
            self.send_response(202); self.end_headers(); return
        data = json.dumps(replies if isinstance(msg, list) else replies[0]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Mcp-Session-Id", "fake-session")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
