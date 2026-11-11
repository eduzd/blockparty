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
        if not self.path.endswith("/chat/completions"):
            return self._send(404, {"error": {"message": "not found"}})
        if auth != "Bearer " + KEY:
            return self._send(401, {"error": {"message": "Invalid API key"}})
        msgs = body.get("messages", [])
        last = msgs[-1]["content"] if msgs else ""
        content = '{"ok": true}' if "Reply with exactly this JSON" in last else json.dumps(LEVEL)
        self._send(200, {"id": "mock", "model": body.get("model"), "choices": [{"index": 0, "message": {"role": "assistant", "content": content}}]})

    def _send(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8777), H).serve_forever()
