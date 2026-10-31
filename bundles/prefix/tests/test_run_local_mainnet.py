# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""run-local-mainnet.sh end to end, offline: a fake `docker` (fake_docker.py) and a fake ycashd.

The fake ycashd serves real Ycash mainnet blocks 0..20 (tests/vectors/ycash-mainnet-blocks-0-20.hex)
over JSON-RPC with cookie auth, writing its .cookie into the mounted datadir as ycashd does. Its
tip climbs by 4 on every getblockchaininfo up to 20 and is kept in a file, so a restart (the
export runs on a node restarted with no network) keeps the chain. It reports the initial block
download complete once the tip is 20. z_gettreestate answers for any height; FAKE_TREESTATE_SKEW
makes the cross-check node's answer differ.
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

TOP = 20


def mainnet_blocks():
    with open(os.path.join(HERE, "vectors", "ycash-mainnet-blocks-0-20.hex")) as f:
        return [bytes.fromhex(line.strip()) for line in f if line.strip()]


def serve(d, name, datadir):
    blocks = mainnet_blocks()
    hashes = [H.display(H.parse_block(b)[0]) for b in blocks]
    tipfile = os.path.join(d, name + ".tip")
    lock = threading.Lock()
    cookie = "__cookie__:eWNhc2hk"
    skew = os.environ.get("FAKE_TREESTATE_SKEW") == "1" and name.endswith("crosscheck")

    def tip(step):
        t = int(open(tipfile).read()) if os.path.exists(tipfile) else 0
        if step:
            with open(tipfile, "w") as fh:
                fh.write(str(min(t + 4, TOP)))
        return t

    class Ycashd(http.server.BaseHTTPRequestHandler):
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
                t = tip(m == "getblockchaininfo")
                if m == "getblockchaininfo":
                    result = {"blocks": t, "headers": TOP, "initial_block_download_complete": t == TOP}
                elif m == "getblockhash":
                    result = hashes[p[0]] if p[0] <= t else None
                    if result is None:
                        error = {"code": -8, "message": "Block height out of range"}
                elif m == "getblock" and p[1] == 0:
                    result = blocks[hashes.index(p[0])].hex()
                elif m == "z_gettreestate":
                    h = int(p[0])
                    result = {"hash": hashes[h], "height": h, "time": H.block_time(blocks[h]),
                              "sprout": {"commitments": {"finalRoot": "59d2cde5e65c1414c32ba54f0fe4bdb3d67618125286e6a191317917c812c6d7"}},
                              "sapling": {"commitments": {"finalRoot": "skewed" if skew else "00" * 32}}}
            out = json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result, "error": error}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Ycashd)
    with open(os.path.join(d, name + ".port"), "w") as fh:
        fh.write(str(srv.server_address[1]))
    with open(os.path.join(datadir, ".cookie"), "w") as fh:
        fh.write(cookie)
    print("ycashd: RPC up", flush=True)
    srv.serve_forever()


@unittest.skipUnless(shutil.which("bash") and os.path.isdir("/proc"), "needs bash and /proc")
class RunLocalMainnet(unittest.TestCase):
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
        self.env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"], FAKE_DOCKER_DIR=self.fake,
                        WORK=self.work, POLL_SEC="1", MIN_DEPTH="5", SPLIT_STEP="10", JOBS="2")
        for n in ("mainnet-ycashd", "mainnet-ycashd-crosscheck"):
            self.addCleanup(subprocess.call, [docker, "rm", "-f", n], env=self.env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def run_local(self, *args, **env):
        return subprocess.run(["bash", os.path.join(ROOT, "run-local-mainnet.sh")] + list(args), env=dict(self.env, **env),
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)

    def history(self, name):
        with open(os.path.join(self.fake, name + ".history")) as fh:
            return [json.loads(line) for line in fh]

    def test_auto_split_crosscheck_sync(self):
        r = self.run_local()
        self.assertEqual(r.returncode, 0, r.stdout)
        out = os.path.join(self.work, "out")
        m = H.verify_dir(out, log=lambda *a: None)
        # tip 20, MIN_DEPTH 5, SPLIT_STEP 10: the default rule (k*10 - 1) gives 9
        self.assertEqual(m["network"], "ycash-mainnet")
        self.assertEqual(m["last_height"], 9)
        self.assertEqual([c["blocks"] for c in m["chunks"]], [10])
        self.assertEqual(m["split"]["hash"], H.display(H.parse_block(mainnet_blocks()[9])[0]))
        self.assertEqual(m["split"]["chaintx"], 10)
        self.assertEqual(m["crosscheck"], {})
        with open(os.path.join(self.work, "split-height")) as fh:
            self.assertEqual(fh.read().strip(), "9")
        with open(os.path.join(self.work, "harvest-report.json")) as fh:
            rep = json.load(fh)
        self.assertEqual((rep["split_height"], rep["crosscheck"], rep["node_tip_at_split"]), (9, "sync", 20))
        # the main node: first with the network, then restarted offline for the export
        a = self.history("mainnet-ycashd")
        self.assertEqual([h["network"] for h in a], ["bridge", "none"])
        self.assertIn("-connect=0", a[1]["args"])
        self.assertEqual([h["network"] for h in self.history("mainnet-ycashd-crosscheck")], ["bridge"])
        self.assertFalse(os.listdir(os.path.join(self.work, "raw")), "raw chunks removed after packing")
        with open(os.path.join(self.work, "timings.txt")) as fh:
            self.assertEqual([ln.split()[0] for ln in fh], ["sync", "export", "pack"])
        for n in ("mainnet-ycashd", "mainnet-ycashd-crosscheck"):
            self.assertFalse(os.path.exists(os.path.join(self.fake, n + ".pid")), n + " left running")

    def test_explicit_split_no_crosscheck_keep_raw(self):
        r = self.run_local("12", CROSSCHECK="none", KEEP_RAW="1", ADDNODES="peer.example.org:8833")
        self.assertEqual(r.returncode, 0, r.stdout)
        m = H.verify_dir(os.path.join(self.work, "out"), log=lambda *a: None)
        self.assertEqual(m["last_height"], 12)
        self.assertEqual([c["file"] for c in m["chunks"]], ["ycash-mainnet-prefix-v1-0000000-0000012.blocks.gz"])
        self.assertTrue(os.listdir(os.path.join(self.work, "raw")))
        self.assertIn("-addnode=peer.example.org:8833", self.history("mainnet-ycashd")[0]["args"])
        self.assertFalse(os.path.exists(os.path.join(self.fake, "mainnet-ycashd-crosscheck.history")))

    def test_crosscheck_node_disagrees(self):
        r = self.run_local(FAKE_TREESTATE_SKEW="1")
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("z_gettreestate at 9 differs", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.work, "out", "SHA256SUMS")))

    def test_bad_inputs(self):
        for args, env, msg in ((["x"], {}, "H_S must be"), (["2300000"], {"CROSSCHECK": "none"}, "newest compiled checkpoint"),
                               ([], {"CROSSCHECK": "rpc"}, "CROSSCHECK_RPC_URL"), ([], {"ADDNODES": "a;b"}, "host[:port]")):
            r = self.run_local(*args, **env)
            self.assertEqual(r.returncode, 1, r.stdout)
            self.assertIn(msg, r.stdout)


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "--serve":
        serve(*sys.argv[2:5])
    else:
        unittest.main()
