#!/usr/bin/env python3
"""The regtest faucet of the kind demo (plan §2 Demo): yew/web/scripts/fund-helper.py's logic as
a container behind the gateway at /faucet/, speaking JSON-RPC over HTTP to the node's RPC
Service (no kubectl, no ycash-cli). REGTEST ONLY: it spends the in-cluster node's wallet, which
is the miner's. The chart renders it only when regtest.faucet.enabled.

  GET /faucet/                                   the page: paste an address → Send 2 YEC, Mine 1 block,
                                                 the node's address to send back to, the tip height
  GET /faucet/send?addr=<a>&zat=<n>[&memo=<m>]   public or private detected by the address prefix
  GET /faucet/fund?addr=<yregtestsapling1…>&zat  z_sendmany from the node's Sapling address (shields
                                                 coinbase first when short); &memo=<text>
  GET /faucet/fund_t?addr=<sm…>&zat=<n>          sendtoaddress (z_sendmany NoPrivacy when refused)
  GET /faucet/address                            a fresh transparent address of the node's wallet
  GET /faucet/mine?n=1                           generate n blocks (1..10)
  GET /faucet/reorg?depth=<d>|height=<h>         invalidateblock + generate (the W3 reorg)
  GET /faucet/info                               JSON: tip, mempool size, node address, limits
  GET /faucet/params/<file>                      the Sapling proving files from $PARAMS_DIR (the
                                                 PVC the init container filled; SHA-256 checked)
  GET /faucet/metrics                            Prometheus text: the node probe (tip, RPC latency),
                                                 the faucet's request counters

The acting routes (send/fund/fund_t/mine/reorg) are limited to one request per $RATE_SECONDS
(default 5) across all callers: 429 + Retry-After otherwise. The `/faucet` prefix is stripped
so the same handler serves a plain mount too.
"""
import base64
import http.server
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

RPC_URL = os.environ.get("RPC_URL", "http://localhost:18832/")
RPC_USER = os.environ.get("RPC_USER", "ycash")
RPC_PASSWORD = os.environ.get("RPC_PASSWORD", "")
PARAMS_DIR = os.environ.get("PARAMS_DIR", "/params")
PORT = int(os.environ.get("PORT", "8080"))
RATE_SECONDS = float(os.environ.get("RATE_SECONDS", "5"))
WALLET_URL = os.environ.get("WALLET_URL", "/")          # where the page links the wallet
PREFIX = "/faucet"
PARAM_FILES = ("sapling-spend.params", "sapling-output.params")
HERE = os.path.dirname(os.path.abspath(__file__))

_auth = base64.b64encode(f"{RPC_USER}:{RPC_PASSWORD}".encode()).decode()
_lock = threading.Lock()          # one acting request at a time, and the rate limit's clock
_last_act = 0.0
_counters = {"requests": 0, "acts": 0, "limited": 0, "errors": 0}
_probe = {"height": None, "seconds": None, "mempool": None, "ok": 0}


class RpcError(RuntimeError):
    pass


def rpc(method, *params, timeout=120):
    body = json.dumps({"jsonrpc": "1.0", "id": "faucet", "method": method, "params": list(params)}).encode()
    req = urllib.request.Request(RPC_URL, data=body, headers={"Content-Type": "text/plain", "Authorization": "Basic " + _auth})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            out = json.load(r)
    except urllib.error.HTTPError as e:
        try:
            out = json.load(e)
        except ValueError:
            raise RpcError(f"{method}: HTTP {e.code}") from None
    if out.get("error"):
        raise RpcError(f"{method}: {out['error'].get('message', out['error'])}")
    return out["result"]


def wait_opid(opid, timeout=300):
    t0 = time.time()
    while time.time() - t0 < timeout:
        for st in rpc("z_getoperationstatus", [opid]):
            if st["status"] == "success":
                return st["result"]["txid"]
            if st["status"] == "failed":
                raise RpcError(str(st.get("error")))
        time.sleep(1)
    raise RpcError(f"operation {opid} timed out")


def node_zaddr():
    for a in rpc("z_listaddresses"):
        if a.startswith("yregtestsapling1"):
            return a
    return rpc("z_getnewaddress", "sapling")


def private_balance(zaddr, minconf=1):
    return float(rpc("z_getbalance", zaddr, minconf))


