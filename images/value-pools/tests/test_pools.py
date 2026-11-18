#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Offline tests of the value-pools service (images/value-pools/pools.py): the parsing and the sums,
the sample store, the sampler against a stand-in chain (tiers, resuming, a reorganisation, another
chain), the series and delta answers with their limits, and the whole service over HTTP against a
stub JSON-RPC node.  python3 -I -m unittest discover -s images/value-pools/tests
"""
import base64
import http.server
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import pools  # noqa: E402

pools.print = lambda *a, **k: None      # the service's log lines are not test output


class Chain:
    """A stand-in node: block h holds fixed, recomputable totals; `reorg(k)` replaces the blocks
    from k up by another branch. `line` picks the answer's shape: ycash6, kogany or legacy (a node
    without transparentPools)."""

    def __init__(self, tip, line="ycash6", vault=None, ycash=None):
        self.tip, self.line, self.vault, self.ycash = tip, line, vault, ycash
        self.branch = {}            # height -> branch number (0 when absent)
        self.log = []
        self.unmonitored_below = 0

    def hash(self, h):
        return f"{self.branch.get(h, 0):02x}{h:062x}"

    def reorg(self, k, tip=None):
        n = max(self.branch.values(), default=0) + 1
        self.tip = self.tip if tip is None else tip
        for h in range(k, self.tip + 1):
            self.branch[h] = n

    def totals(self, h):
        b = self.branch.get(h, 0)
        t = {"sprout": 4_000 * pools.ZAT, "sapling": 500 * pools.ZAT + 3 * h, "orchard": 0,
             "pq_slh_dsa": 7 * h, "pq_falcon": 11 * h + b, "pq_channel": 0, "vault": 40_000_000 if h > 5 else 0,
             "vault_intent": 5 if h % 7 == 0 else 0, "transparent_ecc": 1_000 * pools.ZAT + 625_000_000 * h}
        t["transparent_pq"] = t["pq_slh_dsa"] + t["pq_falcon"]
        t["transparent"] = sum(t[k] for k in pools.TRANSPARENT_PARTS)
        t["supply"] = t["transparent"] + t["sprout"] + t["sapling"]
        return t

    def entry(self, name, h, delta, **more):
        t = self.totals(h)[name]
        e = dict(more, monitored=True, chainValue=t / pools.ZAT, chainValueZat=t)
        if delta:
            dz = t - (self.totals(h - 1)[name] if h else 0)
            e.update(valueDelta=dz / pools.ZAT, valueDeltaZat=dz)
        return e

    def pools_of(self, h, delta):
        vp = [self.entry(k, h, delta, id=k) for k in ("transparent", "sprout", "sapling", "orchard")]
        if self.line == "kogany":       # two more entries, never monitored there
            vp += [{"id": k, "monitored": False, "chainValue": 0.0, "chainValueZat": 0} for k in ("lockbox", "ironwood")]
        out = {"valuePools": vp, "chainSupply": self.entry("supply", h, delta)}
        if self.line == "legacy":
            return out
        if h < self.unmonitored_below:
            out["transparentPools"] = {"monitored": False}
            return out
        out["transparentPools"] = {
            "monitored": True, "transparent": self.entry("transparent", h, delta),
            "pools": [self.entry(k, h, delta, id=k) for k in pools.TRANSPARENT_PARTS],
            "pq_by_scheme": [self.entry("pq_slh_dsa", h, delta, pqscheme=1, pqschemename="SLH-DSA-SHA2-128s"),
                             self.entry("pq_falcon", h, delta, pqscheme=2, pqschemename="FN-DSA-512")],
            "vault_by_module": [dict(self.entry("vault", h, delta), module="YED", tag="59454400")]}
        return out

    def __call__(self, method, *params, paced=False, timeout=30):
        self.log.append((method,) + params)
        if method == "getblockchaininfo":
            up = {}
            if self.ycash is not None:
                up[pools.YCASH_BRANCH] = {"name": "Ycash", "activationheight": self.ycash}
            if self.vault is not None:
                up[pools.VAULT_BRANCH] = {"name": "Vault", "activationheight": self.vault}
            return dict(self.pools_of(self.tip, False), chain="test", blocks=self.tip, bestblockhash=self.hash(self.tip), upgrades=up)
        if method == "getblockhash":
            if not 0 <= params[0] <= self.tip:
                raise pools.RpcError("getblockhash: Block height out of range")
            return self.hash(params[0])
        if method == "getblock":
            want = params[0]
            assert isinstance(want, str) and params[1] == 1, "getblock <height or hash as a string> 1"
            h = int(want) if len(want) < 20 else int(want[2:], 16)
            if not 0 <= h <= self.tip or (len(want) >= 20 and want != self.hash(h)):
                raise pools.RpcError("getblock: Block not found")
            return dict(self.pools_of(h, True), height=h, hash=self.hash(h), time=1_700_000_000 + 150 * h,
                        previousblockhash=self.hash(h - 1) if h else None)
        raise AssertionError(method)

    calls = calls_made = property(lambda self: len(self.log))


def config(**env):
    keep = dict(os.environ)
    try:
        for k in list(os.environ):
            if k in ("RPC_URL", "RPC_USER", "RPC_PASSWORD", "RPC_COOKIE_FILE", "DATA_DIR", "POOLS_PREFIX", "FINE_FROM"):
                del os.environ[k]
        os.environ.update({"RPC_INTERVAL_MS": "0", "COARSE_STEP": "100", "FINE_STEP": "10", "RECENT_BLOCKS": "100",
                           "REORG_MARGIN": "20", "BACKFILL_BATCH": "10000"})
        os.environ.update({k: str(v) for k, v in env.items()})
        return pools.Config()
    finally:
        os.environ.clear()
        os.environ.update(keep)


def service(chain, path=None, **env):
    cfg = config(**env)
    store = pools.Store(path)
    store.load()
    sampler = pools.Sampler(cfg, chain, store)
    return cfg, store, sampler, pools.Api(cfg, chain, store, sampler)


class Parsing(unittest.TestCase):
    def test_amounts_are_exact(self):
        self.assertEqual(pools.yec(626803258644345), "6268032.58644345")
        self.assertEqual(pools.yec(5), "0.00000005")
        self.assertEqual(pools.yec(-150000000), "-1.50000000")
        self.assertIsNone(pools.yec(None))
        self.assertEqual(pools.share(5102890545212, 626803258644345), "0.8141")
        self.assertEqual(pools.share(1, 3), "33.3333")
        self.assertEqual(pools.share(2, 3), "66.6667")
        self.assertEqual(pools.share(7, 7), "100.0000")
        self.assertIsNone(pools.share(1, 0))
        self.assertIsNone(pools.share(None, 5))

    def test_nice_step(self):
        self.assertEqual([pools.nice_step(n) for n in (0, 1, 2, 3, 5, 6, 10, 11, 1715)], [1, 1, 2, 5, 5, 10, 10, 20, 2000])

    def test_a_block_of_each_node_line(self):
        for line in ("ycash6", "kogany"):
            row, d = pools.parse_block(Chain(50, line)("getblock", "14", 1))
            t = Chain(50).totals(14)
            self.assertEqual((row.height, row.monitored), (14, True))
            for k in pools.FIELDS:
                if k not in ("other", "vault_yed"):
                    self.assertEqual(getattr(row, k), t[k], (line, k))
            self.assertEqual((row.other, row.vault_yed), (0, t["vault"]))
            self.assertEqual(d["transparent_ecc"], 625_000_000)
            self.assertEqual(d["pq_falcon"], 11)
            c = pools.checks(row)
            self.assertEqual([c[k]["holds"] for k in ("transparent", "postQuantum", "supply")], [True, True, True])
            self.assertEqual(c["transparent"]["sumZat"], t["transparent"])

    def test_entries_are_read_by_id_not_position(self):
        b = Chain(50)("getblock", "9", 1)
        b["valuePools"].reverse()
        b["transparentPools"]["pools"].reverse()
        b["transparentPools"]["pq_by_scheme"].reverse()
        self.assertEqual(pools.parse_block(b)[0], pools.parse_block(Chain(50)("getblock", "9", 1))[0])

    def test_a_node_without_the_split_and_an_unmonitored_block(self):
        row, _ = pools.parse_block(Chain(50, "legacy")("getblock", "9", 1))
        self.assertFalse(row.monitored)
        self.assertEqual([getattr(row, k) for k in pools.SPLIT], [None] * len(pools.SPLIT))
        self.assertEqual(row.sapling, 500 * pools.ZAT + 27)
        c = pools.checks(row)
        self.assertEqual((c["transparent"]["holds"], c["postQuantum"]["holds"], c["supply"]["holds"]), (None, None, True))
        ch = Chain(50)
        ch.unmonitored_below = 30
        self.assertFalse(pools.parse_block(ch("getblock", "9", 1))[0].monitored)
        self.assertTrue(pools.parse_block(ch("getblock", "30", 1))[0].monitored)

    def test_a_sum_that_does_not_hold_is_reported(self):
        b = Chain(50)("getblock", "9", 1)
        b["transparentPools"]["pools"][0]["chainValueZat"] += 1
        b["transparentPools"]["pq_by_scheme"][1]["chainValueZat"] -= 1
        c = pools.checks(pools.parse_block(b)[0])
        self.assertEqual((c["transparent"]["holds"], c["postQuantum"]["holds"], c["supply"]["holds"]), (False, False, True))
        self.assertEqual(c["transparent"]["sumZat"] - c["transparent"]["expectedZat"], 1)

    def test_a_ycash_dd_answer_takes_transparent_from_the_split(self):
        b = Chain(50)("getblock", "9", 1)
        b["valuePools"] = [e for e in b["valuePools"] if e["id"] in ("sprout", "sapling")]
        del b["chainSupply"]
        row, _ = pools.parse_block(b)
        t = Chain(50).totals(9)
        self.assertEqual((row.transparent, row.supply, row.orchard), (t["transparent"], t["supply"], 0))


class Storing(unittest.TestCase):
    def rows(self, n):
        ch = Chain(n)
        return [pools.parse_block(ch("getblock", str(h), 1))[0] for h in range(n)]

    def test_rows_survive_a_restart_and_the_last_line_wins(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "samples.jsonl")
            s = pools.Store(p)
            s.load()
            rows = self.rows(6)
            for r in rows:
                s.put(r)
            s.put(rows[2])                              # the same row again: nothing written
            s.put(rows[3]._replace(hash="ff"))
            s.drop(4)
            self.assertEqual((s.lines, s.heights, s.top()), (8, [0, 1, 2, 3, 5], 5))
            with open(p, "a", encoding="utf-8") as f:
                f.write('[9,"torn')                     # a crash in the middle of a line
            t = pools.Store(p)
            t.load()
            self.assertEqual(t.heights, [0, 1, 2, 3, 5])
            self.assertEqual(t.get(3).hash, "ff")
            self.assertEqual(t.get(5), rows[5])
            self.assertEqual(t.lines, 5)                # rewritten at load: only the live rows
            with open(p, encoding="utf-8") as f:
                self.assertEqual(len(f.readlines()), 5)
            self.assertEqual(t.between(1, 3), [1, 2, 3])

    def test_the_file_is_rewritten_when_mostly_superseded(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "samples.jsonl")
            s = pools.Store(p)
            s.load()
            row = self.rows(1)[0]
            for i in range(1200):
                s.put(row._replace(time=i))
                s.compact()
            self.assertLess(s.lines, 1100)
            self.assertEqual(len(s), 1)
            s.wipe()
            self.assertEqual((len(s), os.path.getsize(p)), (0, 0))

    def test_no_file_without_a_path(self):
        s = pools.Store(None)
        s.load()
        s.put(self.rows(1)[0])
        s.compact(force=True)
        self.assertEqual(len(s), 1)


class Sampling(unittest.TestCase):
    def test_the_tiers(self):
        ch = Chain(1234, vault=1000, ycash=900)
        cfg, store, sm, api = service(ch)
        sm.round()
        want = set(range(1135, 1235)) | set(range(900, 1235, 10)) | set(range(0, 1235, 100))
        self.assertEqual(set(store.heights), want)
        self.assertEqual(sm.fine_from, 900)             # the earlier activation, floored to the coarse step
        self.assertEqual(sm.missing(1234), [])
        # one getblock per sample, and no call the service is not allowed
        self.assertEqual(sum(1 for c in ch.log if c[0] == "getblock"), len(want))
        self.assertEqual({c[0] for c in ch.log}, {"getblockchaininfo", "getblock"})
        self.assertEqual(sm.delta_mismatches, 0)
        n = ch.calls_made
        sm.round()                                      # nothing new: the tip poll only
        self.assertEqual(ch.calls_made, n + 1)
        self.assertIsNotNone(sm.backfill_done_at)

    def test_fine_from(self):
        for kw, env, want in ((dict(vault=1000), {}, 1000), (dict(vault=1000, ycash=900), {"FINE_MAX_SPAN": 300}, 1000),
                              (dict(), {}, 0), (dict(vault=100), {"FINE_MAX_SPAN": 300}, 900), (dict(vault=1000), {"FINE_FROM": 1200}, 1200)):
            ch = Chain(1234, **kw)
            cfg, store, sm, api = service(ch, **env)
            sm.round()
            self.assertEqual(sm.fine_from, want, (kw, env))

    def test_it_resumes_where_it_stopped(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "samples.jsonl")
            ch = Chain(1234, vault=1000)
            cfg, store, sm, api = service(ch, p, BACKFILL_BATCH=40)
            self.assertEqual(sm.round(), 40)
            self.assertEqual(len(store), 41)            # the tip and one batch, newest first
            self.assertEqual(store.heights[0], 1194)
            total = len(sm.missing(1234)) + len(store)
            ch2 = Chain(1234, vault=1000)
            cfg, store2, sm2, api2 = service(ch2, p)
            self.assertEqual(len(store2), 41)
            sm2.round()
            self.assertEqual(len(store2), total)
            self.assertEqual(sum(1 for c in ch2.log if c[0] == "getblock"), total - 41 + 1)     # + the tip again
            self.assertIn(("getblockhash", 1194), ch2.log)                                      # the stored rows were checked

    def test_new_blocks_and_the_recent_window(self):
        ch = Chain(1234, vault=1000)
        cfg, store, sm, api = service(ch)
        sm.round()
        n = ch.calls_made
        ch.tip = 1237
        sm.round()
        # the poll, the new tip by hash, one hash to confirm the stored chain, the two blocks between
        self.assertEqual(ch.log[n:n + 3], [("getblockchaininfo",), ("getblock", ch.hash(1237), 1), ("getblockhash", 1234)])
        self.assertEqual(sorted(c[1] for c in ch.log[n + 3:]), ["1235", "1236"])
        self.assertIsNone(store.get(1135))              # left the window, in no tier
        self.assertIsNotNone(store.get(1140))
        self.assertIsNotNone(store.get(1138))
        self.assertEqual(sm.reorg_drops, 0)

    def test_a_reorganisation_is_sampled_again(self):
        ch = Chain(1234, vault=1000)
        cfg, store, sm, api = service(ch)
        sm.round()
        old = store.get(1230)
        ch.reorg(1228, tip=1236)
        sm.round()
        self.assertEqual(sm.reorg_drops, 7)             # 1228..1234
        for h in range(1220, 1237):
            self.assertEqual(store.get(h).hash, ch.hash(h), h)
        self.assertNotEqual(store.get(1230), old)
        self.assertEqual(store.get(1230).pq_falcon, 11 * 1230 + 1)
        self.assertEqual(store.get(1227).pq_falcon, 11 * 1227)
        # a shorter chain: what is above the new tip goes
        ch.reorg(1231, tip=1232)
        sm.round()
        self.assertEqual(store.top(), 1232)
        self.assertEqual([store.get(h).hash for h in (1230, 1231, 1232)], [ch.hash(h) for h in (1230, 1231, 1232)])

    def test_a_reorganisation_while_stopped(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "samples.jsonl")
            ch = Chain(1234, vault=1000)
            service(ch, p)[2].round()
            ch.reorg(1225, tip=1240)
            cfg, store, sm, api = service(ch, p)
            sm.round()
            for h in store.between(1100, 1240):
                self.assertEqual(store.get(h).hash, ch.hash(h), h)
            self.assertEqual(len(store.between(1141, 1240)), 100)

    def test_another_chain_wipes_the_store(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "samples.jsonl")
            service(Chain(1234, vault=1000), p)[2].round()
            other = Chain(700)
            other.reorg(0)
            cfg, store, sm, api = service(other, p)
            sm.round()
            self.assertEqual(store.top(), 700)
            for h in store.heights:
                self.assertEqual(store.get(h).hash, other.hash(h))

    def test_a_node_that_is_away(self):
        ch = Chain(300)
        cfg, store, sm, api = service(ch)

        def down(*a, **k):
            raise pools.RpcError("getblockchaininfo: ConnectionRefusedError")
        sm.rpc = down
        with self.assertRaises(pools.RpcError):
            sm.round()
        self.assertEqual(api.current()["ready"], False)
        self.assertEqual(api.series({})[0], 503)
        sm.rpc = ch
        sm.round()
        self.assertEqual(api.current()["height"], 300)


class Answers(unittest.TestCase):
    def setUp(self):
        self.ch = Chain(1234, vault=1000)
        self.cfg, self.store, self.sm, self.api = service(self.ch, ONDEMAND_PER_REQUEST=30, ONDEMAND_PER_MINUTE=50)
        self.sm.round()

    def test_current(self):
        c = self.api.current()
        t = self.ch.totals(1234)
        self.assertEqual((c["height"], c["hash"], c["time"], c["monitored"], c["chain"]), (1234, self.ch.hash(1234), 1_700_000_000 + 150 * 1234, True, "test"))
        by = {p["id"]: p for p in c["pools"] + c["aggregates"]}
        self.assertEqual(by["pq_falcon"]["zat"], t["pq_falcon"])
        self.assertEqual(by["supply"]["yec"], pools.yec(t["supply"]))
        self.assertEqual(by["supply"]["sharePercent"], "100.0000")
        self.assertEqual(sum(p["zat"] for p in c["pools"]), t["supply"])          # the disjoint pools are the supply
        self.assertEqual({k: v["holds"] for k, v in c["checks"].items()}, {"transparent": True, "postQuantum": True, "supply": True})
        self.assertEqual(c["upgrades"], {"vault": 1000})
        self.assertEqual(c["history"]["complete"], True)
        self.assertEqual(c["links"]["block"], "/block/")
        json.dumps(c)

    def test_series_from_the_tiers(self):
        code, s = self.api.series({"from": "1140", "max": "300"})
        self.assertEqual((code, s["from"], s["to"], s["step"], s["complete"], s["points"]), (200, 1140, 1234, 1, True, 95))
        code, s = self.api.series({"from": "1000", "max": "30"})
        self.assertEqual((s["step"], s["heights"][:3], s["heights"][-2:], s["complete"]), (10, [1000, 1010, 1020], [1230, 1234], True))
        self.assertEqual(s["pools"]["pq_slh_dsa"], [7 * h for h in s["heights"]])
        self.assertEqual(s["times"][0], 1_700_000_000 + 150 * 1000)
        self.assertEqual(set(s["pools"]), set(pools.FIELDS))
        n = self.ch.calls_made
        code, s = self.api.series({"last": "50"})
        self.assertEqual((s["from"], s["to"], s["points"]), (1185, 1234, 50))
        code, s = self.api.series({"seconds": str(150 * 40)})
        self.assertEqual((s["from"], s["to"]), (1194, 1234))
        code, s = self.api.series({"from": "0", "max": "14"})
        self.assertEqual((s["step"], s["heights"]), (100, list(range(0, 1201, 100)) + [1234]))
        self.assertEqual(self.ch.calls_made, n)         # the tiers answered: the node was not asked
        self.assertEqual(self.api.series({"from": "x"})[0], 400)
        self.assertEqual(self.api.series({"from": "5000", "to": "9000"})[1]["heights"], [1234])
        self.assertLessEqual(self.api.series({"from": "0", "max": "100000"})[1]["points"], self.cfg.max_points)

    def test_series_that_needs_old_blocks_is_bounded(self):
        n = self.ch.calls_made
        code, s = self.api.series({"from": "200", "to": "400", "max": "101"})        # step 2: 101 heights, 3 stored
        self.assertEqual((s["step"], s["complete"]), (2, False))
        self.assertEqual(self.ch.calls_made - n, 30)                                 # ONDEMAND_PER_REQUEST
        self.assertEqual(s["points"], 33)
        self.api.series({"from": "200", "to": "400", "max": "101"})
        self.assertEqual(self.ch.calls_made - n, 50)                                 # ONDEMAND_PER_MINUTE: 20 left
        code, s = self.api.series({"from": "200", "to": "400", "max": "101"})
        self.assertEqual(self.ch.calls_made - n, 50)                                 # the budget is spent: stored rows only
        self.assertEqual((code, s["complete"], s["points"]), (200, False, 53))
        self.assertEqual(s["heights"], sorted(s["heights"]))
        self.assertEqual(s["pools"]["sapling"], [500 * pools.ZAT + 3 * h for h in s["heights"]])
        # a block inside the reorganisation margin is never fetched for a series (the sampler holds those)
        self.api.budget = pools.Budget(1000)
        self.store.drop(1230)
        m = self.ch.calls_made
        code, s = self.api.series({"from": "1225", "to": "1234"})
        self.assertEqual((self.ch.calls_made, s["complete"], 1230 in s["heights"]), (m, False, False))

    def test_a_mostly_unsampled_range_answers_with_what_is_stored(self):
        self.api.budget = pools.Budget(0)
        code, s = self.api.series({"from": "0", "to": "900", "max": "300"})
        self.assertEqual((s["complete"], s["heights"]), (False, list(range(0, 901, 100))))

    def test_deltas(self):
        code, d = self.api.deltas({"count": "5"})
        self.assertEqual((code, d["heights"]), (200, [1230, 1231, 1232, 1233, 1234]))
        self.assertEqual(d["deltas"]["transparent_ecc"], [625_000_000] * 5)
        self.assertEqual(d["deltas"]["pq_falcon"], [11] * 5)
        self.assertEqual(d["deltas"]["vault_intent"], [0, 0, 5, -5, 0])              # 1232 = 7 * 176
        self.assertEqual(self.api.deltas({"count": "100000"})[1]["count"], 99)       # the recent window
        self.assertEqual(self.api.deltas({"count": "x"})[0], 400)

    def test_limits(self):
        b = pools.Budget(10)
        self.assertEqual([b.take(4, 0), b.take(4, 1), b.take(4, 2), b.take(4, 30)], [4, 4, 2, 0])
        self.assertEqual(b.take(9, 60.5), 4)
        lim = pools.ClientLimit(3)
        self.assertEqual([lim.allow("a", 0) for _ in range(4)], [True, True, True, False])
        self.assertTrue(lim.allow("b", 0))
        self.assertTrue(lim.allow("a", 61))


class StubNode(http.server.BaseHTTPRequestHandler):
    chain = None
    seen = []

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).seen.append((self.headers.get("Authorization"), req["method"]))
        try:
            code, out = 200, {"result": self.chain(req["method"], *req["params"]), "error": None, "id": req["id"]}
        except pools.RpcError as e:
            code, out = 500, {"result": None, "error": {"code": -8, "message": str(e)}, "id": req["id"]}
        body = json.dumps(out).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


class OverHttp(unittest.TestCase):
    """The whole service: pools.Rpc against a stub JSON-RPC node, the handler on a real socket."""

    @classmethod
    def setUpClass(cls):
        cls.chain = Chain(640, "kogany", vault=600)
        StubNode.chain, StubNode.seen = cls.chain, []
        cls.node = http.server.ThreadingHTTPServer(("127.0.0.1", 0), StubNode)
        threading.Thread(target=cls.node.serve_forever, daemon=True).start()
        cls.tmp = tempfile.TemporaryDirectory()
        cookie = os.path.join(cls.tmp.name, ".cookie")
        with open(cookie, "w", encoding="utf-8") as f:
            f.write("__cookie__:secret\n")
        cls.cfg = config(RPC_URL=f"http://127.0.0.1:{cls.node.server_address[1]}/", RPC_COOKIE_FILE=cookie,
                         NETWORK_NAME="a test network", API_PER_MINUTE=40, TRUSTED_PROXY="127.0.0.1")
        cls.store = pools.Store(os.path.join(cls.tmp.name, "samples.jsonl"))
        cls.store.load()
        cls.rpc = pools.Rpc(cls.cfg)
        cls.sampler = pools.Sampler(cls.cfg, cls.rpc, cls.store)
        cls.sampler.round()
        cls.page, cls.csp = pools.load_page()
        api = pools.Api(cls.cfg, cls.rpc, cls.store, cls.sampler)
        cls.srv = pools.Server(("127.0.0.1", 0), pools.make_handler(cls.cfg, api, cls.page, cls.csp))
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.srv.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.node.shutdown()
        cls.srv.server_close()
        cls.node.server_close()
        cls.tmp.cleanup()

    def get(self, path, client="203.0.113.1"):
        req = urllib.request.Request(self.base + path, headers={"X-Forwarded-For": client})
        try:
            with urllib.request.build_opener(NoRedirect).open(req, timeout=10) as r:
                return r.status, dict(r.headers), r.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()

    def test_the_node_is_asked_with_the_cookie_and_only_reads(self):
        want = "Basic " + base64.b64encode(b"__cookie__:secret").decode()
        self.assertTrue(StubNode.seen)
        self.assertEqual({a for a, _ in StubNode.seen}, {want})
        self.assertLessEqual({m for _, m in StubNode.seen}, {"getblockchaininfo", "getblockhash", "getblock"})
        with self.assertRaises(pools.RpcError):
            self.rpc("sendrawtransaction", "00")
        with self.assertRaises(pools.RpcError):          # the node's error (HTTP 500) is an RpcError, not a crash
            self.rpc("getblockhash", 99999)
        self.assertEqual(self.rpc.errors, 1)

    def test_the_page(self):
        for path in ("/pools/", "/pools/index.html", "/"):
            code, h, body = self.get(path)
            self.assertEqual((code, h["Content-Type"]), (200, "text/html; charset=utf-8"))
            self.assertEqual(body, self.page)
        self.assertRegex(h["Content-Security-Policy"], r"^default-src 'none'; script-src 'sha256-[A-Za-z0-9+/=]{44}'; style-src 'sha256-[A-Za-z0-9+/=]{44}'; connect-src 'self';")
        self.assertEqual(h["X-Content-Type-Options"], "nosniff")
        code, h, _ = self.get("/pools")
        self.assertEqual((code, h["Location"]), (308, "/pools/"))
        self.assertEqual(self.get("/poolsx")[0], 404)
        self.assertEqual(self.get("/pools/../etc/passwd")[0], 404)
        self.assertEqual(self.get("/pools/healthz")[2], b"ok\n")

    def test_the_page_is_self_contained(self):
        page = self.page.decode()
        self.assertEqual((page.count("<script>"), page.count("<style>"), page.count("<script"), page.count("<style")), (1, 1, 1, 1))
        for needle in ("src=", "<link", "@import", "url(", "//cdn", "style=\"", "onclick", "innerHTML", "eval("):
            self.assertNotIn(needle, page, needle)
        import re
        for url in re.findall(r"https?://[^\s\"'<>)]+", page):
            self.assertIn(url, ("http://www.w3.org/2000/svg", "https://www.opensource.org/licenses/mit-license.php"), url)

    def test_the_api(self):
        code, h, body = self.get("/pools/api/v1/current")
        c = json.loads(body)
        self.assertEqual((code, h["Content-Type"], c["height"], c["network"], c["monitored"]), (200, "application/json", 640, "a test network", True))
        self.assertEqual({k: v["holds"] for k, v in c["checks"].items()}, {"transparent": True, "postQuantum": True, "supply": True})
        s = json.loads(self.get("/pools/api/v1/series?from=600&max=50")[2])
        self.assertEqual((s["heights"][0], s["heights"][-1], s["complete"]), (600, 640, True))
        self.assertEqual(s["pools"]["pq_falcon"], [11 * x for x in s["heights"]])
        d = json.loads(self.get("/pools/api/v1/deltas?count=3")[2])
        self.assertEqual(d["deltas"]["sapling"], [3, 3, 3])
        st = json.loads(self.get("/pools/api/v1/status")[2])
        self.assertEqual((st["tip"], st["historyComplete"], st["deltaMismatches"]), (640, True, 0))
        self.assertEqual(self.get("/pools/api/v1/nothing")[0], 404)
        self.assertEqual(self.get("/pools/api/v1/series?from=abc")[0], 400)

    def test_requests_per_client_are_limited(self):
        codes = [self.get("/pools/api/v1/current", client="198.51.100.7")[0] for _ in range(45)]
        self.assertEqual((codes.count(200), codes.count(429)), (40, 5))
        self.assertEqual(self.get("/pools/api/v1/current", client="198.51.100.8")[0], 200)     # another client is not affected
        self.assertEqual(self.get("/pools/", client="198.51.100.7")[0], 200)                   # the page itself is not counted


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


if __name__ == "__main__":
    unittest.main()
