#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""The value-pools page of an explorer host: how much YEC sits in each pool of the chain, now and
over time, read from the node's value-pool index (`valuePools`, `transparentPools` and `chainSupply`
in `getblockchaininfo` and `getblock <height> 1`; ycashd 6.22.0-beta3 and koganyd beta3 on).

It is a sidecar beside the explorer (explorer/compose.pools.yaml), not part of it: it reads the node
over JSON-RPC with three read-only calls (getblockchaininfo, getblockhash, getblock, and nothing
else), keeps a small sample file, and serves one self-contained page and a JSON API. No visitor
request reaches the node directly: the tip is polled by one background thread, history is sampled
once and stored, and a zoomed series may fetch a bounded number of old blocks within a per-minute
budget, one request at a time.

  GET <prefix>/                 the page (index.html: inline CSS and JavaScript, nothing external)
  GET <prefix>/api/v1/current   the totals at the tip, the sums that must hold, the sampler's state
  GET <prefix>/api/v1/series    ?from=&to=&max=  or  ?last=<blocks>  or  ?seconds=<s>: totals over height
  GET <prefix>/api/v1/deltas    ?count=<n>: what each of the last n blocks added to or took from each pool
  GET <prefix>/api/v1/status    the sampler: stored samples, what is still to fetch, RPC calls made
  GET <prefix>/healthz          the process serves HTTP

Amounts are integers in zatoshis (1 YEC = 100,000,000 zatoshis; the whole supply stays below 2^53,
so they are exact in JSON); the current totals also carry a decimal string in YEC.

Sampling (README.md "History"): every COARSE_STEP-th block of the whole chain, every FINE_STEP-th
block from FINE_FROM on, every block of the last RECENT_BLOCKS. A block deeper than REORG_MARGIN is
final (the node refuses a reorganisation deeper than 99 blocks).