def ensure_private(zaddr, need_yec):
    if private_balance(zaddr) >= need_yec:
        return
    # fee null (the node's policy), the default limit (50), no memo; the coinbases sit on many of
    # the account's own t-addresses, which the default privacy policy refuses to link.
    r = rpc("z_shieldcoinbase", "*", zaddr, None, 50, "", "AllowLinkingAccountAddresses")
    txid = wait_opid(r["opid"])
    log(f"shielded {r['shieldingValue']} YEC in {txid}; waiting for a confirmation")
    t0 = time.time()
    while private_balance(zaddr) < need_yec:
        if time.time() - t0 > 300:
            raise RpcError("shielded coinbase did not confirm")
        time.sleep(2)


def fund(addr, zat, memo=None):
    yec = zat / 1e8
    zaddr = node_zaddr()
    ensure_private(zaddr, yec + 0.001)
    out = {"address": addr, "amount": f"{yec:.8f}"}
    if memo:
        out["memo"] = memo.encode().hex()
    # fee null = ZIP-317 (6.22 refuses an explicit 0.0001)
    r = rpc("z_sendmany", zaddr, [out], 1, None, "AllowLinkingAccountAddresses")
    txid = wait_opid(r if isinstance(r, str) else r.get("opid"))
    log(f"sent {yec} YEC to {addr} in {txid}")
    return txid


def fund_t(addr, zat):
    yec = zat / 1e8
    try:
        txid = rpc("sendtoaddress", addr, round(yec, 8))
    except RpcError as e:
        log(f"sendtoaddress refused ({e}); z_sendmany instead")
        zaddr = node_zaddr()
        ensure_private(zaddr, yec + 0.001)
        r = rpc("z_sendmany", zaddr, [{"address": addr, "amount": f"{yec:.8f}"}], 1, None, "NoPrivacy")
        txid = wait_opid(r if isinstance(r, str) else r.get("opid"))
    log(f"sent {yec} YEC to transparent {addr} in {txid}")
    return txid


def reorg(depth=None, height=None):
    old_tip = int(rpc("getblockcount"))
    h = int(height) if height is not None else old_tip - int(depth)
    if h < 1 or h > old_tip:
        raise ValueError(f"height {h} not in 1..{old_tip}")
    rpc("invalidateblock", rpc("getblockhash", h))
    want = old_tip + 1
    rpc("generate", want - int(rpc("getblockcount")))
    t0 = time.time()
    while int(rpc("getblockcount")) < want:
        if time.time() - t0 > 120:
            raise RpcError("the new branch did not grow")
        time.sleep(1)
    new_tip = int(rpc("getblockcount"))
    log(f"reorg: invalidated height {h} (old tip {old_tip}), new tip {new_tip}")
    return {"oldTip": old_tip, "invalidated": h, "newTip": new_tip}


def probe():
    """The node probe behind /metrics and the page's tip: one getblockcount, timed."""
    t0 = time.time()
    try:
        h = int(rpc("getblockcount", timeout=10))
        _probe.update(height=h, seconds=time.time() - t0, ok=1)
        _probe["mempool"] = len(rpc("getrawmempool", timeout=10))
    except Exception as e:  # noqa: BLE001
        _probe["ok"] = 0
        log(f"probe failed: {e}")


def prober():
    while True:
        probe()
        time.sleep(15)


def log(msg):
    print("faucet:", msg, flush=True)


