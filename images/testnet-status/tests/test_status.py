# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Offline tests for images/testnet-status: probe.py against stand-in nodes (JSON-RPC servers in this
process) and stand-in seeds (TCP servers answering in a given magic), and status.py serving the
probe's summary with the operator's notices.

Run: python3 -I -m unittest discover -s images/testnet-status/tests -v
"""

import http.server
import importlib.util
import json
import os
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MAGIC = "f77962d3"


def load(name, **env):
    old = dict(os.environ)
    os.environ.update({k: str(v) for k, v in env.items()})
    try:
        spec = importlib.util.spec_from_file_location(name + "_under_test", os.path.join(ROOT, name + ".py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        os.environ.clear()
        os.environ.update(old)


class Node:
    def __init__(self, height=600, hashes=None, vault_hash="v" * 64, yed=True):
        self.height, self.vault_hash, self.yed = height, vault_hash, yed
        self.hashes = hashes or {}
        node = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                m, p = req["method"], req["params"]
                best = node.block(node.height)
                res = {
                    "getblockchaininfo": {"blocks": node.height, "headers": node.height, "bestblockhash": best,
                                          "chain": "test", "testnetprofile": "fast"},
                    "getblockheader": {"time": 1_800_000_000},
                    "getconnectioncount": 7,
                    "getchaintips": [{"height": node.height, "status": "active", "branchlen": 0},
                                     {"height": node.height - 1, "status": "valid-fork", "branchlen": 3},
                                     {"height": 10, "status": "valid-fork", "branchlen": 9}],
                    "getnetworkinfo": {"subversion": "/MagicBean:6.22.0-rc1/", "protocolversion": 270013},
                    "vault_getinfo": {"activationheight": 510400, "active": True, "attestorsetid": "ab" * 32,
                                      "statehash": node.vault_hash, "dbtip": {"hash": best, "height": node.height}},
                    "yed_getstatehash": {"height": node.height, "blockhash": best, "statehash": "y" * 64},
                    "getblockhash": node.block(p[0]) if m == "getblockhash" else None,
                }
                err = None
                if m == "yed_getstatehash" and not node.yed:
                    err = {"code": -32601, "message": "Method not found"}
                body = json.dumps({"result": res.get(m), "error": err, "id": req["id"]}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}/"

    def block(self, h):
        return self.hashes.get(h, "%064x" % h)


class Seed:
    """Reads a 24-byte header and answers with a header in `magic` (or closes, for magic None)."""

    def __init__(self, magic):
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                got = b""
                while len(got) < 24:
                    c = self.request.recv(24 - len(got))
                    if not c:
                        return
                    got += c
                if magic and got[:4] == bytes.fromhex(magic):
                    self.request.sendall(bytes.fromhex(magic) + b"version".ljust(12, b"\0") + b"\0" * 8)

        self.srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.srv.daemon_threads = True
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addr = f"127.0.0.1:{self.srv.server_address[1]}"


class Probe(unittest.TestCase):
    def run_probe(self, nodes, seeds=(), **env):
        cfg = [{"name": f"n{i}", "url": n.url, "line": "ycash6" if i == 0 else "ycash-dd"} for i, n in enumerate(nodes)]
        P = load("probe", NODES=json.dumps(cfg), SEEDS=" ".join(s.addr for s in seeds), MAGIC=MAGIC,
                 NETWORK_NAME="testnet-yb-fast", PROFILE="fast", **env)
        P.one_round()
        return P

    def tearDown(self):
        for x in getattr(self, "servers", []):
            x.srv.shutdown()

    def mk(self, *objs):
        self.servers = getattr(self, "servers", []) + list(objs)
        return objs

    def test_agreeing_nodes_and_seeds(self):
        a, b, good, other = self.mk(Node(600), Node(601), Seed(MAGIC), Seed("fa1af9bf"))
        P = self.run_probe([a, b], [good, other])
        m = P._state["metrics"]
        self.assertIn('ycash_node_height{network="testnet-yb-fast",node="n0",line="ycash6"} 600', m)
        self.assertIn('ycash_nodes_tip_agree{network="testnet-yb-fast"} 1', m)
        self.assertIn(f'ycash_seed_up{{network="testnet-yb-fast",seed="{good.addr}"}} 1', m)
        self.assertIn(f'ycash_seed_up{{network="testnet-yb-fast",seed="{other.addr}"}} 0', m)
        self.assertIn('ycash_node_fork_length{network="testnet-yb-fast",node="n0",line="ycash6"} 3', m)
        self.assertIn('ycash_vault_activation_height{network="testnet-yb-fast",node="n1",line="ycash-dd"} 510400', m)
        s = P._state["status"]
        self.assertEqual((s["height"], s["peers"], s["agree"], s["seeds"]), (601, 7, True, {"up": 1, "total": 2}))
        self.assertEqual(s["vault"], {"activationHeight": 510400, "active": True})
        self.assertNotIn("n0", json.dumps(s))          # no node names in the public summary
        self.assertNotIn("127.0.0.1", json.dumps(s))

    def test_tip_disagreement(self):
        a, b = self.mk(Node(600), Node(600, hashes={600: "f" * 64}))
        P = self.run_probe([a, b])
        self.assertIn('ycash_nodes_tip_agree{network="testnet-yb-fast"} 0', P._state["metrics"])

    def test_statehash_disagreement_at_the_same_block(self):
        a, b = self.mk(Node(600), Node(600, vault_hash="w" * 64))
        P = self.run_probe([a, b])
        m = P._state["metrics"]
        self.assertIn('ycash_statehash_agree{network="testnet-yb-fast",kind="vault"} 0', m)
        self.assertIn('ycash_statehash_agree{network="testnet-yb-fast",kind="yed"} 1', m)
        self.assertFalse(P._state["status"]["stateAgree"])

    def test_statehash_not_compared_across_blocks_or_without_yed(self):
        a, b = self.mk(Node(600, yed=False), Node(601, vault_hash="w" * 64, yed=False))
        P = self.run_probe([a, b])
        self.assertNotIn("ycash_statehash_agree", P._state["metrics"])

    def test_down_node(self):
        a, = self.mk(Node(600))
        P = load("probe", NODES=json.dumps([{"name": "n0", "url": a.url, "line": "ycash6"},
                                            {"name": "gone", "url": "http://127.0.0.1:1/", "line": "ycash-dd"}]))
        P.one_round()
        self.assertIn('ycash_node_up{network="testnet",node="gone",line="ycash-dd"} 0', P._state["metrics"])
        self.assertEqual(P._state["status"]["nodes"], {"up": 1, "total": 2})

    def test_bundle_manifest(self):
        d = tempfile.mkdtemp()
        with open(os.path.join(d, "manifest.json"), "w") as f:
            json.dump({"height": 512640, "created": "2026-11-01T00:00:00Z", "tarball": "t.tar.gz"}, f)

        class Quiet(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *a, **k):
                super().__init__(*a, directory=d, **k)

            def log_message(self, *a):
                pass

        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Quiet)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.shutdown)
        a, = self.mk(Node(600))
        P = self.run_probe([a], BUNDLE_MANIFEST_URL=f"http://127.0.0.1:{srv.server_address[1]}/manifest.json")
        m = P._state["metrics"]
        self.assertIn('ycash_bundle_height{network="testnet-yb-fast"} 512640', m)
        self.assertIn('ycash_bundle_created_timestamp_seconds{network="testnet-yb-fast"} 1793491200', m)
        self.assertEqual(P._state["status"]["bundle"]["height"], 512640)


class Status(unittest.TestCase):
    def test_serves_summary_with_notices_and_headers(self):
        d = tempfile.mkdtemp()
        with open(os.path.join(d, "status.json"), "w") as f:
            json.dump({"network": "testnet-yb-fast", "height": 600}, f)
        with open(os.path.join(d, "notices.json"), "w") as f:
            json.dump([{"date": "2026-11-01", "text": "reset at rc2"}], f)

        class Quiet(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *a, **k):
                super().__init__(*a, directory=d, **k)

            def log_message(self, *a):
                pass

        probe = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Quiet)
        threading.Thread(target=probe.serve_forever, daemon=True).start()
        self.addCleanup(probe.shutdown)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        env = {"PATH": os.environ.get("PATH", ""), "PORT": str(port), "RELEASE": "6.22.0-rc1",
               "PROBE_URL": f"http://127.0.0.1:{probe.server_address[1]}/status.json",
               "NOTICES_FILE": os.path.join(d, "notices.json")}
        p = subprocess.Popen([sys.executable, "-I", os.path.join(ROOT, "status.py")], env=env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: (p.terminate(), p.wait(10)))
        for _ in range(100):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/status.json", timeout=2) as r:
                    s = json.load(r)
                    csp = r.headers["Content-Security-Policy"]
                break
            except OSError:
                time.sleep(0.05)
        self.assertEqual((s["height"], s["release"]), (600, "6.22.0-rc1"))
        self.assertEqual(s["notices"], [{"date": "2026-11-01", "text": "reset at rc2"}])
        self.assertIn("default-src 'none'", csp)
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=2) as r:
            self.assertIn(b"status.js", r.read())
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/../probe.py", timeout=2)
            self.fail("served a file outside the page")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 404)


if __name__ == "__main__":
    unittest.main()