Environment: README.md. Python's standard library only.
"""
import base64
import bisect
import collections
import hashlib
import http.server
import json
import os
import re
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

ZAT = 100_000_000
# One sample = these totals at one block, in zatoshis (None = the node did not report it there).
# The disjoint pools: sprout, sapling, orchard, other (any further valuePools entry, such as
# koganyd's lockbox), and the five parts of transparent: transparent_ecc, pq_slh_dsa + pq_falcon
# (= transparent_pq), pq_channel, vault, vault_intent. vault_yed is the part of vault + vault_intent
# under the YED module's tag.
FIELDS = ("supply", "transparent", "sprout", "sapling", "orchard", "other",
          "transparent_ecc", "transparent_pq", "pq_channel", "vault", "vault_intent",
          "pq_slh_dsa", "pq_falcon", "vault_yed")
SPLIT = FIELDS[6:]                      # from transparentPools: None where the index is not monitored
TRANSPARENT_PARTS = ("transparent_ecc", "transparent_pq", "pq_channel", "vault", "vault_intent")
PQ_PARTS = ("pq_slh_dsa", "pq_falcon")
PQ_SCHEMES = {1: "pq_slh_dsa", 2: "pq_falcon"}
YCASH_BRANCH, VAULT_BRANCH = "374d694f", "6d5b7a31"
Row = collections.namedtuple("Row", ("height", "hash", "time", "monitored") + FIELDS)


def env_int(name, default, lo, hi):
    try:
        v = int(os.environ.get(name, default))
    except ValueError:
        sys.exit(f"pools: {name} must be a whole number")
    if not lo <= v <= hi:
        sys.exit(f"pools: {name} must be {lo}..{hi}")
    return v


class Config:
    """The settings, from the environment (README.md lists them)."""

    def __init__(self):
        e = os.environ.get
        self.rpc_url = e("RPC_URL", "http://node:18832/")
        self.rpc_user = e("RPC_USER", "")
        self.rpc_password = e("RPC_PASSWORD", "")
        self.rpc_cookie_file = e("RPC_COOKIE_FILE", "")
        self.bind = e("BIND", "")
        self.port = env_int("PORT", 8080, 1, 65535)
        self.data_dir = e("DATA_DIR", "/data")
        p = e("POOLS_PREFIX", "/pools").strip("/")
        self.prefix = "/" + p if p else ""
        if not re.fullmatch(r"[A-Za-z0-9._~/-]*", p):
            sys.exit("pools: POOLS_PREFIX must be a plain path")
        self.block_url = e("EXPLORER_BLOCK_URL", "/block/")
        self.network_name = e("NETWORK_NAME", "")[:80]
        self.poll_seconds = env_int("POLL_SECONDS", 5, 1, 3600)
        self.rpc_interval = env_int("RPC_INTERVAL_MS", 50, 0, 60000) / 1000.0
        self.coarse_step = env_int("COARSE_STEP", 1000, 1, 1_000_000)
        self.fine_step = env_int("FINE_STEP", 10, 1, 1_000_000)
        self.fine_from = e("FINE_FROM", "auto")
        self.fine_max_span = env_int("FINE_MAX_SPAN", 200_000, 0, 100_000_000)
        self.recent = env_int("RECENT_BLOCKS", 2000, 100, 1_000_000)
        self.margin = env_int("REORG_MARGIN", 100, 1, 10_000)
        self.batch = env_int("BACKFILL_BATCH", 50, 1, 10_000)
        self.max_points = env_int("MAX_POINTS", 600, 2, 5000)
        self.ondemand_request = env_int("ONDEMAND_PER_REQUEST", 300, 0, 5000)
        self.ondemand_minute = env_int("ONDEMAND_PER_MINUTE", 600, 0, 100_000)
        self.api_per_minute = env_int("API_PER_MINUTE", 120, 1, 1_000_000)
        self.trusted_proxy = e("TRUSTED_PROXY", "")
        if self.fine_from != "auto" and not self.fine_from.isdigit():
            sys.exit("pools: FINE_FROM must be auto or a height")
        if not re.fullmatch(r"(/[A-Za-z0-9._~-]+)*/?", self.block_url) and not re.fullmatch(r"https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~-]+)*/?", self.block_url):
            sys.exit("pools: EXPLORER_BLOCK_URL must be a path or an https URL")


def yec(zat):
    """Zatoshis as a decimal string in YEC, exact (no float)."""
    if zat is None:
        return None
    sign = "-" if zat < 0 else ""
    return f"{sign}{abs(zat) // ZAT}.{abs(zat) % ZAT:08d}"


def share(zat, total):
    """zat / total in percent, 4 decimals, by integer arithmetic (rounded half up)."""
    if zat is None or not total or total <= 0:
        return None
    n = (abs(zat) * 1_000_000 + total // 2) // total         # units of 0.0001 percent
    return f"{'-' if zat < 0 else ''}{n // 10000}.{n % 10000:04d}"


def zat_of(entry):
    v = entry.get("chainValueZat") if isinstance(entry, dict) else None
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def parse_block(b):
    """A getblock (verbosity 1) answer as (Row, deltas): the totals as of that block, and what the
    block itself added to each pool (None where the node gave no delta). Entries are read by id,
    never by position (the node lines order valuePools differently)."""
    v = dict.fromkeys(FIELDS)
    d = dict.fromkeys(FIELDS)

    def put(name, entry, add=False):
        z = zat_of(entry)
        if z is None:
            return
        dz = entry.get("valueDeltaZat")
        dz = dz if isinstance(dz, int) and not isinstance(dz, bool) else None
        if add and v[name] is not None:
            v[name] += z
            d[name] = None if dz is None or d[name] is None else d[name] + dz
        else:
            v[name], d[name] = z, dz

    for entry in b.get("valuePools") or []:
        name = entry.get("id") if isinstance(entry, dict) else None
        if name in ("transparent", "sprout", "sapling", "orchard"):
            put(name, entry)
        elif name is not None:
            put("other", entry, add=True)
    tp = b.get("transparentPools") if isinstance(b.get("transparentPools"), dict) else {}
    monitored = tp.get("monitored") is True
    if monitored:
        if v["transparent"] is None:            # ycash-dd: valuePools has no transparent entry
            put("transparent", tp.get("transparent") or {})
        for entry in tp.get("pools") or []:
            if isinstance(entry, dict) and entry.get("id") in TRANSPARENT_PARTS:
                put(entry["id"], entry)
        for entry in tp.get("pq_by_scheme") or []:
            if isinstance(entry, dict) and entry.get("pqscheme") in PQ_SCHEMES:
                put(PQ_SCHEMES[entry["pqscheme"]], entry)
        for entry in tp.get("vault_by_module") or []:
            if isinstance(entry, dict) and entry.get("module") == "YED":
                put("vault_yed", entry)
    put("supply", b.get("chainSupply") or {})
    if v["supply"] is None:                     # a node without chainSupply: the pools' sum
        parts = [v[k] for k in ("transparent", "sprout", "sapling", "orchard", "other") if v[k] is not None]
        if v["transparent"] is not None:
            v["supply"] = sum(parts)
    for k in ("orchard", "other"):              # absent on a node line that has no such pool: zero
        if v[k] is None:
            v[k] = 0
    row = Row(int(b["height"]), str(b["hash"]), int(b["time"]), monitored, *[v[k] for k in FIELDS])
    return row, d


def checks(row):
    """The sums that must hold at one block. Each: the parts' sum, the expected total, holds."""
    def one(parts, total):
        vals = [getattr(row, p) for p in parts]
        want = getattr(row, total)
        if want is None or any(x is None for x in vals):
            return {"holds": None, "sumZat": None, "expectedZat": want, "parts": list(parts), "total": total}
        return {"holds": sum(vals) == want, "sumZat": sum(vals), "expectedZat": want, "parts": list(parts), "total": total}
    return {"transparent": one(TRANSPARENT_PARTS, "transparent"),
            "postQuantum": one(PQ_PARTS, "transparent_pq"),
            "supply": one(("transparent", "sprout", "sapling", "orchard", "other"), "supply")}


