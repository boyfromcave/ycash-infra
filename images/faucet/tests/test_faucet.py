# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Offline tests for images/faucet/faucet.py: the testnet mode's limits, challenge and routes against a
stand-in node (a JSON-RPC server in this process), and that the regtest mode keeps its routes.

Run: python3 -I -m unittest discover -s images/faucet/tests -v
"""

import hashlib
import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
FAUCET = os.path.join(os.path.dirname(HERE), "faucet.py")
TADDR = "smTestTransparentAddress1234567890"
ZADDR = "ytestsapling1" + "q" * 60
SOURCE = "ytestsapling1" + "s" * 60


class Node:
    """A stand-in ycashd: the RPCs the faucet calls, with a switchable chain."""

    def __init__(self):
        self.chain = "test"
        self.profile = "fast"
        self.calls = []
        node = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                m, p = req["method"], req["params"]
                node.calls.append((m, p))
                res = {
                    "getblockcount": 600000,
                    "getrawmempool": [],
                    "getblockchaininfo": {"chain": node.chain, "testnetprofile": node.profile},
                    "z_listaddresses": [SOURCE],
                    "z_getbalance": 50.0,
                    "validateaddress": {"isvalid": str(p[0]).startswith("sm")} if p else None,
                    "z_validateaddress": {"isvalid": str(p[0]).startswith("ytestsapling1"), "address_type": "sapling"} if p else None,
                    "z_sendmany": "opid-1",
                    "z_getoperationstatus": [{"status": "success", "result": {"txid": "ab" * 32}}],
                    "generate": ["00" * 32],
                    "getnewaddress": TADDR,
                }.get(m)
                body = json.dumps({"result": res, "error": None if m in node.known else {"message": f"{m}?"}, "id": req["id"]}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.known = {"getblockcount", "getrawmempool", "getblockchaininfo", "z_listaddresses", "z_getbalance",
                      "validateaddress", "z_validateaddress", "z_sendmany", "z_getoperationstatus", "generate", "getnewaddress"}
        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}/"

    def sends(self):
        return [p for m, p in self.calls if m == "z_sendmany"]


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Faucet:
    def __init__(self, node, **env):
        self.port = free_port()
        e = {"PATH": os.environ.get("PATH", ""), "RPC_URL": node.url, "RPC_PASSWORD": "x", "PORT": str(self.port),
             "RATE_SECONDS": "0"}
        e.update({k: str(v) for k, v in env.items()})
        self.proc = subprocess.Popen([sys.executable, "-I", FAUCET], env=e, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.05)

    def get(self, path, xff=None):
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}")
        if xff:
            req.add_header("X-Forwarded-For", xff)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    def stop(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)


def load_module(**env):
    """faucet.py imported with the given environment (its settings are read at import)."""
    import importlib.util
    old = dict(os.environ)
    os.environ.update({k: str(v) for k, v in env.items()})
    try:
        spec = importlib.util.spec_from_file_location("faucet_under_test", FAUCET)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        os.environ.clear()
        os.environ.update(old)


class Units(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.F = load_module(FAUCET_MODE="testnet", TRUSTED_PROXY_HOPS="1")

    def test_windows(self):
        w = self.F.Windows(2, 100)
        self.assertEqual(w.retry_after("a", 0), 0)
        w.record("a", 0)
        w.record("a", 10)
        self.assertEqual(w.retry_after("a", 50), 51)
        self.assertEqual(w.retry_after("b", 50), 0)
        self.assertEqual(w.retry_after("a", 100.5), 0)

    def test_cap(self):
        c = self.F.Cap(300, window=100)
        self.assertTrue(c.allows(100, 0))
        c.record(200, 0)
        self.assertTrue(c.allows(100, 1))
        self.assertFalse(c.allows(101, 1))
        self.assertTrue(c.allows(300, 100))

    def test_client_key(self):
        k = self.F.client_key
        self.assertEqual(k("10.0.0.5", "203.0.113.9"), "203.0.113.9")
        self.assertEqual(k("10.0.0.5", "1.2.3.4, 203.0.113.9"), "203.0.113.9")   # only the gateway's entry counts
        self.assertEqual(k("10.0.0.5", None), "10.0.0.5")
        self.assertEqual(k("10.0.0.5", "203.0.113.9", hops=0), "10.0.0.5")
        self.assertEqual(k("10.0.0.5", "2001:db8:1:2:3:4:5:6"), "2001:db8:1:2::/64")
        self.assertEqual(k("10.0.0.5", "::ffff:198.51.100.7"), "198.51.100.7")

    def test_leading_zero_bits(self):
        self.assertEqual(self.F.leading_zero_bits(b"\x00\x00\x80"), 16)
        self.assertEqual(self.F.leading_zero_bits(b"\x00\x0f"), 12)
        self.assertEqual(self.F.leading_zero_bits(b"\xff"), 0)

    def test_pow(self):
        F = self.F
        now = time.time()
        ch = F.new_challenge(now)
        nonce = next(str(n) for n in range(1 << 20)
                     if F.leading_zero_bits(hashlib.sha256(f"{ch}:{n}".encode()).digest()) >= 8)
        self.assertIsNone(F.check_pow(ch, nonce, bits=0))
        self.assertIn("used", F.check_pow(ch, nonce, bits=8, now=now) or "used")   # first use passes ...
        self.assertIn("used", F.check_pow(ch, nonce, bits=8, now=now))            # ... the second is refused
        ch2 = F.new_challenge(now)
        self.assertIn("unknown", F.check_pow(ch2[:-1] + ("0" if ch2[-1] != "0" else "1"), "1", bits=8, now=now))
        self.assertIn("expired", F.check_pow(F.new_challenge(now - 1000), "1", bits=8, now=now))
        self.assertIsNotNone(F.check_pow(ch2, "x" * 40, bits=8, now=now))


class Testnet(unittest.TestCase):
    def setUp(self):
        self.node = Node()

    def tearDown(self):
        self.node.srv.shutdown()

    def start(self, **env):
        f = Faucet(self.node, FAUCET_MODE="testnet", FAUCET_PROFILE="fast", AMOUNT_ZAT=100000000, **env)
        self.addCleanup(f.stop)
        return f

    def test_pays_and_limits_per_ip_and_address(self):
        f = self.start()
        code, body = f.get(f"/send?addr={TADDR}", xff="203.0.113.1")
        self.assertEqual(code, 200, body)
        self.assertEqual(json.loads(body)["kind"], "transparent")
        (src, outs, _minconf, _fee, policy), = self.node.sends()
        self.assertEqual((src, outs, policy), (SOURCE, [{"address": TADDR, "amount": "1.00000000"}], "AllowRevealedRecipients"))
        self.assertEqual(f.get(f"/send?addr={ZADDR}", xff="203.0.113.1")[0], 429)      # same IP
        self.assertEqual(f.get(f"/send?addr={TADDR}", xff="203.0.113.2")[0], 429)      # same address
        code, body = f.get(f"/send?addr={ZADDR}", xff="203.0.113.2")
        self.assertEqual(code, 200, body)
        self.assertEqual(self.node.sends()[1][4], "FullPrivacy")

    def test_daily_cap(self):
        f = self.start(DAILY_CAP_ZAT=200000000)
        for i in range(2):
            self.assertEqual(f.get(f"/send?addr={TADDR}{i}", xff=f"198.51.100.{i}")[0], 200)
        code, body = f.get(f"/send?addr={TADDR}9", xff="198.51.100.9")
        self.assertEqual(code, 429)
        self.assertIn("daily", body)

    def test_refuses_another_chain_or_profile(self):
        f = self.start()
        self.node.chain = "main"
        self.assertEqual(f.get(f"/send?addr={TADDR}", xff="192.0.2.1")[0], 503)
        self.node.chain, self.node.profile = "test", "slow"
        self.assertEqual(f.get(f"/send?addr={TADDR}", xff="192.0.2.2")[0], 503)
        self.assertEqual(self.node.sends(), [])

    def test_refuses_bad_addresses(self):
        f = self.start()
        self.assertEqual(f.get("/send?addr=not-an-address", xff="192.0.2.3")[0], 400)
        code, body = f.get("/send?addr=" + "x" * 40, xff="192.0.2.4")
        self.assertEqual(code, 400)
        self.assertEqual(self.node.sends(), [])

    def test_regtest_routes_are_gone(self):
        f = self.start()
        for path in ("/mine?n=1", "/reorg?depth=1", "/address", f"/fund?addr={ZADDR}", f"/fund_t?addr={TADDR}",
                     "/params/sapling-spend.params", "/faucet/mine"):
            self.assertEqual(f.get(path)[0], 404, path)
        self.assertNotIn("generate", [m for m, _ in self.node.calls])

    def test_pow(self):
        f = self.start(POW_BITS=8)
        self.assertEqual(f.get(f"/send?addr={TADDR}", xff="192.0.2.5")[0], 403)
        ch = json.loads(f.get("/challenge")[1])["challenge"]
        nonce = next(str(n) for n in range(1 << 20)
                     if hashlib.sha256(f"{ch}:{n}".encode()).digest()[0] == 0)
        code, body = f.get(f"/send?addr={TADDR}&challenge={ch}&nonce={nonce}", xff="192.0.2.5")
        self.assertEqual(code, 200, body)

    def test_info_page_and_metrics(self):
        f = self.start()
        info = json.loads(f.get("/info")[1])
        self.assertEqual((info["mode"], info["amountZat"], info["params"]), ("testnet", 100000000, False))
        code, page = f.get("/")
        self.assertEqual(code, 200)
        self.assertIn("TESTNET", page)
        self.assertNotIn("Mine", page)
        for _ in range(50):
            metrics = f.get("/metrics")[1]
            if "faucet_balance_zat" in metrics:
                break
            time.sleep(0.1)
        self.assertIn("faucet_balance_zat 5000000000", metrics)
        self.assertIn("faucet_chain_ok 1", metrics)


class Regtest(unittest.TestCase):
    def test_regtest_mode_unchanged(self):
        node = Node()
        self.addCleanup(node.srv.shutdown)
        f = Faucet(node)
        self.addCleanup(f.stop)
        self.assertTrue(json.loads(f.get("/faucet/info")[1])["regtest"])
        code, body = f.get("/faucet/mine?n=1")
        self.assertEqual(code, 200, body)
        self.assertIn("REGTEST ONLY", f.get("/faucet/")[1])


if __name__ == "__main__":
    unittest.main()
