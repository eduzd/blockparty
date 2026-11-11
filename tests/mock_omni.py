#!/usr/bin/env python3
"""A stand-in for Omni Route (OpenAI-compatible) for local Studio AI checks.
POST /v1/chat/completions with Bearer test-omni-key-1234. Saves each request to
/tmp/mock_omni_last.json so the test can check the agent rules reached the AI."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

KEY = "test-omni-key-1234"
LEVEL = {
    "title": "Mock Lava Run", "sky": 1, "spawn": [0, 3, 0], "goal": [0, 3, 40],
    "parts": [
        ["block", 0, 1, 0, 6, 1, 6, 0, 0],
        ["block", 0, 1, 8, 4, 1, 4, 0, 1],
        ["lava", 0, 0.2, 12, 8, 0.4, 3, 0, 4],
        ["block", 0, 1, 16, 4, 1, 4, 0, 6],
        ["ice", 0, 1, 24, 4, 1, 6, 0, 9],
        ["spinner", 0, 2, 24, 8, 0.5, 0.5, 0, 7],
        ["bounce", 0, 1, 31, 3, 0.5, 3, 0, 5],
        ["coin", 0, 3, 16, 1, 1, 1, 0, 5],
        ["block", 0, 1, 40, 6, 1, 6, 0, 2],
    ],
}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        auth = self.headers.get("Authorization", "")
        json.dump({"path": self.path, "auth_ok": auth == "Bearer " + KEY, "body": body}, open("/tmp/mock_omni_last.json", "w"))
        if self.path != "/v1/chat/completions":
            return self._send(404, {"error": {"message": "not found"}})
        if auth != "Bearer " + KEY:
            return self._send(401, {"error": {"message": "Invalid API key"}})
        msgs = body.get("messages", [])
        last = msgs[-1]["content"] if msgs else ""
        content = '{"ok": true}' if "Reply with exactly this JSON" in last else json.dumps(LEVEL)
        model = str(body.get("model", ""))
        retry = "could not be used" in last
        lv = json.dumps(LEVEL, indent=2)
        msg = {"role": "assistant", "content": content}
        finish = "stop"
        if content.startswith('{"ok"'):
            pass
        elif model == "mock-fenced":
            msg["content"] = "Sure! Here is your level:\n```json\n" + lv.replace('"parts": [', '"parts": [ // the course\n') + "\n```\nHave fun!"
        elif model == "mock-trailing":
            msg["content"] = lv.replace("]\n  ]", "],\n  ],")
        elif model == "mock-wrapped":
            msg["content"] = json.dumps({"level": LEVEL})
        elif model == "mock-parts":
            msg["content"] = [{"type": "text", "text": json.dumps(LEVEL)}]
        elif model == "mock-reasoning":
            msg = {"role": "assistant", "content": None, "reasoning_content": "Thinking... " + json.dumps(LEVEL)}
        elif model == "mock-think":
            msg["content"] = "<think>I will make { a level }</think>" + json.dumps(LEVEL)
        elif model == "mock-cut" and "can't be finished" in last:
            msg["content"] = json.dumps(LEVEL)
        elif model == "mock-cut":
            full = json.dumps(LEVEL)
            msg["content"] = full[: full.index('["coin"') + 10]
            finish = "length"
        elif model == "mock-badfirst":
            msg["content"] = json.dumps(LEVEL) if retry else "-- Luau\nlocal Players = game:GetService('Players')"
        elif model == "mock-broken":
            if "can't be finished" in last:
                msg["content"] = json.dumps(LEVEL)
            else:
                b = json.loads(json.dumps(LEVEL)); b["goal"] = [50, 30, 50]; b["parts"].append(["block", 50, 28.5, 50, 4, 1, 4, 0, 2])
                msg["content"] = json.dumps(b)
        elif model == "mock-luau":
            msg["content"] = "-- Luau script\nlocal x = 1"
        elif model == "mock-empty":
            msg["content"] = ""
            finish = "length"
        if model == "mock-sse":
            raw = ""
            full = json.dumps(LEVEL)
            for i in range(0, len(full), 40):
                raw += "data: " + json.dumps({"choices": [{"index": 0, "delta": {"content": full[i:i+40]}}]}) + "\n\n"
            raw += "data: [DONE]\n\n"
            b = raw.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
            return
        self._send(200, {"id": "mock", "model": model, "choices": [{"index": 0, "message": msg, "finish_reason": finish}]})

    def _send(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8777), H).serve_forever()
