#!/usr/bin/env python3
"""A stand-in for Viper's deploy webhook, for the action's tests.

GET  /webhooks/deploys/<id>/latest  answers the commit in <state>/latest (empty: none yet)
POST /webhooks/deploys/<id>         keeps the body and headers in <state>/body.json and headers.json

Both check X-Viper-Timestamp (within five minutes) and X-Viper-Signature as Viper does (D226,
D354): the hex HMAC-SHA256 of "<timestamp>.<raw body>", or of "<timestamp>.GET <path>" for the
GET, with the token in <state>/token. Writes the port it listens on to <state>/port.
"""
import hashlib
import hmac
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = sys.argv[1]
ENVIRONMENT = "env-1"


def read(name, default=""):
    try:
        with open(os.path.join(STATE, name)) as f:
            return f.read().strip()
    except FileNotFoundError:
        return default


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def signed(self, message):
        timestamp = self.headers.get("X-Viper-Timestamp", "")
        if not timestamp.isdigit() or abs(time.time() - int(timestamp)) > 300:
            return False
        expected = hmac.new(read("token").encode(), f"{timestamp}.".encode() + message, hashlib.sha256).hexdigest()
        return hmac.compare_digest(expected, self.headers.get("X-Viper-Signature", ""))

    def do_GET(self):
        path = f"/webhooks/deploys/{ENVIRONMENT}/latest"
        if self.path != path:
            return self.answer(404, {"ok": False, "error": "No such environment."})
        if not self.signed(f"GET {path}".encode()):
            return self.answer(401, {"ok": False, "error": "The signature doesn't match this environment's deploy token."})
        latest = read("latest") or None
        self.answer(200, {"ok": True, "commit_sha": latest, "build": None})

    def do_POST(self):
        if self.path != f"/webhooks/deploys/{ENVIRONMENT}":
            return self.answer(404, {"ok": False, "error": "No such environment."})
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if not self.signed(body):
            return self.answer(401, {"ok": False, "error": "The signature doesn't match this environment's deploy token."})
        with open(os.path.join(STATE, "body.json"), "wb") as f:
            f.write(body)
        with open(os.path.join(STATE, "headers.json"), "w") as f:
            json.dump({k: v for k, v in self.headers.items()}, f)
        payload = json.loads(body)
        build = payload.get("build") or payload["commit_sha"][:7]
        self.answer(201, {"ok": True, "deploy_id": "deploy-1", "build": build, "outcome": "created"})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(STATE, "port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