class RpcError(Exception):
    pass


class Rpc:
    """JSON-RPC to the node, one call at a time. `paced` calls keep `interval` seconds between
    calls (the sampler); unpaced ones (a tip poll, a bounded series fetch) only wait their turn."""

    def __init__(self, cfg, opener=None):
        self.cfg = cfg
        self.lock = threading.Lock()
        self.last = 0.0
        self.calls = 0
        self.errors = 0
        self.open = opener or urllib.request.build_opener(urllib.request.ProxyHandler({})).open

    def auth(self):
        if self.cfg.rpc_cookie_file:            # re-read: the node writes a new cookie at each start
            with open(self.cfg.rpc_cookie_file, encoding="utf-8") as f:
                cred = f.read().strip()
        else:
            cred = f"{self.cfg.rpc_user}:{self.cfg.rpc_password}"
        return "Basic " + base64.b64encode(cred.encode()).decode()

    def __call__(self, method, *params, paced=False, timeout=30):
        if method not in ("getblockchaininfo", "getblockhash", "getblock"):
            raise RpcError(f"{method}: not a call this service makes")
        with self.lock:
            if paced:
                wait = self.last + self.cfg.rpc_interval - time.monotonic()
                if wait > 0:
                    time.sleep(wait)
            body = json.dumps({"jsonrpc": "1.0", "id": "pools", "method": method, "params": list(params)}).encode()
            req = urllib.request.Request(self.cfg.rpc_url, data=body, headers={"Content-Type": "application/json"})
            self.calls += 1
            try:
                req.add_header("Authorization", self.auth())
                try:
                    with self.open(req, timeout=timeout) as r:
                        out = json.load(r)
                except urllib.error.HTTPError as e:      # the node answers a JSON-RPC error with HTTP 500/404
                    out = json.loads(e.read() or b"{}")
            except (OSError, ValueError) as e:
                self.errors += 1
                raise RpcError(f"{method}: {type(e).__name__}") from e
            finally:
                self.last = time.monotonic()
            if not isinstance(out, dict) or out.get("error") or "result" not in out:
                self.errors += 1
                err = out.get("error") if isinstance(out, dict) else None
                raise RpcError(f"{method}: {err.get('message', 'error') if isinstance(err, dict) else 'bad answer'}")
            return out["result"]


