#!/usr/bin/env python3
"""Minimal Forgejo /api/v1/user/tokens stub for driving fm-mint-forgejo-token.sh.

Request routing:
- POST /api/v1/user/tokens with Authorization: token GOODADMIN -> 201 + fake token body
- POST /api/v1/user/tokens with Authorization: token BADADMIN  -> 401 + Forgejo-style error body
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/api/v1/user/tokens":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            parsed = json.loads(body) if body else {}
        except Exception:
            parsed = {"_raw": body}
        auth = self.headers.get("Authorization", "")
        # Log for evidence
        sys.stderr.write(f"[stub] POST /api/v1/user/tokens auth={auth!r} body={parsed!r}\n")
        sys.stderr.flush()
        if auth == "token GOODADMIN":
            resp = {
                "id": 42,
                "name": parsed.get("name", "unknown"),
                "sha1": "deadbeefcafebabedeadbeefcafebabe12345678",
                "token_last_eight": "12345678",
                "scopes": parsed.get("scopes", []),
            }
            data = json.dumps(resp).encode("utf-8")
            self.send_response(201)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        # Error branch - Forgejo-style error payload
        err = {
            "message": "token is invalid or missing admin scope",
            "url": "https://forgejo.example/api/swagger",
        }
        data = json.dumps(err).encode("utf-8")
        self.send_response(401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):  # keep stdout clean
        sys.stderr.write("[stub-http] " + (fmt % args) + "\n")


def main():
    port = int(os.environ.get("STUB_PORT", "0"))
    srv = HTTPServer(("127.0.0.1", port), Handler)
    actual = srv.server_address[1]
    print(actual, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
