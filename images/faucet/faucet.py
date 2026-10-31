#!/usr/bin/env python3
"""The faucet, in one of two modes (FAUCET_MODE).

regtest (the default): the kind demo's faucet (plan §2 Demo), yew/web/scripts/fund-helper.py's logic
as a container behind the gateway at /faucet/, speaking JSON-RPC over HTTP to the node's RPC Service
(no kubectl, no ycash-cli). It spends the in-cluster node's wallet, which is the miner's. The
lightwallet chart renders it only when regtest.faucet.enabled. Its routes are listed below.

testnet: the public faucet of one Ycash testnet (charts/ycash-testnet faucet.enabled; workspace
testnet plan §6.2). It pays a fixed amount of testnet YEC from the Sapling address of its own wallet
node (restored from a recovery phrase the operator mounts as a Secret; this process never sees the
phrase) and nothing else: no mining, no reorg, no node address, no free amounts. Per-IP and
per-address windows, a daily cap, one payment at a time, and an optional proof-of-work challenge
limit it; the node must report chain "test" (and FAUCET_PROFILE, when set) or nothing is paid. The
routes are in testnet_route() below.

The regtest routes:

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
import collections
import hashlib
import hmac
import http.server
import ipaddress
import json
import os
import re
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

# ---- testnet mode (FAUCET_MODE=testnet; charts/ycash-testnet faucet.*) -------------------------
MODE = os.environ.get("FAUCET_MODE", "regtest")
if MODE not in ("regtest", "testnet"):
    raise SystemExit(f"FAUCET_MODE={MODE!r}: regtest or testnet")
# the /params/ route: the kind demo's wallet needs it; on a testnet only where the operator turns it on
PARAMS_ENABLED = os.environ.get("PARAMS_ENABLED", "1" if MODE == "regtest" else "0") == "1"
NETWORK_NAME = os.environ.get("NETWORK_NAME", "testnet")      # shown on the page (testnet-yb-fast, ...)
FAUCET_PROFILE = os.environ.get("FAUCET_PROFILE", "")         # the node's getblockchaininfo.testnetprofile must equal it
FAUCET_FROM = os.environ.get("FAUCET_FROM", "")               # the paying Sapling address; empty = the wallet's first
AMOUNT_ZAT = int(os.environ.get("AMOUNT_ZAT", "100000000"))   # one payment (1 YEC), fixed
PER_IP_LIMIT = int(os.environ.get("PER_IP_LIMIT", "1"))       # payments per client IP (IPv6: per /64) ...
PER_IP_WINDOW = float(os.environ.get("PER_IP_WINDOW", "86400"))   # ... in this many seconds
PER_ADDR_LIMIT = int(os.environ.get("PER_ADDR_LIMIT", "1"))   # payments per recipient address ...
PER_ADDR_WINDOW = float(os.environ.get("PER_ADDR_WINDOW", "86400"))
DAILY_CAP_ZAT = int(os.environ.get("DAILY_CAP_ZAT", "10000000000"))   # all payments in any 24 h (100 YEC)
POW_BITS = int(os.environ.get("POW_BITS", "0"))               # leading zero bits of the challenge; 0 = off
POW_TTL = 600
# how many proxies in front append to X-Forwarded-For: 1 = the gateway (Envoy writes the peer it saw and
# drops a client-supplied header, charts/ycash-lightwallet routes.yaml), 0 = use the TCP peer
TRUSTED_PROXY_HOPS = int(os.environ.get("TRUSTED_PROXY_HOPS", "1"))
DAY = 86400.0


def param_path(requested):
    """The file under PARAMS_DIR for a requested proving-file name, or None. The path is built from the
    PARAM_FILES entry, never from the request, and must resolve inside PARAMS_DIR (no symlink out)."""
    for name in PARAM_FILES:
        if requested == name:
            root = os.path.realpath(PARAMS_DIR)
            p = os.path.realpath(os.path.join(root, name))
            return p if p.startswith(root + os.sep) else None
    return None

_auth = base64.b64encode(f"{RPC_USER}:{RPC_PASSWORD}".encode()).decode()
_lock = threading.Lock()          # one acting request at a time, and the rate limit's clock
_last_act = 0.0
_counters = {"requests": 0, "acts": 0, "limited": 0, "errors": 0}
_probe = {"height": None, "seconds": None, "mempool": None, "ok": 0, "balance": None, "chain_ok": 0}


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
        if MODE == "testnet":
            check_chain()
            _probe["chain_ok"] = 1
            _probe["balance"] = round(float(rpc("z_getbalance", source_address(), 1, timeout=30)) * 1e8)
    except Exception as e:  # noqa: BLE001
        if MODE == "testnet":
            _probe["chain_ok"] = 0
        _probe["ok"] = 0
        log(f"probe failed: {e}")


def prober():
    while True:
        probe()
        time.sleep(15)


def log(msg):
    print("faucet:", msg, flush=True)


# ---- testnet mode: limits, the challenge, the payment -------------------------------------------

class Windows:
    """At most `limit` events per key in any `window` seconds (a sliding window, in memory: a restart
    forgets it, which the per-address window and the daily cap bound)."""

    def __init__(self, limit, window):
        self.limit, self.window = limit, window
        self.hits = collections.defaultdict(collections.deque)

    def _trim(self, key, now):
        q = self.hits[key]
        while q and q[0] <= now - self.window:
            q.popleft()
        if not q:
            del self.hits[key]
        return q

    def retry_after(self, key, now):
        """0 when one more event is allowed now, else the seconds until it is."""
        if self.limit <= 0:
            return 0
        q = self._trim(key, now) if key in self.hits else ()
        if len(q) < self.limit:
            return 0
        return max(1, int(q[0] + self.window - now) + 1)

    def record(self, key, now):
        self.hits[key].append(now)


class Cap:
    """The total paid in any `window` seconds stays at or below `cap` zatoshis."""

    def __init__(self, cap, window=DAY):
        self.cap, self.window = cap, window
        self.paid = collections.deque()           # (time, zat)

    def total(self, now):
        while self.paid and self.paid[0][0] <= now - self.window:
            self.paid.popleft()
        return sum(z for _, z in self.paid)

    def allows(self, zat, now):
        return self.cap <= 0 or self.total(now) + zat <= self.cap

    def record(self, zat, now):
        self.paid.append((now, zat))


def client_key(peer, xff, hops=None):
    """The rate-limit key of a request: the address `hops` proxies back in X-Forwarded-For (the gateway
    appends the peer it saw), the TCP peer without one; an IPv6 address counts as its /64."""
    hops = TRUSTED_PROXY_HOPS if hops is None else hops
    ip = peer
    if hops > 0:
        parts = [p.strip() for p in (xff or "").split(",") if p.strip()]
        if len(parts) >= hops:
            ip = parts[-hops]
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return ip[:64]
    if a.version == 6:
        if a.ipv4_mapped:
            return str(a.ipv4_mapped)
        return str(ipaddress.ip_network(f"{a}/64", strict=False))
    return str(a)


_pow_key = os.urandom(32)
_pow_used = {}                    # challenge -> expiry (single use)


def _pow_mac(body):
    return hmac.new(_pow_key, body.encode(), hashlib.sha256).hexdigest()[:32]


def new_challenge(now=None):
    body = f"{int(now if now is not None else time.time())}.{os.urandom(12).hex()}"
    return f"{body}.{_pow_mac(body)}"


def leading_zero_bits(digest):
    n = 0
    for b in digest:
        if b == 0:
            n += 8
            continue
        n += 8 - b.bit_length()
        break
    return n


def check_pow(challenge, nonce, bits=None, now=None):
    """None when (challenge, nonce) is a fresh, unused solution with `bits` leading zero bits of
    SHA-256(challenge ":" nonce); else the reason. A solved challenge is spent."""
    bits = POW_BITS if bits is None else bits
    if bits <= 0:
        return None
    now = time.time() if now is None else now
    for c, exp in list(_pow_used.items()):
        if exp < now:
            del _pow_used[c]
    if not challenge or not nonce or len(nonce) > 32 or not re.fullmatch(r"[0-9A-Za-z]+", nonce):
        return "a solved challenge, please (reload the page)"
    parts = challenge.split(".")
    if len(parts) != 3 or not hmac.compare_digest(_pow_mac(f"{parts[0]}.{parts[1]}"), parts[2]):
        return "unknown challenge (reload the page)"
    try:
        ts = int(parts[0])
    except ValueError:
        return "unknown challenge (reload the page)"
    if not 0 <= now - ts <= POW_TTL:
        return "the challenge expired (reload the page)"
    if challenge in _pow_used:
        return "that challenge was used already (reload the page)"
    if leading_zero_bits(hashlib.sha256(f"{challenge}:{nonce}".encode()).digest()) < bits:
        return "the challenge is not solved"
    _pow_used[challenge] = ts + POW_TTL
    return None


_ip_windows = Windows(PER_IP_LIMIT, PER_IP_WINDOW)
_addr_windows = Windows(PER_ADDR_LIMIT, PER_ADDR_WINDOW)
_cap = Cap(DAILY_CAP_ZAT)
_paid_total = 0
_source = None


def check_chain():
    """Refuse to pay unless the node is on a testnet (chain "test") and, with FAUCET_PROFILE, on that one."""
    info = rpc("getblockchaininfo", timeout=10)
    if info.get("chain") != "test":
        raise RpcError(f"the node reports chain {info.get('chain')!r}, not test: refusing to pay")
    if FAUCET_PROFILE and info.get("testnetprofile") != FAUCET_PROFILE:
        raise RpcError(f"the node is on testnet profile {info.get('testnetprofile')!r}, not {FAUCET_PROFILE!r}: refusing to pay")
    return info


def source_address():
    """The Sapling address the faucet pays from: FAUCET_FROM, else the wallet's first Sapling address
    (the one -mnemonicfile restores)."""
    global _source
    if _source is None:
        if FAUCET_FROM:
            _source = FAUCET_FROM
        else:
            addrs = [a for a in rpc("z_listaddresses") if "sapling1" in a]
            if not addrs:
                raise RpcError("the faucet wallet has no Sapling address (restore it from the recovery phrase)")
            _source = addrs[0]
    return _source


ADDR_RE = re.compile(r"[0-9A-Za-z]{26,128}")


def classify(addr):
    """'transparent' or 'sapling' as the node judges the address on its own network; else ValueError."""
    if not ADDR_RE.fullmatch(addr):
        raise ValueError("that is not an address")
    v = rpc("validateaddress", addr)
    if v.get("isvalid"):
        if "pqscheme" in v:
            raise ValueError("a post-quantum address: the faucet pays transparent and Sapling addresses only")
        return "transparent"
    z = rpc("z_validateaddress", addr)
    if z.get("isvalid") and z.get("address_type", z.get("type")) == "sapling":
        return "sapling"
    raise ValueError(f"not a transparent or Sapling address of {NETWORK_NAME}")


def testnet_pay(addr, kind, zat):
    """z_sendmany from the faucet's Sapling address; shields the wallet's coinbase first when short."""
    src = source_address()
    yec = zat / 1e8
    ensure_private(src, yec + 0.001)
    policy = "AllowRevealedRecipients" if kind == "transparent" else "FullPrivacy"
    r = rpc("z_sendmany", src, [{"address": addr, "amount": f"{yec:.8f}"}], 1, None, policy)
    txid = wait_opid(r if isinstance(r, str) else r.get("opid"))
    log(f"paid {yec} YEC ({kind}) in {txid}")
    return txid


class H(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/plain; charset=utf-8", extra=()):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if MODE == "regtest":   # the kind demo's wallet may run on another origin; a testnet faucet answers its own page only
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
        if MODE == "regtest":   # the kind demo's wallet may run on another origin; a testnet faucet answers its own page only
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
        if MODE == "testnet":
            try:
                return self.testnet_route(path, q)
            except (ValueError, KeyError) as e:
                _counters["errors"] += 1
                return self._send(400, f"{e}")
            except Exception as e:  # noqa: BLE001
                # the node's error stays in the log; the caller gets a generic answer
                _counters["errors"] += 1
                log(f"error on {path}: {e}")
                return self._send(503 if isinstance(e, RpcError) else 500, "the faucet cannot pay right now; try again later")
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
        if path.startswith("/params/") and PARAMS_ENABLED:
            p = param_path(path[len("/params/"):])
            if p is None:
                return self._send(404, "not found")
            name = os.path.basename(p)
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
            return self._metrics()
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

    def _metrics(self):
        lines = ["# TYPE faucet_requests_total counter"]
        lines += [f'faucet_requests_total{{kind="{k}"}} {v}' for k, v in _counters.items()]
        lines += ["# TYPE faucet_node_up gauge", f"faucet_node_up {_probe['ok']}"]
        if _probe["height"] is not None:
            lines += ["# TYPE faucet_node_height gauge", f"faucet_node_height {_probe['height']}",
                      "# TYPE faucet_node_rpc_seconds gauge", f"faucet_node_rpc_seconds {_probe['seconds']:.4f}",
                      "# TYPE faucet_node_mempool_size gauge", f"faucet_node_mempool_size {_probe['mempool'] or 0}"]
        if MODE == "testnet":
            now = time.time()
            lines += ["# TYPE faucet_chain_ok gauge", f"faucet_chain_ok {_probe['chain_ok']}",
                      "# TYPE faucet_paid_zat_total counter", f"faucet_paid_zat_total {_paid_total}",
                      "# TYPE faucet_paid_zat_24h gauge", f"faucet_paid_zat_24h {_cap.total(now)}",
                      "# TYPE faucet_daily_cap_zat gauge", f"faucet_daily_cap_zat {DAILY_CAP_ZAT}",
                      "# TYPE faucet_amount_zat gauge", f"faucet_amount_zat {AMOUNT_ZAT}"]
            if _probe["balance"] is not None:
                lines += ["# TYPE faucet_balance_zat gauge", f"faucet_balance_zat {_probe['balance']}"]
        return self._send(200, "\n".join(lines) + "\n", "text/plain; version=0.0.4")

    def testnet_route(self, path, q):
        """The testnet routes: the page, /info, /challenge, /send, /metrics, /params/ (PARAMS_ENABLED)."""
        global _last_act, _paid_total
        if path in ("/", "/index.html"):
            return self._file(os.path.join(HERE, "testnet.html"), "text/html; charset=utf-8")
        if path == "/testnet.js":
            return self._file(os.path.join(HERE, "testnet.js"), "text/javascript; charset=utf-8")
        if path.startswith("/params/") and PARAMS_ENABLED:
            p = param_path(path[len("/params/"):])
            if p is None or not os.path.isfile(p):
                return self._send(404, "not found")
            return self._file(p, "application/octet-stream")
        if path == "/metrics":
            return self._metrics()
        if path == "/info":
            if _probe["height"] is None:
                probe()
            return self._json(200, {"mode": "testnet", "network": NETWORK_NAME, "tip": _probe["height"],
                                    "amountZat": AMOUNT_ZAT, "powBits": POW_BITS,
                                    "perIp": {"limit": PER_IP_LIMIT, "windowSeconds": PER_IP_WINDOW},
                                    "perAddress": {"limit": PER_ADDR_LIMIT, "windowSeconds": PER_ADDR_WINDOW},
                                    "available": bool(_probe["chain_ok"]) and (_probe["balance"] or 0) >= AMOUNT_ZAT,
                                    "params": PARAMS_ENABLED})
        if path == "/challenge":
            return self._json(200, {"challenge": new_challenge() if POW_BITS > 0 else "", "bits": POW_BITS})
        if path != "/send":
            return self._send(404, "not found")
        if self.command != "GET":
            return self._send(405, "GET only")
        now = time.time()
        ip = client_key(self.client_address[0], self.headers.get("X-Forwarded-For"))
        wait = _ip_windows.retry_after(ip, now)
        if wait:
            _counters["limited"] += 1
            return self._send(429, f"this network address was paid recently: retry in {wait // 3600} h {wait % 3600 // 60} min",
                              extra=[("Retry-After", str(wait))])
        addr = q["addr"][0].strip()
        if not ADDR_RE.fullmatch(addr):
            raise ValueError("that is not an address")
        wait = _addr_windows.retry_after(addr, now)
        if wait:
            _counters["limited"] += 1
            return self._send(429, f"that address was paid recently: retry in {wait // 3600} h {wait % 3600 // 60} min",
                              extra=[("Retry-After", str(wait))])
        why = check_pow(q.get("challenge", [""])[0], q.get("nonce", [""])[0], now=now)
        if why:
            return self._send(403, why)
        if not _cap.allows(AMOUNT_ZAT, now):
            _counters["limited"] += 1
            return self._send(429, "the faucet has paid its daily amount; try again tomorrow", extra=[("Retry-After", "3600")])
        if not _lock.acquire(blocking=False):
            _counters["limited"] += 1
            return self._send(429, "busy: another payment is in flight", extra=[("Retry-After", str(max(1, int(RATE_SECONDS))))])
        try:
            wait = RATE_SECONDS - (time.time() - _last_act)
            if wait > 0:
                _counters["limited"] += 1
                return self._send(429, f"retry in {wait:.0f} s", extra=[("Retry-After", str(int(wait) + 1))])
            check_chain()
            kind = classify(addr)
            _last_act = time.time()
            _counters["acts"] += 1
            txid = testnet_pay(addr, kind, AMOUNT_ZAT)
            now = time.time()
            _ip_windows.record(ip, now)
            _addr_windows.record(addr, now)
            _cap.record(AMOUNT_ZAT, now)
            _paid_total += AMOUNT_ZAT
            return self._json(200, {"txid": txid, "amountZat": AMOUNT_ZAT, "kind": kind})
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
    if MODE == "testnet":
        log(f"listening on :{PORT} (node {RPC_URL}, {NETWORK_NAME}, {AMOUNT_ZAT} zat a payment, "
            f"{PER_IP_LIMIT}/IP and {PER_ADDR_LIMIT}/address per window, cap {DAILY_CAP_ZAT} zat/24 h, pow {POW_BITS} bits) — TESTNET")
    else:
        log(f"listening on :{PORT} (node {RPC_URL}, params {PARAMS_DIR}, one act per {RATE_SECONDS:g} s) — REGTEST ONLY")
    http.server.ThreadingHTTPServer(("", PORT), H).serve_forever()
