# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""run-local.sh end to end, offline: a fake `docker` (fake_docker.py) and a fake Zebra.

The fake Zebra serves the vendored testnet blocks 0..10 over JSON-RPC with cookie auth, and its
tip climbs by 4 on every getblockchaininfo, as a syncing node's would. It records the tip it
reported when the export began, so the test can check the export waited for LAST + TIP_MARGIN.
Started with `--network none` the fake never answers RPC, as Zebra 7.0.0 does (fake_docker.py).
"""

import base64
import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path[0:0] = [ROOT, HERE]
import harvest as H  # noqa: E402
from test_harvest import vec  # noqa: E402


def serve(d, name):
    blocks = {h: vec(h) for h in range(11)}
    state = {"tip": 0, "export_began_at": None}
    lock = threading.Lock()
    cookie = "__cookie__:ZmFrZQ=="

    class Zebra(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            if self.headers.get("Authorization") != "Basic " + base64.b64encode(cookie.encode()).decode():
                self.send_response(401)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            req = json.loads(body)
            m, p = req["method"], req["params"]
            result, error = None, None
            with lock:
                if m == "getblockchaininfo":
                    result = {"blocks": state["tip"]}
                    state["tip"] = min(state["tip"] + 4, 1000)
                elif m == "getblockhash":
                    if state["export_began_at"] is None:
                        state["export_began_at"] = state["tip"]
                        with open(os.path.join(d, name + ".requests"), "w") as fh:
                            json.dump(state, fh)
                    if p[0] in blocks and p[0] <= state["tip"]:
                        result = H.display(H.parse_block(blocks[p[0]])[0])
                    else:
                        error = {"code": -8, "message": "Block not found"}
                elif m == "getblock" and p[1] == 0:
                    by_hash = {H.display(H.parse_block(b)[0]): b for b in blocks.values()}
                    result = by_hash[p[0]].hex()
            out = json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result, "error": error}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Zebra)
    with open(os.path.join(d, name + ".port"), "w") as fh:
        fh.write(str(srv.server_address[1]))
    with open(os.path.join(d, name + ".cookie"), "w") as fh:
        fh.write(cookie)
    print("RPC server started", flush=True)
    srv.serve_forever()


@unittest.skipUnless(shutil.which("bash") and os.path.isdir("/proc"), "needs bash and /proc")
class RunLocal(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d)
        bindir = os.path.join(self.d, "bin")
        os.makedirs(bindir)
        docker = os.path.join(bindir, "docker")
        with open(docker, "w") as fh:
            fh.write('#!/bin/sh\nexec "%s" -I "%s" "$@"\n' % (sys.executable, os.path.join(HERE, "fake_docker.py")))
        os.chmod(docker, 0o700)
        self.fake = os.path.join(self.d, "docker-state")
        self.work = os.path.join(self.d, "work")
        self.env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"],
                        FAKE_DOCKER_DIR=self.fake, WORK=self.work, POLL_SEC="1")
        self.addCleanup(subprocess.call, [docker, "rm", "-f", "prefix-zebrad"], env=self.env,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def run_local(self, last, **env):
        return subprocess.run(["bash", os.path.join(ROOT, "run-local.sh"), str(last)], env=dict(self.env, **env),
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)

    def test_sync_export_pack(self):
        r = self.run_local(10)
        self.assertEqual(r.returncode, 0, r.stdout)
        out = os.path.join(self.work, "out")
        H.verify_dir(out, log=lambda *a: None)
        with open(os.path.join(out, "manifest.json")) as fh:
            self.assertEqual(json.load(fh)["hashes"]["10"], H.display(H.parse_block(vec(10))[0]))
        # one zebrad, with the network, no stop height; the export began at tip >= LAST + 10
        with open(os.path.join(self.fake, "prefix-zebrad.net")) as fh:
            self.assertEqual(fh.read(), "bridge")
        with open(os.path.join(self.fake, "prefix-zebrad.env")) as fh:
            self.assertNotIn("ZEBRA_STATE__DEBUG_STOP_AT_HEIGHT", json.load(fh))
        with open(os.path.join(self.fake, "prefix-zebrad.requests")) as fh:
            self.assertGreaterEqual(json.load(fh)["export_began_at"], 20)
        with open(os.path.join(self.work, "timings.txt")) as fh:
            self.assertEqual([ln.split()[0] for ln in fh], ["sync", "export", "pack"])
        self.assertFalse(os.path.exists(os.path.join(self.fake, "prefix-zebrad.pid")), "zebrad left running")

    def test_margin_zero_and_bad_margin(self):
        r = self.run_local(10, TIP_MARGIN="0")
        self.assertEqual(r.returncode, 0, r.stdout)
        r = self.run_local(10, TIP_MARGIN="x")
        self.assertEqual(r.returncode, 1)
        self.assertIn("TIP_MARGIN", r.stdout)

    def test_export_failure_stops_zebrad(self):
        # blocks above 10 do not exist in the fake: the export fails, zebrad is still cleaned up
        r = self.run_local(12, TIP_MARGIN="0")
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.fake, "prefix-zebrad.pid")), "zebrad left running")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--serve":
        serve(sys.argv[2], sys.argv[3])
    else:
        unittest.main()
