#!/usr/bin/env python3
"""A scripted OpenAI-compatible model on loopback for plumbing tests.

No real provider is called. Each chat request is logged as one JSON line to
the log file. Replies follow a tiny script: when the latest message is a tool
result, answer in text; when the prompt contains "use tool <name>", call that
tool once; "CALL <tool> <json>" calls a tool with exact arguments; "LONGREPLY <kilobytes>" streams a long reply;
"slowly" delays the reply by 5 s, "PAUSE <ms>" by that long; "RATELIMIT" answers 429 like OpenAI's rate
limit; otherwise reply with fixed text.
Usage: fake-model.py <port> <log-file>
"""
import json, re, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, LOG = int(sys.argv[1]), sys.argv[2]

def reply_for(body):
    messages = body.get("messages", [])
    last = messages[-1] if messages else {}
    if last.get("role") == "tool":
        return {"content": "The tool said: " + str(last.get("content"))[:200]}
    text = json.dumps(last.get("content", ""))
    raw = last.get("content") if isinstance(last.get("content"), str) else ""
    if "CALL " in raw:  # explicit: CALL <tool> <json arguments>
        name, args = raw.split("CALL ", 1)[1].split(" ", 1)
        return {"tool": name, "arguments": json.loads(args.split("\n<turn-context>")[0])}
    tools = [t["function"]["name"] for t in body.get("tools", []) if t.get("type") == "function"]
    for name in tools:
        if f"use tool {name}" in text or f"use tool {name.split('__')[-1]}" in text:
            return {"tool": name, "arguments": {"text": "hello from the fake model"}}
    return {"content": "Hello from the fake model."}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            return self.send_json({"object": "list", "data": [{"id": "fake-model", "object": "model", "owned_by": "agneta"}]})
        self.send_error(404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        with open(LOG, "a") as log:
            log.write(json.dumps({"path": self.path, "body": body}) + "\n")
        if not self.path.endswith("/chat/completions"):
            return self.send_error(404)
        last = json.dumps(body.get("messages", [])[-1:])
        if "RATELIMIT" in last:  # a provider's rate limit, as OpenAI reports it
            payload = json.dumps({"error": {"message": "Rate limit reached for requests. Please try again in 20s.",
                                            "type": "requests", "code": "rate_limit_exceeded"}}).encode()
            self.send_response(429)
            self.send_header("Content-Type", "application/json")
            self.send_header("Retry-After", "20")
            self.send_header("x-ratelimit-reset-requests", "20s")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        reply = reply_for(body)
        if "slowly" in last:
            time.sleep(5)  # long enough for a cancel test to interrupt
        if pause := re.search(r"PAUSE (\d+)", last):
            time.sleep(int(pause.group(1)) / 1000)  # an exact delay in milliseconds
        usage = {"prompt_tokens": 42, "completion_tokens": 7, "total_tokens": 49}
        if "tool" in reply:
            delta = {"role": "assistant", "tool_calls": [{"index": 0, "id": "call_1", "type": "function",
                     "function": {"name": reply["tool"], "arguments": json.dumps(reply["arguments"])}}]}
            finish = "tool_calls"
        else:
            delta = {"role": "assistant", "content": reply["content"]}
            finish = "stop"
        if body.get("stream") and "LONGREPLY" in last:
            # A long reply in many chunks (megabytes, for flow-control tests): "LONGREPLY <kilobytes>".
            kilobytes = int(re.search(r"LONGREPLY (\d+)", last).group(1))
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            piece = "x" * 1024
            for n in range(kilobytes):
                chunk = {"choices": [{"index": 0, "delta": {"role": "assistant", "content": piece} if n == 0 else {"content": piece}}]}
                chunk.update({"id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": int(time.time()), "model": "fake-model"})
                self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            for chunk in ({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}, {"choices": [], "usage": usage}):
                chunk.update({"id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": int(time.time()), "model": "fake-model"})
                self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for chunk in ({"choices": [{"index": 0, "delta": delta}]},
                          {"choices": [{"index": 0, "delta": {}, "finish_reason": finish}]},
                          {"choices": [], "usage": usage}):
                chunk.update({"id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": int(time.time()), "model": "fake-model"})
                self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
        else:
            message = dict(delta)
            self.send_json({"id": "chatcmpl-fake", "object": "chat.completion", "created": int(time.time()), "model": "fake-model",
                            "choices": [{"index": 0, "message": message, "finish_reason": finish}], "usage": usage})

    def send_json(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
