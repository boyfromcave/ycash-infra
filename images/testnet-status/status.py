#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""The public status page of one Ycash testnet. It holds no secret and reaches no node: it serves a
static page and, as /status.json, the probe's public summary (PROBE_URL, cached for CACHE seconds)
with the operator's notices (NOTICES_FILE, a JSON list of {"date", "text"} from a ConfigMap) and the
current release candidate (RELEASE, when the operator names it) added.

  GET /              the page (index.html; status.js renders it)
  GET /status.js
  GET /status.json   {"network", "height", "tipTime", "peers", "vault", "attestorSet", "version",
                      "release", "bundle", "seeds", "notices", ...}
  GET /healthz

Environment: PROBE_URL (http://<probe>:9100/status.json), NOTICES_FILE, RELEASE, CACHE (s, 15), PORT (8080).
Python's standard library only.
"""
import http.server
import json
import os
import threading
import time
import urllib.request

PROBE_URL = os.environ.get("PROBE_URL", "http://localhost:9100/status.json")
NOTICES_FILE = os.environ.get("NOTICES_FILE", "")
RELEASE = os.environ.get("RELEASE", "")
CACHE = float(os.environ.get("CACHE", "15"))
PORT = int(os.environ.get("PORT", "8080"))
HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = {"/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"),
          "/status.js": ("status.js", "text/javascript; charset=utf-8")}
CSP = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

_lock = threading.Lock()
_cache = {"at": 0.0, "body": None}


def notices():
    if not NOTICES_FILE:
        return []
    try:
        with open(NOTICES_FILE, encoding="utf-8") as f:
            items = json.load(f)
        return [{"date": str(i.get("date", "")), "text": str(i.get("text", ""))} for i in items if isinstance(i, dict)][:20]
    except (OSError, ValueError):
        return []


def status():
    with _lock:
        now = time.time()
        if _cache["body"] is None or now - _cache["at"] >= CACHE:
            try:
                with urllib.request.urlopen(PROBE_URL, timeout=5) as r:
                    s = json.load(r)
            except Exception:  # noqa: BLE001
                s = {"stale": True}
            s["release"] = RELEASE or None
            s["notices"] = notices()
            s["served"] = int(now)
            _cache.update(at=now, body=json.dumps(s, sort_keys=True).encode())
        return _cache["body"]


class H(http.server.BaseHTTPRequestHandler):
    server_version = "status"
    sys_version = ""

    def _send(self, code, body, ctype, cache="no-store"):
        body = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", CSP)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in STATIC:
            name, ctype = STATIC[path]
            with open(os.path.join(HERE, name), "rb") as f:
                return self._send(200, f.read(), ctype, "public, max-age=300")
        if path == "/status.json":
            return self._send(200, status(), "application/json", "public, max-age=15")
        if path == "/healthz":
            return self._send(200, "ok\n", "text/plain")
        return self._send(404, "not found\n", "text/plain")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"status: :{PORT}, from {PROBE_URL}", flush=True)
    http.server.ThreadingHTTPServer(("", PORT), H).serve_forever()
