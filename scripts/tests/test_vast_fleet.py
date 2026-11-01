#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Offline tests of scripts/vast-fleet.py against scripts/tests/fake_vast.py (nothing is rented).

Run: python3 -I -m unittest discover -s scripts/tests -p 'test_vast_fleet.py'   (make miners-test, CI)
"""

import contextlib
import copy
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "vast-fleet.py")
FAKE = os.path.join(HERE, "fake_vast.py")
EXAMPLE = os.path.join(HERE, "..", "..", "infra", "vast-miners", "fleet.example.json")
KEY = "c0ffee" + "0123456789abcdef" * 3 + "abcdef12345678"[:10]
NOW = 1_800_000_000          # a fixed "now" (2027-01-15), so burst times are deterministic
DIGEST = "ghcr.io/example/ycash-miner@sha256:" + "ab" * 32

spec = importlib.util.spec_from_file_location("vast_fleet", SCRIPT)
vf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vf)


def fleet_file(**changes):
    with open(EXAMPLE, encoding="utf-8") as f:
        raw = json.load(f)
    raw["image"] = DIGEST
    for i, net in enumerate(("fast", "slow", "legacy")):
        raw["networks"][net]["pools"] = [p.replace(".example", f".test{i}") for p in raw["networks"][net]["pools"]]
    for k, v in changes.items():
        net, field = k.split("__")
        raw["networks"][net][field] = v
    return raw


def offer(oid, gpu, price, machine=None, rel=0.99, **kw):
    o = {"id": oid, "gpu_name": gpu, "num_gpus": 1, "dph_total": price, "reliability": rel,
         "machine_id": machine or oid + 500}
    o.update(kw)
    return o


OFFERS = [
    offer(1, "RTX 3060", 0.061),
    offer(2, "RTX 3060", 0.058),
    offer(3, "RTX 3060", 0.040, rel=0.80),        # cheapest, but unreliable
    offer(4, "RTX 4090", 0.030),                   # cheapest, but not a card we asked for
    offer(5, "RTX 3070", 0.120),
    offer(6, "RTX 3070", 0.110),
    offer(7, "RTX 3070", 0.300),                   # over every cap
    offer(8, "RTX A4000", 0.135),
    offer(9, "RTX 3070", 0.125),
]


def inst(iid, label, status="running", start=NOW - 3600, **kw):
    r = {"id": iid, "label": label, "actual_status": status, "intended_status": "running",
         "gpu_name": "RTX 3060", "dph_total": 0.06, "public_ipaddr": f"198.51.100.{iid % 250}",
         "machine_id": iid + 9, "start_date": start, "extra_env": []}
    r.update(kw)
    return r


class FakeVast:
    def __init__(self, tmp, state):
        self.state, self.log = os.path.join(tmp, "state.json"), os.path.join(tmp, "log.jsonl")
        self.write(state)
        open(self.log, "w").close()
        port_file = os.path.join(tmp, "port")
        self.proc = subprocess.Popen([sys.executable, "-I", FAKE, "--state", self.state, "--log", self.log,
                                      "--port-file", port_file, "--key", KEY])
        for _ in range(100):
            if os.path.exists(port_file):
                break
            time.sleep(0.05)
        with open(port_file, encoding="utf-8") as f:
            self.url = f"http://127.0.0.1:{f.read().strip()}"

    def write(self, state):
        state.setdefault("now", NOW)
        with open(self.state, "w", encoding="utf-8") as f:
            json.dump(state, f)

    def read(self):
        with open(self.state, encoding="utf-8") as f:
            return json.load(f)

    def calls(self, method=None):
        with open(self.log, encoding="utf-8") as f:
            rows = [json.loads(line) for line in f if line.strip()]
        return [r for r in rows if method is None or r["method"] == method]

    def clear(self):
        open(self.log, "w").close()

    def stop(self):
        self.proc.terminate()
        self.proc.wait(5)


class Base(unittest.TestCase):
    state = None

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.fake = FakeVast(self.tmp, copy.deepcopy(self.state) if self.state else
                             {"instances": [], "offers": copy.deepcopy(OFFERS)})
        self.env = {"VAST_URL": self.fake.url, "VAST_API_KEY": KEY, "VAST_FLEET_PACE": "0",
                    "VAST_FLEET_NOW": str(NOW)}
        self.saved = {k: os.environ.get(k) for k in list(self.env) + ["GITHUB_ACTIONS", "GITHUB_OUTPUT",
                                                                      "GITHUB_STEP_SUMMARY"]}
        os.environ.update(self.env)
        for k in ("GITHUB_ACTIONS", "GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY"):
            os.environ.pop(k, None)
        vf._masked.clear()
        self.fleet = os.path.join(self.tmp, "fleet.json")
        self.set_fleet(fleet_file())

    def tearDown(self):
        self.fake.stop()
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def set_fleet(self, raw):
        with open(self.fleet, "w", encoding="utf-8") as f:
            json.dump(raw, f)

    def run_fleet(self, *args):
        vf._masked.clear()          # each run is a fresh process in real use
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = vf.main(["--fleet", self.fleet, *args])
        self.out = out.getvalue()
        return rc

    def labels(self):
        return sorted(str(i["label"]) for i in self.fake.read()["instances"])

    def creates(self):
        return [c for c in self.fake.calls("PUT") if c["path"].startswith("/api/v0/asks/")]


class TestFleetFile(unittest.TestCase):
    def parse(self, raw):
        return vf.parse_fleet(raw)

    def test_example_is_valid_and_has_placeholders(self):
        with open(EXAMPLE, encoding="utf-8") as f:
            fl = self.parse(json.load(f))
        self.assertEqual(fl["total"], 3)
        self.assertEqual({n: c["count"] for n, c in fl["networks"].items()}, {"fast": 1, "slow": 2, "legacy": 0})
        for cfg in fl["networks"].values():
            self.assertIsNotNone(vf.startable(cfg))

    def test_refuses_secret_looking_fields(self):
        for bad in ({"api_key": "x"}, {"vast_token": "x"}, {"password": "x"}, {"pool_pass": "x"}):
            raw = fleet_file()
            raw["networks"]["fast"].update(bad)
            with self.assertRaisesRegex(vf.FleetError, "secret"):
                self.parse(raw)
        raw = fleet_file()
        raw["VAST_API_KEY"] = KEY
        with self.assertRaisesRegex(vf.FleetError, "secret"):
            self.parse(raw)
        for value in (KEY, "ghp_" + "a" * 36, "-----BEGIN PRIVATE KEY-----"):
            raw = fleet_file(fast__comment=value)
            with self.assertRaisesRegex(vf.FleetError, "secret"):
                self.parse(raw)
        raw = fleet_file(fast__pools=["stratum+tcp://user:hunter2@pool.test0:3333"])
        with self.assertRaises(vf.FleetError):
            self.parse(raw)

    def test_refuses_bad_values(self):
        cases = [
            fleet_file(fast__count=9), fleet_file(fast__max_dph=5), fleet_file(fast__rental="spot"),
            fleet_file(fast__pools=["pool.test0"]), fleet_file(fast__pools=[]),
            fleet_file(fast__extra_args=["--pass", "x"]), fleet_file(fast__extra_args=["--user=someone"]),
            fleet_file(fast__extra_args=["$(id)"]), fleet_file(fast__payout="not an address"),
            fleet_file(fast__image="ghcr.io/example/ycash-miner:latest"), fleet_file(fast__gpu_names=[]),
            fleet_file(fast__unknown_field=1),
        ]
        for raw in cases:
            with self.assertRaises(vf.FleetError):
                self.parse(raw)
        raw = fleet_file()
        for n in ("a1", "a2", "a3"):
            raw["networks"][n] = dict(raw["networks"]["slow"], count=5)
        with self.assertRaisesRegex(vf.FleetError, "at most"):
            self.parse(raw)

    def test_miner_field(self):
        fl = self.parse(fleet_file())
        self.assertEqual({c["miners"][0] for c in fl["networks"].values()}, {"lolminer"})   # the default
        for bad in ("xmrig", "", [], ["lolminer", "gminer"], 3):
            with self.assertRaises(vf.FleetError):
                self.parse(fleet_file(slow__miner=bad))
        # miniz is refused until the fleet carries both pins
        with self.assertRaisesRegex(vf.FleetError, "miniz_url"):
            self.parse(fleet_file(slow__miner=["lolminer", "miniz"]))
        raw = fleet_file(slow__miner=["lolminer", "miniz"])
        raw["miniz_url"] = "https://downloads.example/miniZ_linux-x64.tar.gz"
        with self.assertRaisesRegex(vf.FleetError, "both"):
            self.parse(raw)
        raw["miniz_sha256"] = "ab" * 32           # 64 hex: a checksum, not taken for a secret
        fl = self.parse(raw)
        self.assertEqual(fl["networks"]["slow"]["miners"], ["lolminer", "miniz"])
        raw["miniz_url"] = "http://downloads.example/miniZ.tar.gz"
        with self.assertRaises(vf.FleetError):
            self.parse(raw)
        raw = fleet_file(fast__comment="ab" * 32)    # the same 64 hex elsewhere is still refused
        with self.assertRaisesRegex(vf.FleetError, "secret"):
            self.parse(raw)

    def test_labels(self):
        self.assertEqual(vf.parse_label("ycash-fast-0")[:2], ("fast", 0))
        self.assertIsNotNone(vf.parse_label("ycash-legacy-3.until-20270115T1200Z")[2])
        for other in (None, "", "ycash-fast", "ycash-fast-x", "ycash-Fast-0", "my-ycash-fast-0", "ycash-fast-0 ",
                      "ycash-fast-0.until-tomorrow", "ycash-fast-1234"):
            self.assertIsNone(vf.parse_label(other), other)

    def test_only_https_or_local(self):
        with self.assertRaises(vf.ApiError):
            vf.Vast(KEY, "http://console.example")
        with self.assertRaises(vf.ApiError):
            vf.Vast("", "https://console.example")
        vf.Vast(KEY, "http://127.0.0.1:1")


class TestReconcile(Base):
    def test_starts_the_fleet_cheapest_under_the_cap(self):
        self.assertEqual(self.run_fleet("reconcile"), 0, self.out)
        self.assertEqual(self.labels(), ["ycash-fast-0", "ycash-slow-0", "ycash-slow-1"])
        rents = {c["body"]["label"]: (int(c["path"].split("/")[4]), c["body"]) for c in self.creates()}
        self.assertEqual(rents["ycash-fast-0"][0], 2)          # 0.058: not 4 (wrong card), not 3 (reliability)
        self.assertEqual({rents["ycash-slow-0"][0], rents["ycash-slow-1"][0]}, {6, 5})   # 0.110, 0.120
        body = rents["ycash-slow-1"][1]
        self.assertEqual(body["image"], DIGEST)
        self.assertEqual(body["runtype"], "args")
        self.assertIsNone(body["price"])
        self.assertTrue(body["cancel_unavail"])
        self.assertEqual(body["env"], {"POOL_URL": "pool-b.test1:3333", "WORKER": "vast-slow-1", "MINER": "lolminer"})
        self.assertEqual(rents["ycash-slow-0"][1]["env"]["POOL_URL"], "pool-a.test1:3333")
        self.assertEqual(body["env"]["POOL_URL"], "pool-b.test1:3333")       # round-robin over the pools
        self.assertEqual(body["env"]["WORKER"], "vast-slow-1")
        # every created instance is labelled again explicitly
        relabels = [c for c in self.fake.calls("PUT") if c["path"].startswith("/api/v0/instances/")]
        self.assertEqual(len(relabels), 3)
        # idempotent: a second run changes nothing
        self.fake.clear()
        self.assertEqual(self.run_fleet("reconcile"), 0, self.out)
        self.assertEqual(self.fake.calls("PUT") + self.fake.calls("DELETE"), [])

    def test_payout_and_extra_args_reach_the_env(self):
        addr = "s1" + "a" * 33
        self.set_fleet(fleet_file(fast__payout=addr, fast__extra_args=["--devices", "0"]))
        self.assertEqual(self.run_fleet("reconcile", "--network", "fast"), 0, self.out)
        env = self.creates()[0]["body"]["env"]
        self.assertEqual(env["PAYOUT"], addr)
        self.assertEqual(env["MINER_ARGS"], "--devices 0")
        self.assertEqual(self.labels(), ["ycash-fast-0"])

    def test_miner_per_slot_and_drift(self):
        raw = fleet_file()
        self.assertEqual(self.run_fleet("reconcile", "--network", "slow"), 0, self.out)
        raw["miniz_url"] = "https://downloads.example/miniZ_linux-x64.tar.gz"
        raw["miniz_sha256"] = "cd" * 32
        raw["networks"]["slow"]["miner"] = ["lolminer", "miniz"]
        self.set_fleet(raw)
        self.fake.clear()
        self.assertEqual(self.run_fleet("reconcile", "--network", "slow"), 0, self.out)
        deleted = [c["path"] for c in self.fake.calls("DELETE")]
        self.assertEqual(len(deleted), 1)                  # slot 1 changes miner: replaced; slot 0 kept
        (c,) = self.creates()
        self.assertEqual(c["body"]["label"], "ycash-slow-1")
        self.assertEqual(c["body"]["env"]["MINER"], "miniz")
        self.assertEqual(c["body"]["env"]["MINIZ_URL"], raw["miniz_url"])
        self.assertEqual(c["body"]["env"]["MINIZ_SHA256"], "cd" * 32)
        self.fake.clear()
        self.assertEqual(self.run_fleet("reconcile", "--network", "slow"), 0, self.out)
        self.assertEqual(self.fake.calls("DELETE") + self.creates(), [])

    def test_respects_the_price_cap(self):
        st = self.fake.read()
        st["offers"] = [offer(11, "RTX 3060", 0.20), offer(12, "RTX 3070", 0.31)]
        self.fake.write(st)
        self.assertEqual(self.run_fleet("reconcile"), 1)
        self.assertEqual(self.creates(), [])
        self.assertIn("no offer", self.out)

    def test_checks_the_card_itself(self):
        st = self.fake.read()
        st["filter_gpus"] = False       # a search that ignores the card filter: the script still checks
        st["offers"] = [offer(21, "RTX 4090", 0.01), offer(22, "RTX 3060", 0.07)]
        self.fake.write(st)
        self.assertEqual(self.run_fleet("reconcile", "--network", "fast"), 0, self.out)
        self.assertEqual([int(c["path"].split("/")[4]) for c in self.creates()], [22])

    def test_replaces_a_dead_or_stuck_miner(self):
        self.fake.write({"offers": copy.deepcopy(OFFERS), "instances": [
            inst(101, "ycash-fast-0", status="exited"),
            inst(102, "ycash-slow-0", status="loading", start=NOW - 2 * 3600),   # stuck starting
            inst(103, "ycash-slow-1", status="loading", start=NOW - 60),         # just starting: kept
        ]})
        self.assertEqual(self.run_fleet("reconcile"), 0, self.out)
        deleted = sorted(int(c["path"].split("/")[4]) for c in self.fake.calls("DELETE"))
        self.assertEqual(deleted, [101, 102])
        self.assertEqual(sorted(c["body"]["label"] for c in self.creates()), ["ycash-fast-0", "ycash-slow-0"])
        self.assertEqual(self.labels(), ["ycash-fast-0", "ycash-slow-0", "ycash-slow-1"])

    def test_destroys_extras_and_never_touches_others(self):
        others = [inst(201, None), inst(202, "my-training-job"), inst(203, "ycash-fast"),
                  inst(204, "ycash-fast-x"), inst(205, "YCASH-fast-0"), inst(206, "notycash-fast-0")]
        self.fake.write({"offers": copy.deepcopy(OFFERS), "instances": others + [
            inst(301, "ycash-fast-0"), inst(302, "ycash-fast-1"),                  # above count 1
            inst(303, "ycash-slow-0"), inst(304, "ycash-slow-0", start=NOW - 60),  # two in one slot
            inst(305, "ycash-slow-1"), inst(306, "ycash-oldnet-0"),               # a network not in the file
            inst(307, "ycash-legacy-0.until-20200101T0000Z"),                     # a burst long over
        ]})
        self.assertEqual(self.run_fleet("reconcile"), 0, self.out)
        deleted = sorted(int(c["path"].split("/")[4]) for c in self.fake.calls("DELETE"))
        self.assertEqual(deleted, [302, 304, 306, 307])
        self.assertEqual(self.creates(), [])
        left = {i["id"] for i in self.fake.read()["instances"]}
        self.assertTrue({201, 202, 203, 204, 205, 206} <= left)
        # down destroys every one of ours and still none of the others
        self.fake.clear()
        self.assertEqual(self.run_fleet("down"), 0, self.out)
        self.assertEqual({i["id"] for i in self.fake.read()["instances"]}, {201, 202, 203, 204, 205, 206})

    def test_down_one_network(self):
        self.assertEqual(self.run_fleet("reconcile"), 0)
        self.assertEqual(self.run_fleet("down", "--network", "slow"), 0, self.out)
        self.assertEqual(self.labels(), ["ycash-fast-0"])

    def test_placeholder_pool_refuses_that_network_only(self):
        self.set_fleet(fleet_file(slow__pools=["pool-a.example:3333", "pool-b.test1:3333"]))
        self.assertEqual(self.run_fleet("reconcile"), 1)
        self.assertEqual(self.labels(), ["ycash-fast-0"])
        self.assertIn("placeholder", self.out)
        raw = fleet_file()
        raw["image"] = "ghcr.io/example/ycash-miner@sha256:" + "0" * 64
        self.set_fleet(raw)
        self.assertEqual(self.run_fleet("reconcile", "--network", "slow"), 1)
        self.assertIn("image digest", self.out)

    def test_dry_run_changes_nothing(self):
        self.fake.write({"offers": copy.deepcopy(OFFERS), "instances": [inst(401, "ycash-fast-0", status="exited"),
                                                                         inst(402, "ycash-oldnet-1")]})
        self.assertEqual(self.run_fleet("--dry-run", "reconcile"), 0, self.out)
        self.assertEqual(self.fake.calls("PUT") + self.fake.calls("DELETE"), [])
        self.assertIn("destroy ycash-oldnet-1", self.out)
        self.assertIn("start ycash-slow-1", self.out)

    def test_interruptible_bids_under_the_cap(self):
        st = self.fake.read()
        st["offers"] = [offer(31, "RTX 3060", 0.09, min_bid=0.030), offer(32, "RTX 3060", 0.09, min_bid=0.095)]
        self.fake.write(st)
        self.set_fleet(fleet_file(fast__rental="interruptible"))
        self.assertEqual(self.run_fleet("reconcile", "--network", "fast"), 0, self.out)
        (c,) = self.creates()
        self.assertEqual(int(c["path"].split("/")[4]), 31)
        self.assertAlmostEqual(c["body"]["price"], 0.034)
        self.assertLessEqual(c["body"]["price"], 0.09)

    def test_offer_gone_tries_the_next_and_no_credit_stops(self):
        st = self.fake.read()
        st["fail_offers"] = [2]
        self.fake.write(st)
        self.assertEqual(self.run_fleet("reconcile", "--network", "fast"), 0, self.out)
        self.assertEqual([int(c["path"].split("/")[4]) for c in self.creates()], [2, 1])
        self.run_fleet("down")
        st = self.fake.read()
        st["credit"] = False
        self.fake.write(st)
        self.fake.clear()
        self.assertEqual(self.run_fleet("reconcile"), 1)
        self.assertEqual(len(self.creates()), 1)     # the first refusal stops the rest
        self.assertIn("credit", self.out)

    def test_a_dropped_label_is_set_again(self):
        st = self.fake.read()
        st["drop_labels"] = True
        self.fake.write(st)
        self.assertEqual(self.run_fleet("reconcile", "--network", "fast"), 0, self.out)
        self.assertEqual(self.labels(), ["ycash-fast-0"])

    def test_many_instances_are_paged(self):
        self.fake.write({"offers": copy.deepcopy(OFFERS),
                         "instances": [inst(500 + i, f"job-{i}") for i in range(60)] + [inst(600, "ycash-oldnet-0")]})
        self.assertEqual(self.run_fleet("--dry-run", "status"), 0, self.out)
        self.assertIn("60 other instance(s)", self.out)
        self.assertEqual(len(self.fake.calls("GET")), 3)


class TestBurst(Base):
    def test_burst_then_expiry(self):
        self.assertEqual(self.run_fleet("burst", "legacy", "2", "--hours", "3"), 0, self.out)
        self.assertEqual(self.labels(), ["ycash-legacy-0.until-20270115T1100Z", "ycash-legacy-1.until-20270115T1100Z"])
        # the other networks are not touched by a burst
        self.assertFalse(any("fast" in c["body"]["label"] or "slow" in c["body"]["label"] for c in self.creates()))
        # a reconcile inside the window keeps them
        self.fake.clear()
        self.assertEqual(self.run_fleet("reconcile", "--network", "legacy"), 0, self.out)
        self.assertEqual(self.fake.calls("DELETE"), [])
        # expire inside the window: nothing, burst_active=2
        self.assertEqual(self.run_fleet("expire"), 0)
        self.assertIn("burst_active=2", self.out)
        # after the window: expire destroys them and never starts anything
        os.environ["VAST_FLEET_NOW"] = str(NOW + 3 * 3600 + 120)
        self.fake.clear()
        self.assertEqual(self.run_fleet("expire"), 0, self.out)
        self.assertEqual(len(self.fake.calls("DELETE")), 2)
        self.assertEqual(self.creates(), [])
        self.assertIn("burst_active=0", self.out)

    def test_burst_extends_and_shrinks(self):
        self.set_fleet(fleet_file(slow__count=1))
        self.assertEqual(self.run_fleet("burst", "slow", "3", "--hours", "2"), 0, self.out)
        self.assertEqual(self.labels(), ["ycash-slow-0", "ycash-slow-1.until-20270115T1000Z",
                                         "ycash-slow-2.until-20270115T1000Z"])
        # a later burst of 2 for longer: slot 2 goes, slot 1 is relabelled (no new rental)
        os.environ["VAST_FLEET_NOW"] = str(NOW + 1200)     # 20 min on: still starting, not stuck
        self.fake.clear()
        self.assertEqual(self.run_fleet("burst", "slow", "2", "--hours", "5"), 0, self.out)
        self.assertEqual(self.creates(), [])
        self.assertEqual(self.labels(), ["ycash-slow-0", "ycash-slow-1.until-20270115T1320Z"])

    def test_burst_limits(self):
        self.assertEqual(self.run_fleet("burst", "legacy", "0", "--hours", "3"), 1)
        self.assertEqual(self.run_fleet("burst", "legacy", "2", "--hours", "500"), 1)
        self.assertEqual(self.run_fleet("burst", "nosuch", "2", "--hours", "3"), 1)
        self.assertEqual(self.creates(), [])


class TestImage(unittest.TestCase):
    def test_image_names(self):
        ok = ["ghcr.io/example/ycash-miner@sha256:" + "a" * 64,
              "registry.example:5000/team/miner@sha256:" + "b" * 64,
              "miner@sha256:" + "c" * 64]
        bad = ["ghcr.io/example/ycash-miner:latest", "ghcr.io/x@sha256:" + "a" * 63,
               "a@b@sha256:" + "a" * 64, "UPPER/x@sha256:" + "a" * 64, 7]
        for i in ok:
            self.assertTrue(vf.image_ok(i), i)
        for i in bad:
            self.assertFalse(vf.image_ok(i), i)

    def test_no_backtracking(self):
        import time
        t = time.time()
        self.assertFalse(vf.image_ok("0/" + "-/" * 5000 + "!@sha256:" + "a" * 64))
        self.assertLess(time.time() - t, 1.0)


class TestSecrets(Base):
    def test_key_never_printed_and_ids_masked_in_actions(self):
        self.fake.write({"offers": copy.deepcopy(OFFERS), "instances": [inst(7000123, "ycash-fast-0")]})
        os.environ["GITHUB_ACTIONS"] = "true"
        self.assertEqual(self.run_fleet("reconcile"), 0, self.out)
        self.run_fleet("status")
        out = self.out
        visible = "\n".join(line for line in out.splitlines() if not line.startswith("::add-mask::"))
        self.assertNotIn(KEY, out)                       # not even in an ::add-mask:: line
        self.assertIn("::add-mask::7000123", out)
        self.assertIn("::add-mask::198.51.100.", out)
        self.assertNotIn(KEY, visible)
        self.assertNotIn("7000123", visible)
        self.assertNotIn("198.51.100.", visible)

    def test_key_never_printed_outside_actions_and_on_errors(self):
        os.environ["VAST_API_KEY"] = KEY[:-1] + "0"      # a wrong key: the fake answers 401 and echoes it
        self.assertEqual(self.run_fleet("status"), 1)
        self.assertNotIn(KEY[:-1], self.out)
        self.assertIn("401", self.out)
        os.environ["VAST_API_KEY"] = KEY
        self.assertEqual(self.run_fleet("reconcile"), 0)
        self.assertNotIn(KEY, self.out)
        self.assertNotIn("::add-mask::", self.out)

    def test_no_key_no_call(self):
        os.environ.pop("VAST_API_KEY")
        self.assertEqual(self.run_fleet("status"), 1)
        self.assertEqual(self.fake.calls(), [])
        self.assertEqual(self.run_fleet("validate"), 0)
        self.assertEqual(self.run_fleet("total"), 0)
        self.assertEqual(self.out.strip(), "3")


if __name__ == "__main__":
    unittest.main()
