#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""A stand-in for the part of the Vast.ai REST API that scripts/vast-fleet.py uses, on 127.0.0.1.

In plain words: the tests must not rent anything or spend money, so this small local server
pretends to be Vast.ai. It keeps a pretend account (instances and offers) in a JSON file and logs
every request, so a test can check what the fleet script would have rented or destroyed.

  python3 -I scripts/tests/fake_vast.py --state STATE.json --log LOG.jsonl --port-file PORT [--key KEY]

STATE.json: {"instances": [...], "offers": [...], "next_id": 7000001, "credit": true,
             "fail_offers": [offer ids whose rent fails], "now": <epoch for start_date>}
Instances are rows as GET /api/v1/instances/ returns them (extra_env as [name, value] pairs).
The offer search ignores the price filter on purpose: the script must check the cap itself.
"""

import argparse
import json
import os
import re
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

LOCK = threading.Lock()


def make_handler(args):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):  # quiet
            pass

        def _state(self):
            with open(args.state, encoding="utf-8") as f:
                return json.load(f)

        def _save(self, st):
            with open(args.state, "w", encoding="utf-8") as f:
                json.dump(st, f, indent=1)

        def _reply(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _handle(self, method):
            u = urllib.parse.urlparse(self.path)
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"null") if n else None
            with open(args.log, "a", encoding="utf-8") as f:
                f.write(json.dumps({"method": method, "path": u.path, "query": u.query, "body": body,
                                    "auth": self.headers.get("Authorization")}) + "\n")
            if self.headers.get("Authorization") != f"Bearer {args.key}":
                return self._reply(401, {"success": False, "error": "unauthorized",
                                         "msg": "bad key " + str(self.headers.get("Authorization"))})
            with LOCK:
                st = self._state()
                code, obj = self._route(method, u, body, st)
                self._save(st)
            return self._reply(code, obj)

        def _route(self, method, u, body, st):
            q = urllib.parse.parse_qs(u.query)
            insts = st.setdefault("instances", [])
            if method == "GET" and u.path == "/api/v1/instances/":
                limit = int(json.loads(q.get("limit", ["25"])[0]))
                start = int(q.get("after_token", ["0"])[0])
                page = insts[start:start + limit]
                nxt = str(start + limit) if start + limit < len(insts) else None
                return 200, {"instances": page, "next_token": nxt, "total_instances": len(insts)}
            if method == "POST" and u.path == "/api/v0/bundles/":
                want = (body or {}).get("gpu_name", {}).get("in")
                offers = [o for o in st.get("offers", []) if not o.get("rented")]
                if want and st.get("filter_gpus", True):
                    offers = [o for o in offers if o.get("gpu_name") in want]
                if (body or {}).get("type") == "bid":
                    offers = [o for o in offers if "min_bid" in o]
                return 200, {"offers": offers}
            m = re.match(r"^/api/v0/asks/([0-9]+)/$", u.path)
            if method == "PUT" and m:
                oid = int(m.group(1))
                if not st.get("credit", True):
                    return 400, {"success": False, "error": "insufficient_credit", "msg": "Your account lacks credit"}
                offer = next((o for o in st.get("offers", []) if o["id"] == oid and not o.get("rented")), None)
                if offer is None or oid in st.get("fail_offers", []):
                    return 400, {"success": False, "error": "no_such_ask", "msg": "Offer is no longer available"}
                offer["rented"] = True
                iid = st.get("next_id", 7000001)
                st["next_id"] = iid + 1
                env = body.get("env") or {}
                insts.append({
                    "id": iid, "label": None if st.get("drop_labels") else body.get("label"),
                    "actual_status": "loading", "intended_status": "running", "cur_state": "running",
                    "gpu_name": offer.get("gpu_name"),
                    "dph_total": body.get("price") if body.get("price") is not None else offer.get("dph_total"),
                    "public_ipaddr": f"203.0.113.{iid % 250}", "machine_id": offer.get("machine_id"),
                    "start_date": st.get("now", time.time()), "image_uuid": body.get("image"),
                    "extra_env": [[k, v] for k, v in env.items()], "offer_id": oid,
                })
                return 200, {"success": True, "new_contract": iid}
            m = re.match(r"^/api/v0/instances/([0-9]+)/$", u.path)
            if m:
                iid = int(m.group(1))
                inst = next((i for i in insts if i["id"] == iid), None)
                if inst is None:
                    return 404, {"success": False, "error": "no_such_instance", "msg": f"no instance {iid}"}
                if method == "PUT":
                    inst["label"] = (body or {}).get("label")
                    return 200, {"success": True}
                if method == "DELETE":
                    insts.remove(inst)
                    return 200, {"success": True}
            return 404, {"success": False, "error": "not_found", "msg": f"{method} {u.path}"}

        def do_GET(self):
            self._handle("GET")

        def do_POST(self):
            self._handle("POST")

        def do_PUT(self):
            self._handle("PUT")

        def do_DELETE(self):
            self._handle("DELETE")

    return H


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--key", default="0123456789abcdef" * 4)
    args = ap.parse_args()
    srv = HTTPServer(("127.0.0.1", 0), make_handler(args))
    with open(args.port_file + ".tmp", "w", encoding="utf-8") as f:
        f.write(str(srv.server_address[1]))
    os.replace(args.port_file + ".tmp", args.port_file)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