class H(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/plain; charset=utf-8", extra=()):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Access-Control-Allow-Origin", "*")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj), "application/json")

    def _file(self, path, ctype):
        size = os.path.getsize(path)
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(size))
        self.send_header("Access-Control-Allow-Origin", "*")
        if ctype.startswith("text/html"):
            self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(path, "rb") as f:
            while chunk := f.read(1 << 20):
                self.wfile.write(chunk)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        _counters["requests"] += 1
        u = urllib.parse.urlparse(self.path)
        path = u.path
        if path == PREFIX:
            return self._send(301, "", extra=[("Location", PREFIX + "/")])
        if path.startswith(PREFIX + "/"):
            path = path[len(PREFIX):]
        q = urllib.parse.parse_qs(u.query)
        try:
            return self.route(path, q)
        except (RpcError, ValueError, KeyError) as e:
            _counters["errors"] += 1
            return self._send(400 if isinstance(e, (ValueError, KeyError)) else 500, f"{e}")
        except Exception as e:  # noqa: BLE001
            _counters["errors"] += 1
            return self._send(500, f"{e}")

    def route(self, path, q):
        global _last_act
        if path in ("/", "/index.html"):
            return self._file(os.path.join(HERE, "index.html"), "text/html; charset=utf-8")
        if path == "/app.js":
            return self._file(os.path.join(HERE, "app.js"), "text/javascript; charset=utf-8")
        if path.startswith("/params/"):
            name = path[len("/params/"):]
            if name not in PARAM_FILES:
                return self._send(404, "not found")
            p = os.path.join(PARAMS_DIR, name)
            if not os.path.isfile(p):
                return self._send(404, f"{name} missing: the init container has not fetched it yet")
            return self._file(p, "application/octet-stream")
        if path == "/info":
            if _probe["height"] is None:
                probe()
            return self._json(200, {"regtest": True, "tip": _probe["height"], "mempool": _probe["mempool"],
                                    "nodeAddress": self._node_addr(),
                                    "rateSeconds": RATE_SECONDS, "walletUrl": WALLET_URL,
                                    "params": [n for n in PARAM_FILES if os.path.isfile(os.path.join(PARAMS_DIR, n))]})
        if path == "/metrics":
            lines = ["# TYPE faucet_requests_total counter"]
            lines += [f'faucet_requests_total{{kind="{k}"}} {v}' for k, v in _counters.items()]
            lines += ["# TYPE faucet_node_up gauge", f"faucet_node_up {_probe['ok']}"]
            if _probe["height"] is not None:
                lines += ["# TYPE faucet_node_height gauge", f"faucet_node_height {_probe['height']}",
                          "# TYPE faucet_node_rpc_seconds gauge", f"faucet_node_rpc_seconds {_probe['seconds']:.4f}",
                          "# TYPE faucet_node_mempool_size gauge", f"faucet_node_mempool_size {_probe['mempool'] or 0}"]
            return self._send(200, "\n".join(lines) + "\n", "text/plain; version=0.0.4")
        if path == "/address":
            return self._send(200, rpc("getnewaddress"))
        if path not in ("/send", "/fund", "/fund_t", "/mine", "/reorg"):
            return self._send(404, "not found")
        # the arguments are checked before the rate slot is taken, so a typo does not cost 5 s
        addr = memo = None
        zat = 0
        if path in ("/send", "/fund", "/fund_t"):
            addr = q["addr"][0].strip()
            zat = int(q.get("zat", ["200000000"])[0])
            if not 0 < zat <= 100_000_000_000:
                return self._send(400, "zat must be 1..1000 YEC")
            memo = q.get("memo", [None])[0]
            if path == "/fund" and not addr.startswith("yregtestsapling1"):
                return self._send(400, "a regtest Sapling address, please")
            if path != "/fund" and not addr.startswith("yregtestsapling1") and not (addr.startswith("sm") or addr.startswith("s1") or addr.startswith("t")):
                return self._send(400, "a regtest address, please (sm…/s1… public or yregtestsapling1… private)")
        if path == "/reorg" and q.get("depth", [None])[0] is None and q.get("height", [None])[0] is None:
            return self._send(400, "depth or height, please")
        # the acting routes: one at a time, one per RATE_SECONDS
        if not _lock.acquire(blocking=False):
            _counters["limited"] += 1
            return self._send(429, "busy: another request is in flight", extra=[("Retry-After", str(int(RATE_SECONDS)))])
        try:
            wait = RATE_SECONDS - (time.time() - _last_act)
            if wait > 0:
                _counters["limited"] += 1
                return self._send(429, f"one request per {RATE_SECONDS:g} s: retry in {wait:.1f} s", extra=[("Retry-After", str(int(wait) + 1))])
            _last_act = time.time()
            _counters["acts"] += 1
            if path == "/mine":
                n = min(max(int(q.get("n", ["1"])[0]), 1), 10)
                hashes = rpc("generate", n)
                _probe["height"] = int(rpc("getblockcount"))
                return self._json(200, {"mined": n, "tip": _probe["height"], "blocks": hashes})
            if path == "/reorg":
                return self._json(200, reorg(depth=q.get("depth", [None])[0], height=q.get("height", [None])[0]))
            if path == "/fund_t" or (path == "/send" and not addr.startswith("yregtestsapling1")):
                return self._send(200, fund_t(addr, zat))
            return self._send(200, fund(addr, zat, memo))
        finally:
            _lock.release()

    _node_t = None

    def _node_addr(self):
        if H._node_t is None:
            H._node_t = rpc("getnewaddress")
        return H._node_t

    def log_message(self, fmt, *a):
        log(fmt % a)


if __name__ == "__main__":
    threading.Thread(target=prober, daemon=True).start()
    log(f"listening on :{PORT} (node {RPC_URL}, params {PARAMS_DIR}, one act per {RATE_SECONDS:g} s) — REGTEST ONLY")
    http.server.ThreadingHTTPServer(("", PORT), H).serve_forever()