class Store:
    """The samples: height -> Row in memory, an append-only JSON-lines file on disk (one row per
    line, `[height, null]` for a dropped one; the last line for a height wins). The file is
    rewritten when more than half of it is superseded lines."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.RLock()
        self.rows = {}
        self.heights = []           # sorted
        self.lines = 0

    def load(self):
        with self.lock:
            self.rows, self.lines = {}, 0
            if self.path and os.path.exists(self.path):
                with open(self.path, encoding="utf-8") as f:
                    for line in f:
                        self.lines += 1
                        try:
                            a = json.loads(line)
                            if len(a) == 2 and a[1] is None:
                                self.rows.pop(int(a[0]), None)
                            else:
                                r = Row(int(a[0]), str(a[1]), int(a[2]), bool(a[3]), *a[4:])
                                self.rows[r.height] = r
                        except (ValueError, TypeError, IndexError):
                            continue                    # a torn last line after a crash
            self.heights = sorted(self.rows)
            if self.path:
                self.compact(force=self.lines != len(self.rows))

    def _append(self, obj):
        if not self.path:
            return
        with open(self.path, "a", encoding="utf-8") as f:
            f.write(json.dumps(obj, separators=(",", ":")) + "\n")
        self.lines += 1

    def compact(self, force=False):
        with self.lock:
            if not self.path or not (force or self.lines > 2 * len(self.rows) + 1000):
                return
            tmp = self.path + ".new"
            with open(tmp, "w", encoding="utf-8") as f:
                for h in self.heights:
                    f.write(json.dumps(list(self.rows[h]), separators=(",", ":")) + "\n")
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self.path)
            self.lines = len(self.rows)

    def get(self, h):
        return self.rows.get(h)

    def put(self, row):
        with self.lock:
            if self.rows.get(row.height) == row:
                return
            if row.height not in self.rows:
                bisect.insort(self.heights, row.height)
            self.rows[row.height] = row
            self._append(list(row))

    def drop(self, h):
        with self.lock:
            if h in self.rows:
                del self.rows[h]
                del self.heights[bisect.bisect_left(self.heights, h)]
                self._append([h, None])

    def wipe(self):
        with self.lock:
            self.rows, self.heights = {}, []
            self.compact(force=True)

    def between(self, lo, hi):
        with self.lock:
            return self.heights[bisect.bisect_left(self.heights, lo):bisect.bisect_right(self.heights, hi)]

    def top(self):
        with self.lock:
            return self.heights[-1] if self.heights else None

    def __len__(self):
        return len(self.rows)


class Sampler:
    """Follows the node's tip and fills the history. One thread runs `run`; `round` is one step of
    it (the tests call it directly)."""

    def __init__(self, cfg, rpc, store):
        self.cfg, self.rpc, self.store = cfg, rpc, store
        self.lock = threading.Lock()
        self.tip = None              # the Row at the node's tip
        self.tip_deltas = None
        self.chain = None
        self.upgrades = {}
        self.updated = 0.0           # when the node last answered
        self.fine_from = None
        self.validated = False
        self.delta_mismatches = 0
        self.reorg_drops = 0
        self.last_error = ""
        self.started = time.time()
        self.backfill_done_at = None

    # ---- which heights are kept ---------------------------------------------------------------
    def fine_start(self, tip_h):
        c = self.cfg
        if c.fine_from != "auto":
            return int(c.fine_from)
        for h in sorted(x for x in (self.upgrades.get("ycash"), self.upgrades.get("vault")) if isinstance(x, int)):
            if 0 <= tip_h - h <= c.fine_max_span:
                return h - h % c.coarse_step
        h = max(0, tip_h - min(c.fine_max_span, 20_000))
        return h - h % c.coarse_step

    def keep(self, h, tip_h):
        c = self.cfg
        return (h % c.coarse_step == 0 or h > tip_h - c.recent
                or (self.fine_from is not None and h >= self.fine_from and h % c.fine_step == 0))

    def wanted(self, tip_h):
        """Every height to sample, newest first within each tier: the recent window, the fine tier,
        the coarse tier. A generator; a height may come up in more than one tier."""
        c = self.cfg
        yield from range(tip_h, max(-1, tip_h - c.recent), -1)
        if self.fine_from is not None:
            yield from range(tip_h - tip_h % c.fine_step, self.fine_from - 1, -c.fine_step)
        yield from range(tip_h - tip_h % c.coarse_step, -1, -c.coarse_step)

    def missing(self, tip_h, limit=None):
        out, seen = [], set()
        for h in self.wanted(tip_h):
            if h not in seen and self.store.get(h) is None:
                seen.add(h)
                out.append(h)
                if limit and len(out) >= limit:
                    break
        return out

    # ---- the node ------------------------------------------------------------------------------
    def fetch(self, block, paced):
        """One block's Row (by height or hash). Its deltas are checked against the stored parent."""
        b = self.rpc("getblock", str(block), 1, paced=paced)
        row, deltas = parse_block(b)
        prev = self.store.get(row.height - 1)
        if prev is not None and prev.hash == b.get("previousblockhash"):
            for k in FIELDS:
                a, z, dz = getattr(prev, k), getattr(row, k), deltas[k]
                if a is not None and z is not None and dz is not None and z - a != dz:
                    self.delta_mismatches += 1
        return row, deltas

    def validate(self, tip_h):
        """At start: the stored samples must be this node's chain. The lowest one and the highest
        final one are compared with the node; a difference wipes the store (another network, or a
        chain that was reset). The rows within the reorganisation margin are checked by follow()."""
        hs = self.store.between(0, tip_h - self.cfg.margin)
        for h in ([hs[0], hs[-1]] if hs else []):
            if self.rpc("getblockhash", h) != self.store.get(h).hash:
                print(f"pools: the stored sample at {h} is not on the node's chain: the history is sampled again", flush=True)
                self.store.wipe()
                break
        self.validated = True

    def follow(self, tip_h, tip_hash):
        """The tip changed: store the new tip, and walk down from it comparing stored hashes with
        the node's until one agrees (one call when the chain only grew). A stored block that is no
        longer on the chain is dropped and sampled again by backfill()."""
        c = self.cfg
        if not self.validated:
            self.validate(tip_h)
        for h in self.store.between(tip_h + 1, 1 << 62):
            self.store.drop(h)
            self.reorg_drops += 1
        row, deltas = self.fetch(tip_hash, paced=False)
        if row.height != tip_h:
            raise RpcError("the tip moved during the poll")
        self.fine_from = self.fine_start(tip_h)
        self.store.put(row)
        for h in range(tip_h - 1, max(-1, tip_h - c.margin - 1), -1):
            have = self.store.get(h)
            if have is None:
                continue
            if self.rpc("getblockhash", h) == have.hash:
                break
            self.store.drop(h)
            self.reorg_drops += 1
        for h in self.store.between(0, tip_h - c.recent):       # what left the recent window
            if not self.keep(h, tip_h):
                self.store.drop(h)
        self.store.compact()
        with self.lock:
            self.tip, self.tip_deltas = row, deltas

    def backfill(self, tip_h, limit):
        n = 0
        for h in self.missing(tip_h, limit):
            row, _ = self.fetch(h, paced=True)
            if row.height == h:
                self.store.put(row)
            n += 1
        if n < limit and self.backfill_done_at is None:
            self.backfill_done_at = time.time()
            print(f"pools: history complete: {len(self.store)} samples, {self.rpc.calls} RPC calls, {int(self.backfill_done_at - self.started)} s", flush=True)
        return n

    def round(self):
        """One poll of the tip and one batch of history. Returns the number of blocks fetched."""
        info = self.rpc("getblockchaininfo")
        tip_h, tip_hash = int(info["blocks"]), str(info["bestblockhash"])
        up = info.get("upgrades") if isinstance(info.get("upgrades"), dict) else {}
        self.upgrades = {name: up[b]["activationheight"] for name, b in (("ycash", YCASH_BRANCH), ("vault", VAULT_BRANCH))
                         if isinstance(up.get(b), dict) and isinstance(up[b].get("activationheight"), int)}
        self.chain = str(info.get("chain", ""))[:16]
        if self.tip is None or self.tip.hash != tip_hash:
            self.follow(tip_h, tip_hash)
        self.updated = time.time()
        self.last_error = ""
        return self.backfill(tip_h, self.cfg.batch)

    def run(self):
        while True:
            try:
                fetched = self.round()
            except (RpcError, KeyError, ValueError, TypeError, OSError) as e:
                self.last_error = str(e)[:200]
                fetched = 0
            if not fetched:                   # history is complete (or the node is away): wait for the next poll
                time.sleep(self.cfg.poll_seconds)


