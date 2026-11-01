#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""vast-fleet: keep a fleet of rented GPU miners on Vast.ai at the size a fleet file asks for.

In plain words: the Ycash testnets need someone mining, and mining needs graphics cards. Vast.ai
rents out other people's graphics cards by the hour. This script reads a small file that says,
per testnet, how many miners to run, which cards, the most to pay per hour and which pools to mine
into, then compares that with what is actually rented and fixes the difference: it rents the
cheapest matching card for a missing miner, replaces one that died, and gives back any that are
no longer wanted. It only ever touches machines it labelled itself (``ycash-<network>-<n>``).

Actions (python3 -I scripts/vast-fleet.py --fleet FILE ACTION ...):
  validate              check the fleet file, offline (no key needed)
  total                 print the number of miners the file asks for, offline
  status                what is rented: per network, each miner's slot, state, card and price
  reconcile             make it so: start missing miners (cheapest offer under the cap, spread over
                        the pools round-robin), replace dead ones, destroy extras and anything
                        labelled ours that the file no longer has. --network NET: that one only
  down [--network NET]  destroy every miner of ours (or one network's)
  burst NET N --hours H run N miners on NET for H hours (slots above the file's count are labelled
                        ycash-NET-I.until-YYYYMMDDTHHMMZ and expire by themselves), then reconcile it
  expire                destroy only the burst miners whose time is up; never starts one

--dry-run prints what would change and changes nothing (it still reads the account and searches
offers). The API key comes only from the environment, VAST_API_KEY; it is never printed, and in
GitHub Actions every instance id and host address is masked (::add-mask::) before anything is
printed. Instances without one of our labels are counted and never touched. A fleet file with a
field that looks like a secret is refused: the miners run on strangers' machines and may carry only
a pool address, a worker name and a payout address.

The REST API used (as the vastai CLI 1.10.0 calls it, https://console.vast.ai):
  GET    /api/v1/instances/      the account's instances, paged (next_token -> after_token)
  POST   /api/v0/bundles/        search offers (type on-demand | bid)
  PUT    /api/v0/asks/<offer>/   rent an offer (label, image, env, disk, runtype args, price for bid)
  PUT    /api/v0/instances/<id>/ relabel (a burst's end time)
  DELETE /api/v0/instances/<id>/ destroy
Standard library only.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

FORMAT = "ycash-vast-fleet/1"
DEFAULT_URL = "https://console.vast.ai"
NET_RE = re.compile(r"^[a-z][a-z0-9]{0,15}$")
LABEL_RE = re.compile(r"^ycash-([a-z][a-z0-9]{0,15})-([0-9]{1,3})(?:\.until-([0-9]{8}T[0-9]{4}Z))?$")
UNTIL_FMT = "%Y%m%dT%H%MZ"
WORKER_RE = re.compile(r"^[A-Za-z0-9._-]{1,48}$")
PAYOUT_RE = re.compile(r"^[1-9A-HJ-NP-Za-km-z]{26,40}$")
IMAGE_RE = re.compile(r"^[a-z0-9][a-z0-9./_-]*(?::[0-9]+)?(?:/[a-z0-9./_-]+)*@sha256:[0-9a-f]{64}$")
POOL_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})?:([0-9]{1,5})$")
ARG_RE = re.compile(r"^[A-Za-z0-9=,._:/*-]+$")
GPU_RE = re.compile(r"^[A-Za-z0-9 ._-]{2,40}$")
# Hard limits, whatever the file says: a typo must not rent a farm.
MAX_TOTAL = 16
MAX_PER_NET = 8
MAX_DPH = 1.0
MAX_BURST_HOURS = 168
STARTING = {"", "created", "loading", "scheduling", "starting"}
SECRET_KEY_RE = re.compile(r"(key|secret|token|pass|auth|cred|private|mnemonic|seed|cookie|bearer)", re.I)
SECRET_VALUE_RES = [
    re.compile(r"-----BEGIN"),
    re.compile(r"^(gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}"),
    re.compile(r"^[A-Fa-f0-9]{40,}$"),          # a bare long hex string (Vast API keys are 64 hex)
    re.compile(r"^[A-Za-z0-9+/_-]{40,}={0,2}$"),  # a long token-like string
    re.compile(r"://[^/@\s]*:[^/@\s]*@"),       # user:password@ in a URL
]
NET_KEYS = {"count", "gpu_names", "max_dph", "min_reliability", "rental", "pools", "worker_prefix",
            "payout", "extra_args", "image", "disk_gb", "comment"}
TOP_KEYS = {"format", "image", "disk_gb", "max_start_minutes", "comment", "networks"}
FORBIDDEN_ARGS = {"-p", "--pool", "-u", "--user", "--pass", "--dualpool", "--dualuser", "--dualpass",
                  "-a", "--algo", "--pers", "-c", "--coin", "--config", "--json", "--profile",
                  "--watchdogscript", "--apihost", "--apiport", "--tls", "--socks5", "--dns-over-https"}


class FleetError(Exception):
    pass


class ApiError(Exception):
    pass


# ---------------------------------------------------------------------------------------------
# output: GitHub Actions masking and summary

def in_actions():
    return bool(os.environ.get("GITHUB_ACTIONS"))


_masked = set()


def mask(value):
    """Hide a value in GitHub Actions logs from here on (prints nothing outside Actions)."""
    v = str(value or "").strip()
    if v and v not in _masked and in_actions():
        _masked.add(v)
        print(f"::add-mask::{v}", flush=True)


def say(msg=""):
    print(msg, flush=True)


def summary(lines):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")


def output(key, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"{key}={value}\n")
    say(f"{key}={value}")


# ---------------------------------------------------------------------------------------------
# the fleet file

def is_placeholder_pool(hostport):
    host = hostport.rsplit(":", 1)[0].lower()
    return (host == "example" or host.endswith(".example") or host.endswith(".invalid")
            or "replace" in host or "placeholder" in host or "todo" in host)


def is_placeholder_image(image):
    return image.endswith("@sha256:" + "0" * 64)


def normalize_pool(url):
    hp = url[len("stratum+tcp://"):] if url.startswith("stratum+tcp://") else url
    if "@" in hp or "://" in hp:
        raise FleetError(f"pool {url!r}: host:port or stratum+tcp://host:port, no user or password")
    m = POOL_RE.match(hp)
    if not m or not 1 <= int(m.group(2)) <= 65535:
        raise FleetError(f"pool {url!r}: host:port or stratum+tcp://host:port")
    return hp


def scan_secrets(node, path="$"):
    """Refuse any field that looks like a credential: by name anywhere, by value in any string."""
    if isinstance(node, dict):
        for k, v in node.items():
            if SECRET_KEY_RE.search(str(k)):
                raise FleetError(f"{path}.{k}: a field named like a secret; the fleet file holds no keys, "
                                 "passwords or tokens (the API key comes from VAST_API_KEY)")
            scan_secrets(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            scan_secrets(v, f"{path}[{i}]")
    elif isinstance(node, str):
        s = node.split("@sha256:")[0] if "@sha256:" in node else node
        for r in SECRET_VALUE_RES:
            if r.search(s):
                raise FleetError(f"{path}: a value that looks like a secret; the fleet file holds no keys, "
                                 "passwords or tokens")


def load_fleet(path):
    try:
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, ValueError) as e:
        raise FleetError(f"{path}: {e}") from None
    return parse_fleet(raw)


def parse_fleet(raw):
    if not isinstance(raw, dict):
        raise FleetError("the fleet file is a JSON object")
    scan_secrets(raw)
    unknown = set(raw) - TOP_KEYS
    if unknown:
        raise FleetError(f"unknown top-level field(s): {', '.join(sorted(unknown))}")
    if raw.get("format") != FORMAT:
        raise FleetError(f"format must be {FORMAT!r}")
    nets = raw.get("networks")
    if not isinstance(nets, dict) or not nets:
        raise FleetError("networks: an object with at least one network")
    default_image = raw.get("image", "")
    default_disk = raw.get("disk_gb", 8)
    fleet = {"max_start_minutes": raw.get("max_start_minutes", 30), "networks": {}}
    if not isinstance(fleet["max_start_minutes"], int) or not 5 <= fleet["max_start_minutes"] <= 240:
        raise FleetError("max_start_minutes: 5 to 240")
    total = 0
    for name, n in nets.items():
        where = f"networks.{name}"
        if not NET_RE.match(name):
            raise FleetError(f"{where}: a network name is lowercase letters and digits, 1 to 16")
        if not isinstance(n, dict):
            raise FleetError(f"{where}: an object")
        unknown = set(n) - NET_KEYS
        if unknown:
            raise FleetError(f"{where}: unknown field(s): {', '.join(sorted(unknown))}")
        count = n.get("count")
        if not isinstance(count, int) or isinstance(count, bool) or not 0 <= count <= MAX_PER_NET:
            raise FleetError(f"{where}.count: an integer 0 to {MAX_PER_NET}")
        total += count
        gpus = n.get("gpu_names")
        if not isinstance(gpus, list) or not gpus or not all(isinstance(g, str) and GPU_RE.match(g) for g in gpus):
            raise FleetError(f"{where}.gpu_names: a non-empty list of GPU names as Vast lists them, e.g. \"RTX 3060\"")
        max_dph = n.get("max_dph")
        if not isinstance(max_dph, (int, float)) or isinstance(max_dph, bool) or not 0 < max_dph <= MAX_DPH:
            raise FleetError(f"{where}.max_dph: dollars per hour, above 0 and at most {MAX_DPH}")
        rel = n.get("min_reliability", 0.95)
        if not isinstance(rel, (int, float)) or isinstance(rel, bool) or not 0 <= rel <= 1:
            raise FleetError(f"{where}.min_reliability: 0 to 1")
        rental = n.get("rental", "on-demand")
        if rental not in ("on-demand", "interruptible"):
            raise FleetError(f"{where}.rental: on-demand or interruptible")
        pools = n.get("pools")
        if not isinstance(pools, list) or not pools or not all(isinstance(p, str) for p in pools):
            raise FleetError(f"{where}.pools: a non-empty list of stratum pools (host:port)")
        pools = [normalize_pool(p) for p in pools]
        prefix = n.get("worker_prefix", f"vast-{name}")
        if not isinstance(prefix, str) or not WORKER_RE.match(prefix):
            raise FleetError(f"{where}.worker_prefix: letters, digits, . _ -, at most 48")
        payout = n.get("payout", "")
        if not isinstance(payout, str) or (payout and not PAYOUT_RE.match(payout)):
            raise FleetError(f"{where}.payout: empty (the pool pays its own address) or a transparent address")
        args = n.get("extra_args", [])
        if not isinstance(args, list) or not all(isinstance(a, str) and ARG_RE.match(a) for a in args):
            raise FleetError(f"{where}.extra_args: a list of plain miner options")
        for a in args:
            if a.split("=", 1)[0] in FORBIDDEN_ARGS:
                raise FleetError(f"{where}.extra_args: {a} is set by the image or not allowed")
        image = n.get("image", default_image)
        if not isinstance(image, str) or not IMAGE_RE.match(image):
            raise FleetError(f"{where}.image: an image by digest, <repository>@sha256:<64 hex>")
        disk = n.get("disk_gb", default_disk)
        if not isinstance(disk, int) or isinstance(disk, bool) or not 4 <= disk <= 64:
            raise FleetError(f"{where}.disk_gb: 4 to 64")
        fleet["networks"][name] = {
            "count": count, "gpu_names": gpus, "max_dph": float(max_dph), "min_reliability": float(rel),
            "rental": rental, "pools": pools, "worker_prefix": prefix, "payout": payout,
            "extra_args": args, "image": image, "disk_gb": disk,
        }
    if total > MAX_TOTAL:
        raise FleetError(f"the fleet asks for {total} miners; at most {MAX_TOTAL}")
    fleet["total"] = total
    return fleet


def startable(cfg):
    """Why a network cannot start miners yet (placeholders left in the file), or None."""
    bad = [p for p in cfg["pools"] if is_placeholder_pool(p)]
    if bad:
        return f"its pool address is still a placeholder ({len(bad)} of {len(cfg['pools'])}): fill in the fleet file"
    if is_placeholder_image(cfg["image"]):
        return "its image digest is still the all-zero placeholder: build the miner image and fill in its digest"
    return None


# ---------------------------------------------------------------------------------------------
# the Vast REST API

class Vast:
    def __init__(self, key, url=None, pace=None):
        if not key:
            raise ApiError("VAST_API_KEY is not set")
        self.key = key
        self.url = (url or DEFAULT_URL).rstrip("/")
        u = urllib.parse.urlparse(self.url)
        if not (u.scheme == "https" or (u.scheme == "http" and u.hostname in ("127.0.0.1", "localhost"))):
            raise ApiError("VAST_URL must be https (http only for a local stand-in)")
        self.pace = float(os.environ.get("VAST_FLEET_PACE", "1") if pace is None else pace)

    def redact(self, text):
        text = str(text).replace(self.key, "<key>")
        text = re.sub(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", "<ip>", text)
        return text[:300]

    def call(self, method, path, query=None, body=None):
        url = self.url + path
        if query:
            url += "?" + "&".join(f"{k}={urllib.parse.quote_plus(v if isinstance(v, str) else json.dumps(v))}"
                                  for k, v in query.items())
        data = None if body is None else json.dumps(body).encode()
        delay = 2.0
        for attempt in range(4):
            req = urllib.request.Request(url, data=data, method=method, headers={
                "Authorization": "Bearer " + self.key, "Accept": "application/json",
                "Content-Type": "application/json", "User-Agent": "ycash-vast-fleet/1"})
            try:
                with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310 (https, or a local stand-in: checked in __init__)
                    text = r.read().decode() or "{}"
                    return json.loads(text)
            except urllib.error.HTTPError as e:
                body_text = e.read().decode(errors="replace")
                if e.code in (429, 502, 503, 504) and attempt < 3:
                    time.sleep(delay * self.pace)
                    delay *= 2
                    continue
                raise ApiError(f"{method} {path.split('?')[0]}: HTTP {e.code}: {self.redact(body_text)}") from None
            except (urllib.error.URLError, TimeoutError, ValueError) as e:
                if attempt < 3:
                    time.sleep(delay * self.pace)
                    delay *= 2
                    continue
                raise ApiError(f"{method} {path.split('?')[0]}: {self.redact(e)}") from None
        raise ApiError(f"{method} {path}: gave up")

    def instances(self):
        rows, params = [], {"select_filters": {}, "order_by": [{"col": "id", "dir": "asc"}], "limit": 25}
        for _ in range(200):
            page = self.call("GET", "/api/v1/instances/", query=params)
            for row in page.get("instances") or []:
                env = row.get("extra_env") or []
                if isinstance(env, list):
                    row["extra_env"] = {e[0]: e[1] for e in env if isinstance(e, (list, tuple)) and len(e) == 2}
                rows.append(row)
            token = page.get("next_token")
            if not token:
                return rows
            params["after_token"] = token
        raise ApiError("instances: too many pages")

    def offers(self, cfg):
        q = {
            "verified": {"eq": True}, "external": {"eq": False}, "rentable": {"eq": True}, "rented": {"eq": False},
            "gpu_name": {"in": cfg["gpu_names"]}, "num_gpus": {"eq": 1},
            "reliability": {"gte": cfg["min_reliability"]},
            "order": [["dph_total", "asc"]], "type": "bid" if cfg["rental"] == "interruptible" else "on-demand",
            "allocated_storage": cfg["disk_gb"], "limit": 64,
        }
        if cfg["rental"] == "on-demand":
            q["dph_total"] = {"lte": cfg["max_dph"]}
        return self.call("POST", "/api/v0/bundles/", body=q).get("offers") or []

    def create(self, offer_id, payload):
        r = self.call("PUT", f"/api/v0/asks/{int(offer_id)}/", body=payload)
        if not r.get("success"):
            raise ApiError(f"rent: {self.redact(r.get('msg') or r.get('error') or 'refused')}")
        return r.get("new_contract")

    def relabel(self, inst_id, label):
        self.call("PUT", f"/api/v0/instances/{int(inst_id)}/", body={"label": label})

    def destroy(self, inst_id):
        self.call("DELETE", f"/api/v0/instances/{int(inst_id)}/", body={})


# ---------------------------------------------------------------------------------------------
# the plan

def utcnow():
    fake = os.environ.get("VAST_FLEET_NOW")   # tests: a fixed epoch
    return datetime.fromtimestamp(int(fake), timezone.utc) if fake else datetime.now(timezone.utc)


def parse_label(label):
    m = LABEL_RE.match(label or "")
    if not m:
        return None
    until = datetime.strptime(m.group(3), UNTIL_FMT).replace(tzinfo=timezone.utc) if m.group(3) else None
    return m.group(1), int(m.group(2)), until


def make_label(net, idx, until=None):
    return f"ycash-{net}-{idx}" + (f".until-{until.strftime(UNTIL_FMT)}" if until else "")


def health(inst, now, max_start_minutes):
    """'running', 'starting' or 'dead: <why>'."""
    actual = (inst.get("actual_status") or "").lower()
    intended = (inst.get("intended_status") or "").lower()
    if intended == "stopped":
        return f"dead: {actual or 'stopped'} (intended stopped)"
    if actual == "running":
        return "running"
    if actual in STARTING:
        started = inst.get("start_date")
        if isinstance(started, (int, float)) and (now.timestamp() - started) > max_start_minutes * 60:
            return f"dead: still {actual or 'starting'} after {max_start_minutes} min"
        return "starting"
    return f"dead: {actual}"


def offer_price(offer, cfg):
    """(price to pay per hour, bid or None) or None when over the cap."""
    if cfg["rental"] == "interruptible":
        floor = offer.get("min_bid", offer.get("dph_total"))
        if not isinstance(floor, (int, float)):
            return None
        bid = round(min(cfg["max_dph"], floor * 1.10 + 0.001), 4)
        return (bid, bid) if floor <= cfg["max_dph"] and bid >= floor else None
    p = offer.get("dph_total")
    return (p, None) if isinstance(p, (int, float)) and p <= cfg["max_dph"] else None


def offer_ok(offer, cfg):
    rel = offer.get("reliability2", offer.get("reliability"))
    return (offer.get("gpu_name") in cfg["gpu_names"] and offer.get("num_gpus", 1) == 1
            and isinstance(rel, (int, float)) and rel >= cfg["min_reliability"]
            and offer_price(offer, cfg) is not None)


class Fleet:
    def __init__(self, fleet, api, dry_run=False):
        self.fleet, self.api, self.dry = fleet, api, dry_run
        self.now = utcnow()
        self.errors = []
        self.used_offers = set()
        self.offer_cache = {}
        self.no_credit = False

    # -- reading
    def read(self):
        rows = self.api.instances()
        ours, foreign, odd = {}, 0, 0
        for r in rows:
            mask(r.get("id"))
            mask(r.get("public_ipaddr"))
            p = parse_label(r.get("label"))
            if p is None:
                if str(r.get("label") or "").startswith("ycash-"):
                    odd += 1
                foreign += 1
                continue
            net, idx, until = p
            r["_net"], r["_idx"], r["_until"] = net, idx, until
            r["_health"] = health(r, self.now, self.fleet["max_start_minutes"])
            ours.setdefault((net, idx), []).append(r)
        return ours, foreign, odd

    # -- acting (each says what it does; nothing happens in a dry run)
    def destroy(self, inst, why):
        say(f"  destroy {inst.get('label')} ({why})")
        if not self.dry:
            try:
                self.api.destroy(inst["id"])
            except ApiError as e:
                self.errors.append(f"destroy {inst.get('label')}: {e}")

    def relabel(self, inst, label):
        say(f"  relabel {inst.get('label')} -> {label}")
        if not self.dry:
            try:
                self.api.relabel(inst["id"], label)
            except ApiError as e:
                self.errors.append(f"relabel {inst.get('label')}: {e}")

    def create(self, net, idx, until=None):
        cfg = self.fleet["networks"][net]
        label = make_label(net, idx, until)
        why = startable(cfg)
        if why:
            self.errors.append(f"{label}: not started: {why}")
            say(f"  REFUSED {label}: {why}")
            return
        if self.no_credit:
            self.errors.append(f"{label}: not started: the account has no credit")
            return
        if net not in self.offer_cache:
            try:
                self.offer_cache[net] = sorted((o for o in self.api.offers(cfg) if offer_ok(o, cfg)),
                                               key=lambda o: offer_price(o, cfg)[0])
            except ApiError as e:
                self.errors.append(f"{label}: offer search: {e}")
                return
        env = {"POOL_URL": cfg["pools"][idx % len(cfg["pools"])], "WORKER": f"{cfg['worker_prefix']}-{idx}"}
        if cfg["payout"]:
            env["PAYOUT"] = cfg["payout"]
        if cfg["extra_args"]:
            env["MINER_ARGS"] = " ".join(cfg["extra_args"])
        tries = 0
        for offer in self.offer_cache[net]:
            if offer.get("id") in self.used_offers:
                continue
            if tries >= 3:
                break
            tries += 1
            self.used_offers.add(offer.get("id"))
            price, bid = offer_price(offer, cfg)
            pool_no = idx % len(cfg["pools"]) + 1
            say(f"  start {label}: {offer.get('gpu_name')} at ${price:.4f}/h ({cfg['rental']}), "
                f"pool {pool_no} of {len(cfg['pools'])}, worker {env['WORKER']}")
            if self.dry:
                return
            payload = {"client_id": "me", "image": cfg["image"], "env": env, "disk": cfg["disk_gb"],
                       "label": label, "runtype": "args", "cancel_unavail": True, "price": bid}
            try:
                new_id = self.api.create(offer["id"], payload)
            except ApiError as e:
                msg = str(e)
                if re.search(r"credit|balance|insufficient", msg, re.I):
                    self.no_credit = True
                    self.errors.append(f"{label}: not started: {msg}")
                    return
                say(f"  offer taken or refused ({msg}); trying the next")
                continue
            mask(new_id)
            if new_id is None:
                self.errors.append(f"{label}: rented, but Vast returned no instance id: check the console")
                return
            # the label is what makes it ours: set it again explicitly, so a create that dropped it
            # cannot leave an unlabelled (unmanaged) miner running
            try:
                self.api.relabel(new_id, label)
            except ApiError as e:
                self.errors.append(f"{label}: rented, but labelling it failed ({e}): label or destroy it in the console")
            time.sleep(self.api.pace)
            return
        self.errors.append(f"{label}: no offer for {', '.join(cfg['gpu_names'])} at or under "
                           f"${cfg['max_dph']:.3f}/h ({cfg['rental']}, reliability >= {cfg['min_reliability']})")
        say(f"  NO OFFER for {label} under ${cfg['max_dph']:.3f}/h")

    # -- the reconcile
    def reconcile(self, only=None, burst=None):
        """burst = (net, n, until): run n miners on net, slots >= count labelled to expire at until."""
        ours, foreign, odd = self.read()
        nets = self.fleet["networks"]
        say(f"{len(ours)} slot(s) of ours, {foreign} other instance(s) on the account (never touched)"
            + (f", {odd} with a ycash- label we do not recognise (never touched)" if odd else ""))
        for (net, idx), insts in sorted(ours.items()):
            if only and net != only:
                continue
            if net not in nets:
                for i in insts:
                    self.destroy(i, f"network {net} is not in the fleet")
                continue
            count = nets[net]["count"]
            until = max((i["_until"] for i in insts if i["_until"]), default=None)
            if burst and burst[0] == net and idx >= count:
                if idx < burst[1]:
                    until = burst[2]
                else:
                    for i in insts:
                        self.destroy(i, f"above the burst of {burst[1]}")
                    continue
            wanted = idx < count or (until is not None and until > self.now)
            if not wanted:
                why = "burst over" if until is not None else f"above the fleet's {count}"
                for i in insts:
                    self.destroy(i, why)
                continue
            alive = sorted((i for i in insts if not i["_health"].startswith("dead")),
                           key=lambda i: (i["_health"] != "running", i.get("start_date") or 0))
            for i in insts:
                if i["_health"].startswith("dead"):
                    self.destroy(i, i["_health"][6:])
            for i in alive[1:]:
                self.destroy(i, "a second instance in the same slot")
            if not alive:
                self.create(net, idx, until if idx >= count else None)
                continue
            want_label = make_label(net, idx, until if idx >= count else None)
            if alive[0].get("label") != want_label:
                self.relabel(alive[0], want_label)
        for net, cfg in sorted(nets.items()):
            if only and net != only:
                continue
            n = cfg["count"]
            if burst and burst[0] == net:
                n = max(n, burst[1])
            for idx in range(n):
                if (net, idx) not in ours:
                    until = burst[2] if burst and burst[0] == net and idx >= cfg["count"] else None
                    self.create(net, idx, until)

    def down(self, only=None):
        ours, foreign, _ = self.read()
        say(f"down: {sum(len(v) for (n, _), v in ours.items() if not only or n == only)} of ours"
            + (f" on {only}" if only else "") + f"; {foreign} other instance(s) left alone")
        for (net, _idx), insts in sorted(ours.items()):
            if only and net != only:
                continue
            for i in insts:
                self.destroy(i, "down")

    def expire(self):
        ours, _, _ = self.read()
        left = 0
        for (_net, _idx), insts in sorted(ours.items()):
            for i in insts:
                if i["_until"] is None:
                    continue
                if i["_until"] <= self.now:
                    self.destroy(i, "burst over")
                else:
                    left += 1
        output("burst_active", left)

    def status(self):
        ours, foreign, odd = self.read()
        nets = self.fleet["networks"]
        lines = ["| miner | state | card | $/h | pool | until |", "|---|---|---|---|---|---|"]
        total, bursts = 0.0, 0
        for (net, idx), insts in sorted(ours.items()):
            cfg = nets.get(net)
            for i in insts:
                price = i.get("dph_total")
                total += price if isinstance(price, (int, float)) else 0
                bursts += 1 if i["_until"] else 0
                pool = f"{idx % len(cfg['pools']) + 1}/{len(cfg['pools'])}" if cfg else "-"
                lines.append(f"| {i.get('label')} | {i['_health']} | {i.get('gpu_name') or '?'} | "
                             f"{price if price is not None else '?'} | {pool} | "
                             f"{i['_until'].strftime(UNTIL_FMT) if i['_until'] else '-'} |")
        for net, cfg in sorted(nets.items()):
            have = sum(1 for (n, _) in ours if n == net)
            note = startable(cfg) if cfg["count"] else None
            lines.append(f"\n{net}: {have} running or starting slot(s), fleet count {cfg['count']}"
                         + (f"; cannot start: {note}" if note else ""))
        lines.append(f"\nours: about ${total:.3f}/h (≈ ${total * 730:.0f} a month); "
                     f"{foreign} other instance(s) on the account, never touched"
                     + (f" ({odd} with an unrecognised ycash- label)" if odd else ""))
        for line in lines:
            say(line)
        summary(["## miners: status", ""] + lines)
        output("ours", sum(len(v) for v in ours.values()))
        output("burst_active", bursts)


# ---------------------------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description="Keep a Vast.ai miner fleet at the size a fleet file asks for.")
    ap.add_argument("--fleet", required=True, help="the fleet file (JSON, format ycash-vast-fleet/1)")
    ap.add_argument("--dry-run", action="store_true", help="print what would change; change nothing")
    sub = ap.add_subparsers(dest="action", required=True)
    sub.add_parser("validate")
    sub.add_parser("total")
    sub.add_parser("status")
    p = sub.add_parser("reconcile")
    p.add_argument("--network")
    p = sub.add_parser("down")
    p.add_argument("--network")
    p = sub.add_parser("burst")
    p.add_argument("network")
    p.add_argument("count", type=int)
    p.add_argument("--hours", type=int, required=True)
    sub.add_parser("expire")
    a = ap.parse_args(argv)

    key = os.environ.get("VAST_API_KEY", "")
    if key:
        mask(key)
    try:
        fleet = load_fleet(a.fleet)
        nets = fleet["networks"]
        if a.action == "validate":
            for net, cfg in sorted(nets.items()):
                note = startable(cfg)
                say(f"{net}: count {cfg['count']}, {', '.join(cfg['gpu_names'])}, at most ${cfg['max_dph']:.3f}/h "
                    f"{cfg['rental']}, {len(cfg['pools'])} pool(s)" + (f"; cannot start yet: {note}" if note else ""))
            say(f"fleet file OK: {fleet['total']} miner(s)")
            return 0
        if a.action == "total":
            print(fleet["total"])
            return 0
        for attr in ("network",):
            net = getattr(a, attr, None)
            if net is not None and net not in nets and a.action != "down":
                raise FleetError(f"network {net!r} is not in the fleet file ({', '.join(sorted(nets))})")
        if a.action == "down" and a.network is not None and not NET_RE.match(a.network):
            raise FleetError("down --network: a network name")
        burst = None
        if a.action == "burst":
            if not 1 <= a.count <= MAX_PER_NET:
                raise FleetError(f"burst: 1 to {MAX_PER_NET} miners")
            if not 1 <= a.hours <= MAX_BURST_HOURS:
                raise FleetError(f"burst: 1 to {MAX_BURST_HOURS} hours")
            extra = max(0, a.count - nets[a.network]["count"])
            if fleet["total"] + extra > MAX_TOTAL:
                raise FleetError(f"burst: the fleet would exceed {MAX_TOTAL} miners")
            until = (utcnow() + timedelta(hours=a.hours)).replace(second=0, microsecond=0)
            burst = (a.network, a.count, until)
        api = Vast(key, os.environ.get("VAST_URL"))
        f = Fleet(fleet, api, dry_run=a.dry_run)
        if a.dry_run:
            say("dry run: nothing is rented, relabelled or destroyed")
        if a.action == "status":
            f.status()
        elif a.action == "reconcile":
            f.reconcile(only=a.network)
        elif a.action == "burst":
            say(f"burst: {a.count} miner(s) on {a.network} until {burst[2].strftime(UNTIL_FMT)}")
            f.reconcile(only=a.network, burst=burst)
        elif a.action == "down":
            f.down(only=a.network)
        elif a.action == "expire":
            f.expire()
        if f.errors:
            for e in f.errors:
                say(f"::error::{e}" if in_actions() else f"error: {e}")
            summary(["", "### errors", ""] + [f"- {e}" for e in f.errors])
            return 1
        return 0
    except (FleetError, ApiError) as e:
        msg = str(e).replace(key, "<key>") if key else str(e)
        say(f"::error::{msg}" if in_actions() else f"vast-fleet: {msg}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
