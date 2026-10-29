#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""The testnet probe: one network's nodes and seeds, as Prometheus metrics and a public summary.

Every INTERVAL seconds it asks each node in NODES over JSON-RPC (getblockchaininfo, getblockheader,
getconnectioncount, getchaintips, getnetworkinfo, vault_getinfo, yed_getstatehash), compares the
nodes with each other (the block hash at their common height; vault_getinfo.statehash and
yed_getstatehash between nodes whose state is at the same block: the testnet plan §6.4 cross-line
check, ycash6 against ycash-dd), opens a P2P connection to every seed in SEEDS and checks that it
answers with this network's magic, and reads the latest state bundle's manifest (BUNDLE_MANIFEST_URL).

  GET /metrics       Prometheus text (cluster-internal: it names the nodes)
  GET /status.json   the public summary the status page shows (no node names, no addresses)
  GET /healthz       200 once the first round finished

Environment: NODES (JSON: [{"name", "url", "line"}]), RPC_USER, RPC_PASSWORD, SEEDS ("host:port ..."),
MAGIC (hex, 4 bytes), NETWORK_NAME, PROFILE, BUNDLE_MANIFEST_URL, INTERVAL (s, default 30), PORT (9100).
Python's standard library only.
"""
import base64
import calendar
import hashlib
import http.server
import json
import os
import random
import socket
import struct
import threading
import time
import urllib.error
import urllib.request

NODES = json.loads(os.environ.get("NODES", "[]"))
RPC_USER = os.environ.get("RPC_USER", "")
RPC_PASSWORD = os.environ.get("RPC_PASSWORD", "")
SEEDS = os.environ.get("SEEDS", "").split()
MAGIC = bytes.fromhex(os.environ.get("MAGIC", "f77962d3"))
NETWORK_NAME = os.environ.get("NETWORK_NAME", "testnet")
PROFILE = os.environ.get("PROFILE", "")
BUNDLE_MANIFEST_URL = os.environ.get("BUNDLE_MANIFEST_URL", "")
INTERVAL = float(os.environ.get("INTERVAL", "30"))
PORT = int(os.environ.get("PORT", "9100"))
FORK_WINDOW = int(os.environ.get("FORK_WINDOW", "10"))   # a side branch counts while its tip is this close to ours
DEFAULT_PROTOCOL = 270013        # ycash6 src/version.h PROTOCOL_VERSION; a node's own value is used once known

_auth = base64.b64encode(f"{RPC_USER}:{RPC_PASSWORD}".encode()).decode()
_state = {"metrics": "", "status": None, "rounds": 0}
_bundle = {"checked": 0.0, "manifest": None, "ok": 0}


class RpcError(RuntimeError):
    pass


def rpc(url, method, *params, timeout=15):
    body = json.dumps({"jsonrpc": "1.0", "id": "probe", "method": method, "params": list(params)}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "text/plain", "Authorization": "Basic " + _auth})
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


def optional(url, method, *params):
    """An RPC that a node may not have (yed_* before an attestor set; vault_* on an old build): None."""
    try:
        return rpc(url, method, *params)
    except RpcError:
        return None


def node_round(n):
    url = n["url"]
    r = {"name": n["name"], "line": n.get("line", ""), "up": 0}
    try:
        bci = rpc(url, "getblockchaininfo")
        best = bci["bestblockhash"]
        r.update(height=int(bci["blocks"]), headers=int(bci.get("headers", bci["blocks"])), best=best,
                 chain=bci.get("chain"), profile=bci.get("testnetprofile", ""))
        r["tip_time"] = int(rpc(url, "getblockheader", best)["time"])
        r["peers"] = int(rpc(url, "getconnectioncount"))
        tips = rpc(url, "getchaintips")
        # side branches near the tip only: an old one stays in getchaintips for good
        r["fork"] = max([int(t.get("branchlen", 0)) for t in tips
                         if t.get("status") in ("valid-fork", "valid-headers") and int(t.get("height", 0)) >= r["height"] - FORK_WINDOW] or [0])
        net = rpc(url, "getnetworkinfo")
        r["subversion"] = net.get("subversion", "")
        r["protocol"] = int(net.get("protocolversion", DEFAULT_PROTOCOL))
        r["up"] = 1
        v = optional(url, "vault_getinfo")
        if v is not None:
            r["vault"] = {"activation": int(v.get("activationheight", -1)), "active": bool(v.get("active")),
                          "set": v.get("attestorsetid"), "statehash": v.get("statehash"),
                          "at": (v.get("dbtip") or {}).get("hash")}
        y = optional(url, "yed_getstatehash")
        if y is not None:
            r["yed"] = {"statehash": y.get("statehash"), "at": y.get("blockhash")}
    except Exception as e:  # noqa: BLE001
        r["error"] = str(e)[:200]
    return r


def agreement(nodes):
    """(tips_agree, vault_agree, yed_agree, compared): the block hash at the nodes' common height, and each
    state hash between the nodes whose state is at the same block. None = nothing to compare."""
    up = [n for n in nodes if n["up"]]
    tips = None
    if len(up) >= 2:
        h = min(n["height"] for n in up)
        hashes = set()
        for n in up:
            try:
                hashes.add(rpc(n["url"], "getblockhash", h))
            except Exception:  # noqa: BLE001
                pass
        tips = len(hashes) <= 1
    out = [tips]
    for kind in ("vault", "yed"):
        groups = {}
        for n in up:
            s = n.get(kind)
            if s and s.get("statehash") and s.get("at"):
                groups.setdefault(s["at"], []).append(s["statehash"])
        compared = [g for g in groups.values() if len(g) >= 2]
        out.append(None if not compared else all(len(set(g)) == 1 for g in compared))
    return tuple(out)


def p2p_message(command, payload):
    return MAGIC + command.encode().ljust(12, b"\0") + struct.pack("<I", len(payload)) + \
        hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4] + payload


def version_payload(protocol):
    addr = struct.pack("<Q", 0) + b"\0" * 10 + b"\xff\xff" + b"\0" * 4 + struct.pack(">H", 0)
    ua = b"/ycash-testnet-probe:1/"
    return struct.pack("<iQq", protocol, 0, int(time.time())) + addr + addr + \
        struct.pack("<Q", random.getrandbits(64)) + bytes([len(ua)]) + ua + struct.pack("<i", 0) + b"\0"


def seed_check(hostport, protocol=DEFAULT_PROTOCOL, timeout=10):
    """(up, seconds): up when the peer answers our version message with a message in this network's magic
    (its version, or a reject: either proves the network). A peer of another network drops the connection."""
    host, _, port = hostport.rpartition(":")
    t0 = time.time()
    try:
        with socket.create_connection((host.strip("[]"), int(port)), timeout=timeout) as s:
            s.settimeout(timeout)
            s.sendall(p2p_message("version", version_payload(protocol)))
            hdr = b""
            while len(hdr) < 24:
                chunk = s.recv(24 - len(hdr))
                if not chunk:
                    return 0, time.time() - t0
                hdr += chunk
            return (1 if hdr[:4] == MAGIC else 0), time.time() - t0
    except OSError:
        return 0, time.time() - t0


def bundle_round(now):
    if not BUNDLE_MANIFEST_URL or now - _bundle["checked"] < 600:
        return
    _bundle["checked"] = now
    try:
        with urllib.request.urlopen(BUNDLE_MANIFEST_URL, timeout=20) as r:
            _bundle["manifest"] = json.load(r)
        _bundle["ok"] = 1
    except Exception as e:  # noqa: BLE001
        _bundle["ok"] = 0
        print(f"probe: bundle manifest: {e}", flush=True)


def iso_seconds(s):
    try:
        return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return None


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def render(nodes, agree, seeds, now):
    L = []

    def g(name, help_, rows):
        L.append(f"# HELP {name} {help_}")
        L.append(f"# TYPE {name} gauge")
        for labels, value in rows:
            lab = ",".join(f'{k}="{esc(v)}"' for k, v in labels.items())
            L.append(f"{name}{{{lab}}} {value}" if lab else f"{name} {value}")

    net = {"network": NETWORK_NAME}
    nl = lambda n: {**net, "node": n["name"], "line": n["line"]}  # noqa: E731
    g("ycash_node_up", "1 when the node answered RPC this round", [(nl(n), n["up"]) for n in nodes])
    up = [n for n in nodes if n["up"]]
    g("ycash_node_height", "the node's active chain height", [(nl(n), n["height"]) for n in up])
    g("ycash_node_headers", "the best header height the node knows", [(nl(n), n["headers"]) for n in up])
    g("ycash_node_tip_timestamp_seconds", "the block time of the node's tip", [(nl(n), n["tip_time"]) for n in up])
    g("ycash_node_peers", "the node's P2P connections", [(nl(n), n["peers"]) for n in up])
    g("ycash_node_fork_length", "the longest valid side branch getchaintips reports", [(nl(n), n["fork"]) for n in up])
    g("ycash_node_info", "the node's version string", [({**nl(n), "subversion": n["subversion"], "profile": n["profile"]}, 1) for n in up])
    vrows = [n for n in up if "vault" in n]
    g("ycash_vault_activation_height", "UPGRADE_VAULT's height (-1 unscheduled)", [(nl(n), n["vault"]["activation"]) for n in vrows])
    g("ycash_vault_active", "1 when Vault rules apply to the next block", [(nl(n), int(n["vault"]["active"])) for n in vrows])
    g("ycash_vault_attestor_set_info", "the attestor set YED governs on the node", [({**nl(n), "set": n["vault"]["set"] or ""}, 1) for n in vrows])
    tips, vault_ok, yed_ok = agree
    g("ycash_nodes_compared", "nodes that answered and were compared", [(net, len(up))])
    if tips is not None:
        g("ycash_nodes_tip_agree", "1 when every node has the same block at their common height", [(net, int(tips))])
    rows = [({**net, "kind": k}, int(ok)) for k, ok in (("vault", vault_ok), ("yed", yed_ok)) if ok is not None]
    if rows:
        g("ycash_statehash_agree", "1 when nodes whose state is at the same block report the same state hash", rows)
    g("ycash_seed_up", "1 when the seed answered a P2P version message in this network's magic",
      [({**net, "seed": s}, up_) for s, up_, _ in seeds])
    g("ycash_seed_handshake_seconds", "the time to that answer", [({**net, "seed": s}, f"{t:.3f}") for s, _, t in seeds])
    if BUNDLE_MANIFEST_URL:
        g("ycash_bundle_manifest_ok", "1 when the latest bundle manifest was read", [(net, _bundle["ok"])])
        m = _bundle["manifest"] or {}
        if "height" in m:
            g("ycash_bundle_height", "the latest state bundle's height", [(net, int(m["height"]))])
        created = iso_seconds(m.get("created"))
        if created:
            g("ycash_bundle_created_timestamp_seconds", "the latest state bundle's creation time", [(net, created)])
    g("ycash_probe_last_round_timestamp_seconds", "when this probe last finished a round", [(net, int(now))])
    return "\n".join(L) + "\n"


def summary(nodes, agree, seeds, now):
    """The public summary: numbers only, no node names, addresses or errors."""
    up = [n for n in nodes if n["up"]]
    best = max(up, key=lambda n: n["height"], default=None)
    lead = next((n for n in up if n["line"] == "ycash6"), best)
    vault = (lead or {}).get("vault") or {}
    m = _bundle["manifest"] or {}
    return {
        "network": NETWORK_NAME, "profile": PROFILE, "updated": int(now),
        "height": best["height"] if best else None, "tipTime": best["tip_time"] if best else None,
        "peers": max((n["peers"] for n in up), default=None),
        "nodes": {"up": len(up), "total": len(nodes)},
        "agree": agree[0], "stateAgree": None if agree[1] is None and agree[2] is None else all(a is not False for a in agree[1:]),
        "vault": {"activationHeight": vault.get("activation"), "active": vault.get("active")},
        "attestorSet": vault.get("set"),
        "version": (lead or {}).get("subversion"),
        "seeds": {"up": sum(u for _, u, _ in seeds), "total": len(seeds)},
        "bundle": {k: m.get(k) for k in ("height", "blockhash", "version", "created", "tarball", "sha256", "bytes")} if m else None,
    }


def one_round():
    now = time.time()
    nodes = [node_round(n) for n in NODES]
    for n, cfg in zip(nodes, NODES):
        n["url"] = cfg["url"]
    agree = agreement(nodes)
    protocol = max([n.get("protocol", 0) for n in nodes] + [DEFAULT_PROTOCOL])
    seeds = [(s, *seed_check(s, protocol)) for s in SEEDS]
    bundle_round(now)
    _state["metrics"] = render(nodes, agree, seeds, now)
    _state["status"] = summary(nodes, agree, seeds, now)
    _state["rounds"] += 1


def loop():
    while True:
        try:
            one_round()
        except Exception as e:  # noqa: BLE001
            print(f"probe: round failed: {e}", flush=True)
        time.sleep(INTERVAL)


class H(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        body = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/metrics":
            return self._send(200, _state["metrics"], "text/plain; version=0.0.4")
        if path == "/status.json":
            if _state["status"] is None:
                return self._send(503, "{}", "application/json")
            return self._send(200, json.dumps(_state["status"], sort_keys=True), "application/json")
        if path == "/healthz":
            return self._send(200 if _state["rounds"] else 503, "ok\n", "text/plain")
        return self._send(404, "not found\n", "text/plain")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    threading.Thread(target=loop, daemon=True).start()
    print(f"probe: {len(NODES)} node(s), {len(SEEDS)} seed(s), {NETWORK_NAME}, every {INTERVAL:g} s on :{PORT}", flush=True)
    http.server.ThreadingHTTPServer(("", PORT), H).serve_forever()