class Budget:
    """At most `per_minute` units in any minute (a sliding window of timestamps)."""

    def __init__(self, per_minute):
        self.per_minute = per_minute
        self.used = collections.deque()
        self.lock = threading.Lock()

    def take(self, want, now=None):
        now = time.monotonic() if now is None else now
        with self.lock:
            while self.used and self.used[0][0] <= now - 60:
                self.used.popleft()
            got = max(0, min(want, self.per_minute - sum(n for _, n in self.used)))
            if got:
                self.used.append((now, got))
            return got


class ClientLimit:
    """API requests per client address per minute (fixed windows); the table is bounded."""

    def __init__(self, per_minute):
        self.per_minute = per_minute
        self.lock = threading.Lock()
        self.window = 0
        self.count = {}

    def allow(self, key, now=None):
        w = int((time.time() if now is None else now) // 60)
        with self.lock:
            if w != self.window or len(self.count) > 50_000:
                self.window, self.count = w, {}
            self.count[key] = self.count.get(key, 0) + 1
            return self.count[key] <= self.per_minute


def nice_step(n):
    """The smallest of 1, 2, 5, 10, 20, 50, ... that is >= n."""
    p = 1
    while True:
        for m in (1, 2, 5):
            if m * p >= n:
                return m * p
        p *= 10


class Api:
    """The JSON answers, built from the sampler's state and the store."""

    def __init__(self, cfg, rpc, store, sampler):
        self.cfg, self.rpc, self.store, self.sampler = cfg, rpc, store, sampler
        self.budget = Budget(cfg.ondemand_minute)
        self.ondemand_lock = threading.Lock()
        self.extra = collections.OrderedDict()      # final blocks fetched for a series, not in the tiers
        self.extra_lock = threading.Lock()
        self.cache = collections.OrderedDict()      # (tip hash, query) -> answer
        self.ondemand_calls = 0

    def row(self, h):
        r = self.store.get(h)
        if r is None:
            with self.extra_lock:
                r = self.extra.get(h)
        return r

    def current(self):
        s = self.sampler
        with s.lock:
            tip = s.tip
        now = time.time()
        if tip is None:
            return {"ready": False, "network": self.cfg.network_name, "error": "the node has not answered yet", "served": int(now)}
        leaves = ("sapling", "sprout", "transparent_ecc", "pq_falcon", "pq_slh_dsa", "pq_channel", "vault", "vault_intent", "orchard", "other")
        labels = {"sapling": "Sapling", "sprout": "Sprout", "transparent_ecc": "Transparent (ECC)",
                  "pq_falcon": "Post-quantum Falcon (FN-DSA-512)", "pq_slh_dsa": "Post-quantum SLH-DSA (SLH-DSA-SHA2-128s)",
                  "pq_channel": "Post-quantum channels", "vault": "Vault (locked in vaults)",
                  "vault_intent": "Vault intents (released, waiting out their delay)", "orchard": "Orchard", "other": "Other pools",
                  "transparent": "Transparent, all kinds", "transparent_pq": "Post-quantum, both schemes",
                  "vault_yed": "In vaults of the Yellowback (YED) module", "supply": "Total supply"}

        def entry(k):
            z = getattr(tip, k)
            return {"id": k, "label": labels[k], "zat": z, "yec": yec(z), "sharePercent": share(z, tip.supply),
                    "monitored": z is not None}
        tip_h = tip.height
        miss = len(s.missing(tip_h, 100_000)) if s.backfill_done_at is None else 0
        return {
            "ready": True, "network": self.cfg.network_name, "chain": s.chain,
            "height": tip.height, "hash": tip.hash, "time": tip.time,
            "updated": int(s.updated), "served": int(now), "ageSeconds": max(0, int(now - s.updated)),
            "monitored": tip.monitored,
            "pools": [entry(k) for k in leaves],
            "aggregates": [entry(k) for k in ("transparent", "transparent_pq", "vault_yed", "supply")],
            "checks": checks(tip),
            "upgrades": dict(s.upgrades),
            "links": {"block": self.cfg.block_url},
            "history": {"complete": s.backfill_done_at is not None, "samples": len(self.store), "missing": miss,
                        "fineFrom": s.fine_from, "fineStep": self.cfg.fine_step, "coarseStep": self.cfg.coarse_step,
                        "recentBlocks": self.cfg.recent},
        }

    def _fetch_extra(self, heights, tip_h):
        """Old blocks a series asks for that no tier holds: at most ONDEMAND_PER_REQUEST a request,
        ONDEMAND_PER_MINUTE a minute over all requests, one request at a time; only final blocks."""
        heights = [h for h in heights if h <= tip_h - self.cfg.margin][: self.cfg.ondemand_request]
        if not heights or not self.ondemand_lock.acquire(blocking=False):
            return
        try:
            for h in heights[: self.budget.take(len(heights))]:
                if self.row(h) is not None:
                    continue
                try:
                    row, _ = parse_block(self.rpc("getblock", str(h), 1, timeout=10))
                except (RpcError, KeyError, ValueError, TypeError):
                    return
                self.ondemand_calls += 1
                with self.extra_lock:
                    self.extra[row.height] = row
                    while len(self.extra) > 20_000:
                        self.extra.popitem(last=False)
        finally:
            self.ondemand_lock.release()

    def series(self, q):
        s = self.sampler
        with s.lock:
            tip = s.tip
        if tip is None:
            return 503, {"error": "the node has not answered yet"}
        try:
            mx = min(self.cfg.max_points, max(2, int(q.get("max", "300"))))
            to = min(tip.height, int(q["to"])) if "to" in q else tip.height
            if "last" in q:
                lo = to - max(1, int(q["last"])) + 1
            elif "seconds" in q:
                cut = tip.time - max(1, int(q["seconds"]))
                lo = to
                for h in reversed(self.store.between(0, to)):   # the first sample not older than the cut
                    if self.store.get(h).time < cut:
                        break
                    lo = h
            else:
                lo = int(q.get("from", "0"))
            lo = max(0, min(lo, to))
            if to < 0:
                raise ValueError
        except ValueError:
            return 400, {"error": "from, to, last, seconds and max are whole numbers"}
        key = (tip.hash, lo, to, mx)
        with self.extra_lock:
            hit = self.cache.get(key)
        if hit is not None:
            return 200, hit
        step = nice_step(-(-(to - lo) // (mx - 1))) if to > lo else 1
        grid = sorted(set(range(lo + (-lo) % step, to + 1, step)) | {lo, to})
        self._fetch_extra([h for h in grid if self.row(h) is None], tip.height)
        rows = [r for r in map(self.row, grid) if r is not None]
        complete = len(rows) == len(grid)
        if not complete:                            # a sparse grid: what the tiers hold in the range, if that is more
            hs = self.store.between(lo, to)
            hs = sorted(set(hs[::-(-len(hs) // mx) or 1]) | set(hs[-1:]))
            held = [r for r in map(self.store.get, hs) if r is not None]
            if len(held) > len(rows):
                rows = held
        out = {"tip": tip.height, "from": lo, "to": to, "step": step, "points": len(rows), "complete": complete,
               "heights": [r.height for r in rows], "times": [r.time for r in rows],
               "monitored": [r.monitored for r in rows],
               "pools": {k: [getattr(r, k) for r in rows] for k in FIELDS}}
        if complete:
            with self.extra_lock:
                self.cache[key] = out
                while len(self.cache) > 64:
                    self.cache.popitem(last=False)
        return 200, out

    def deltas(self, q):
        s = self.sampler
        with s.lock:
            tip = s.tip
        if tip is None:
            return 503, {"error": "the node has not answered yet"}
        try:
            n = max(1, min(500, self.cfg.recent - 1, int(q.get("count", "100"))))
        except ValueError:
            return 400, {"error": "count is a whole number"}
        heights, times, cols = [], [], {k: [] for k in FIELDS}
        for h in range(tip.height - n + 1, tip.height + 1):
            a, b = self.store.get(h - 1), self.store.get(h)
            if a is None or b is None:
                continue
            heights.append(h)
            times.append(b.time)
            for k in FIELDS:
                x, y = getattr(a, k), getattr(b, k)
                cols[k].append(None if x is None or y is None else y - x)
        return 200, {"tip": tip.height, "count": len(heights), "heights": heights, "times": times, "deltas": cols}

    def status(self):
        s = self.sampler
        with s.lock:
            tip = s.tip
        return {"tip": tip.height if tip else None, "samples": len(self.store), "fileLines": self.store.lines,
                "historyComplete": s.backfill_done_at is not None,
                "historySeconds": int(s.backfill_done_at - s.started) if s.backfill_done_at else None,
                "missing": len(s.missing(tip.height, 100_000)) if tip else None,
                "rpcCalls": self.rpc.calls, "rpcErrors": self.rpc.errors, "onDemandCalls": self.ondemand_calls,
                "deltaMismatches": s.delta_mismatches, "reorgDrops": s.reorg_drops,
                "lastError": s.last_error, "ageSeconds": max(0, int(time.time() - s.updated)) if s.updated else None,
                "uptimeSeconds": int(time.time() - s.started)}


HERE = os.path.dirname(os.path.abspath(__file__))


def load_page():
    """index.html and its Content-Security-Policy: the one inline script and the one inline style
    are admitted by their sha256, nothing else runs or loads; the API is same-origin."""
    with open(os.path.join(HERE, "index.html"), "rb") as f:
        page = f.read()

    def digest(tag):
        m = re.search(rb"<" + tag + rb">(.*?)</" + tag + rb">", page, re.S)
        return "'sha256-" + base64.b64encode(hashlib.sha256(m.group(1)).digest()).decode() + "'" if m else "'none'"
    csp = (f"default-src 'none'; script-src {digest(b'script')}; style-src {digest(b'style')}; connect-src 'self'; "
           "img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
    return page, csp


def make_handler(cfg, api, page, csp):
    limit = ClientLimit(cfg.api_per_minute)
    slots = threading.BoundedSemaphore(32)

    class H(http.server.BaseHTTPRequestHandler):
        server_version = "pools"
        sys_version = ""
        protocol_version = "HTTP/1.1"
        timeout = 15

        def _send(self, code, body, ctype="application/json", cache="no-store", extra=()):
            if not isinstance(body, (bytes, str)):
                body = json.dumps(body, separators=(",", ":"))
            body = body.encode() if isinstance(body, str) else body
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", cache)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", csp)
            for k, v in extra:
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def client(self):
            peer = self.client_address[0]
            fwd = self.headers.get("X-Forwarded-For", "")
            if cfg.trusted_proxy and peer == cfg.trusted_proxy and fwd:   # the proxy's own last entry
                return fwd.split(",")[-1].strip()[:64]
            return peer

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            if not slots.acquire(blocking=False):
                return self._send(503, {"error": "busy"}, extra=(("Retry-After", "2"),))
            try:
                self.route()
            finally:
                slots.release()

        def route(self):
            u = urllib.parse.urlsplit(self.path)
            path = u.path
            if cfg.prefix and (path == cfg.prefix or path.startswith(cfg.prefix + "/")):
                if path == cfg.prefix:
                    return self._send(308, "", "text/plain", extra=(("Location", cfg.prefix + "/"),))
                path = path[len(cfg.prefix):]
            if path == "/healthz":
                return self._send(200, "ok\n", "text/plain")
            if path in ("/", "/index.html"):
                return self._send(200, page, "text/html; charset=utf-8", "public, max-age=60")
            if not path.startswith("/api/v1/"):
                return self._send(404, {"error": "not found"})
            if not limit.allow(self.client()):
                return self._send(429, {"error": "too many requests"}, extra=(("Retry-After", "60"),))
            q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query, max_num_fields=8).items()} if len(u.query) <= 200 else {}
            name = path[len("/api/v1/"):]
            if name == "current":
                return self._send(200, api.current(), cache="public, max-age=3")
            if name == "series":
                code, body = api.series(q)
                return self._send(code, body, cache="public, max-age=5" if code == 200 else "no-store")
            if name == "deltas":
                code, body = api.deltas(q)
                return self._send(code, body, cache="public, max-age=5" if code == 200 else "no-store")
            if name == "status":
                return self._send(200, api.status())
            return self._send(404, {"error": "not found"})

        def log_message(self, *a):
            pass

    return H


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


def main():
    cfg = Config()
    os.makedirs(cfg.data_dir, exist_ok=True)
    store = Store(os.path.join(cfg.data_dir, "samples.jsonl"))
    store.load()
    rpc = Rpc(cfg)
    sampler = Sampler(cfg, rpc, store)
    api = Api(cfg, rpc, store, sampler)
    page, csp = load_page()
    threading.Thread(target=sampler.run, name="sampler", daemon=True).start()
    print(f"pools: {cfg.bind or '*'}:{cfg.port}{cfg.prefix}/, node {cfg.rpc_url}, {len(store)} stored samples", flush=True)
    Server((cfg.bind, cfg.port), make_handler(cfg, api, page, csp)).serve_forever()


if __name__ == "__main__":
    main()
