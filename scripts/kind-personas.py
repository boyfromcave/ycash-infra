#!/usr/bin/env python3
"""The Yellowback personas, host-run, against the kind cluster's one regtest node (plan K0c).

  kind-personas.py up [--price USD] [--attestors N] [--blocks N] [--no-walk]
  kind-personas.py down | status

What the devnet's `up` does for eight nodes, done for the one node the chart runs, with the devnet's
own tooling from the workspace (ycash6/contrib/yellowback: the Rust `yellowback-attest` and the
Python `yellowback-quote`) talking to the node over its host port (kind/kind.yaml: 18832):

  1. the pool: the node is the quoting pool. The arming Job records a payout address of its wallet
     in ConfigMap <release>-yellowback-set; the chart renders -yellowbackpayoutaddress from it, so
     an older cluster needs one `helm upgrade` (done here, announced; retried while another operation
     holds the release). The chart's miner `generate`s on that node, so every block carries its tag.
  2. one `yellowback-quote --mock-price` beside it (yed_setquote every 5 s), then ACTIVATION_BLOCKS
     tagged blocks mined through `generate` so the price windows fill (NO_PRICE lifts).
  3. N `yed_registerattestor 10 200` from the node's wallet (a SET_JOIN each; one block + a settle
     between them), BOND_MATURITY blocks -> TRIGGERED, ATTEST_ARM_DELAY more -> ARMED.
  4. one `yellowback-attest attest --mock-price` per seq (the node signs with that seq's key) and one
     `subscribe` beside the same node, on the `dir` transport; blocks into an attestation tick;
     poolFresh >= M_SELECT.
  5. the price walk: every tick the quote's and every attestor's mock price moves a little around
     the base (a constant quote beside moving attestations is pinned, PIN-1), as the devnet's walk.

The heartbeat is the chart's miner (one block every few seconds); nothing here mines after `up`.
`down` stops the agents and leaves the chain as it is (ARMED; the attestations go stale after
ATTEST_MAX_AGE blocks and minting halts until `up` again, which is then a few seconds). State, logs,
configs and the bus live under $YCASH_PERSONAS_DIR (default ~/.local/state/ycash-infra/personas).
The workspace venv is the interpreter (the quote agent needs Python >= 3.11); only the stdlib is used.
"""
import argparse
import base64
import json
import os
import random
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
WORKSPACE = os.environ.get("WORKSPACE") or os.path.abspath(os.path.join(HERE, "..", "..", ".."))
YCASH6 = os.environ.get("YCASH6") or os.path.join(WORKSPACE, "ycash6")
QUOTE_AGENT = os.path.join(YCASH6, "contrib", "yellowback", "yellowback-quote")
ATTEST_CRATE = os.path.join(YCASH6, "contrib", "yellowback", "attest")
ATTEST_AGENT = os.environ.get("YELLOWBACK_ATTEST_BIN") or os.path.join(ATTEST_CRATE, "target", "release", "yellowback-attest")
STATE_DIR = os.environ.get("YCASH_PERSONAS_DIR") or os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "ycash-infra", "personas")
RPC_URL = os.environ.get("YCASH_RPC_URL", "http://127.0.0.1:18832/")
RPC_USER = os.environ.get("YCASH_RPC_USER", "ycash")
RPC_PASSWORD = os.environ.get("YCASH_RPC_PASSWORD", "ycash-regtest")
NS = os.environ.get("NAMESPACE", "ycash")
RELEASE = os.environ.get("RELEASE", "ycash")
CONTEXT = os.environ.get("CONTEXT", "kind-ycash")
CHART = os.path.join(HERE, "..", "charts", "ycash-lightwallet")

# The regtest constants (ycash6 qa/rpc-tests/test_framework/yellowback_util.py; the devnet's).
ATTEST_BOND_YEC, ATTEST_LOCK_BLOCKS = 10, 200
BOND_MATURITY, ATTEST_ARM_MIN, ATTEST_ARM_DELAY = 8, 3, 8
ATTEST_INTERVAL, ATTEST_HEARTBEAT_BLOCKS, REF_LAG, M_SELECT = 4, 100, 2, 2
ACTIVATION_BLOCKS = 64 + 6           # P_SLOW_WINDOW + 6: the three price windows fill
WALK_TICK, WALK_VOL_PCT, WALK_BAND_PCT = 5, 1.0, 10.0

QUOTE_CONF = """# written by kind-personas.py: the pool quote agent beside the kind node
[node]
rpc_url = "%(url)s"
rpc_user = "%(user)s"
rpc_password = "%(password)s"

[quote]
poll_seconds = 5
fail_polls = 2
min_sources = 1
min_venues = 1

[[sources]]
name = "nowhere"
kind = "generic"
venue = "nowhere"
url = "http://127.0.0.1:1/never"
path = "price"
"""
ATTEST_CONF = """# written by kind-personas.py: attestor seq %(seq)d, signed by the kind node's wallet
[node]
rpc_url = "%(url)s"
rpc_user = "%(user)s"
rpc_password = "%(password)s"

[attest]
seq = %(seq)d
every_blocks = %(every)d
heartbeat_blocks = %(heartbeat)d
fail_polls = 2
ref_lag = %(ref_lag)d
poll_seconds = 2
min_sources = 1
min_venues = 1

[transport]
kind = "dir"
path = "%(bus)s"

[subscribe]
listattestors_seconds = 5
"""
SUBSCRIBE_CONF = """# written by kind-personas.py: the subscriber beside the kind node (the minting node)
[node]
rpc_url = "%(url)s"
rpc_user = "%(user)s"
rpc_password = "%(password)s"

[transport]
kind = "dir"
path = "%(bus)s"

[subscribe]
listattestors_seconds = 5
"""


# ------------------------------------------------------------------------------------ rpc, state

class RpcError(Exception):
    pass


def rpc(method, *params, timeout=120):
    body = json.dumps({"jsonrpc": "1.0", "id": "personas", "method": method, "params": list(params)}).encode()
    auth = base64.b64encode(("%s:%s" % (RPC_USER, RPC_PASSWORD)).encode()).decode()
    req = urllib.request.Request(RPC_URL, data=body, headers={"content-type": "text/plain", "authorization": "Basic " + auth})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            reply = json.load(resp)
    except urllib.error.HTTPError as error:
        try:
            reply = json.load(error)
        except Exception:
            raise RpcError("%s: HTTP %d" % (method, error.code))
    if reply.get("error"):
        raise RpcError("%s: %s" % (method, reply["error"].get("message", reply["error"])))
    return reply["result"]


def state_path():
    return os.path.join(STATE_DIR, "personas.json")


def load_state():
    try:
        with open(state_path()) as file:
            return json.load(file)
    except OSError:
        return {}


def save_state(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = state_path() + ".tmp"
    with open(tmp, "w") as file:
        json.dump(state, file, indent=1, sort_keys=True)
    os.replace(tmp, state_path())


def write_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as file:
        file.write(text)
    os.chmod(path, 0o600)


def write_price(path, usd):
    tmp = path + ".tmp"
    with open(tmp, "w") as file:
        file.write("%.6f\n" % usd)
    os.replace(tmp, path)


def alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def spawn(name, argv):
    log = open(os.path.join(STATE_DIR, name + ".log"), "ab")
    proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True, cwd=STATE_DIR)
    print("    %s: pid %d (%s/%s.log)" % (name, proc.pid, STATE_DIR, name))
    return proc.pid


def kill(name, pid):
    if alive(pid):
        try:
            os.kill(pid, signal.SIGTERM)
            print("  stopped %s (pid %d)" % (name, pid))
        except OSError as error:
            print("  %s: %s" % (name, error))


def sh(*argv, check=True, capture=True):
    return subprocess.run(list(argv), check=check, capture_output=capture, text=True)


def kubectl(*argv, **kw):
    return sh("kubectl", "--context", CONTEXT, "-n", NS, *argv, **kw)


# ------------------------------------------------------------------------------------ the chain

def generate(n, label=None):
    """Mine n blocks on the node (tagged: the node is the pool). The chart's miner mines beside this."""
    for _ in range(n):
        rpc("generate", 1)
    if label:
        print("    %s -> height %d" % (label, rpc("getblockcount")))


def settle(seconds=2.0):
    """generate returns before the wallet has digested the block (the devnet's _settle): a wallet RPC
    issued at once builds on a stale view and the mempool refuses it."""
    time.sleep(seconds)
    rpc("getbalance")


def wait_until(what, pred, timeout, every=1.0):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = pred()
        if last:
            return last
        time.sleep(every)
    raise SystemExit("timed out after %ds waiting for %s (last: %r)" % (timeout, what, last))


def ensure_payout():
    """The node must be the pool: -yellowbackpayoutaddress on its command line, rendered by the chart
    from the set ConfigMap's payoutaddress (written by the arming Job r2+). An older cluster: write it
    and run the one helm upgrade that restarts the node with it."""
    info = rpc("yed_getinfo")
    if info["miner"]["payoutAddress"]:
        print("  pool: the node pays out to %s" % info["miner"]["payoutAddress"])
        return
    cm = RELEASE + "-yellowback-set"
    payout = kubectl("get", "configmap", cm, "-o", "jsonpath={.data.payoutaddress}", check=False).stdout.strip()
    if not payout:
        payout = rpc("getnewaddress")
        kubectl("patch", "configmap", cm, "--type", "merge", "-p", json.dumps({"data": {"payoutaddress": payout}}))
        print("  pool: recorded payout address %s in ConfigMap %s" % (payout, cm))
    print("  pool: helm upgrade so the node restarts with -yellowbackpayoutaddress=%s (announced; retried while the release is locked)" % payout)
    values = os.path.join(CHART, "values-kind.yaml")
    for attempt in range(40):
        run = sh("helm", "upgrade", "--install", RELEASE, CHART, "--kube-context", CONTEXT, "-n", NS, "-f", values, "--wait", "--timeout", "15m", check=False)
        if run.returncode == 0:
            break
        if "another operation" in run.stderr or "in progress" in run.stderr:
            print("    helm: another operation is in progress; retrying in 15 s (%d)" % (attempt + 1))
            time.sleep(15)
            continue
        raise SystemExit("helm upgrade failed:\n%s" % run.stderr)
    else:
        raise SystemExit("helm release stayed locked for ten minutes")
    kubectl("rollout", "status", "statefulset/" + RELEASE + "-ycashd", "--timeout=15m", capture=False)
    wait_until("yed_getinfo after the restart", lambda: _try(lambda: rpc("yed_getinfo")["miner"]["payoutAddress"]), 300, 3)
    print("  pool: the node pays out to %s" % rpc("yed_getinfo")["miner"]["payoutAddress"])


def _try(f):
    try:
        return f()
    except Exception:
        return None


def start_quote(state, price):
    conf = os.path.join(STATE_DIR, "quote.toml")
    write_private(conf, QUOTE_CONF % {"url": RPC_URL, "user": RPC_USER, "password": RPC_PASSWORD})
    mock = os.path.join(STATE_DIR, "price-quote")
    write_price(mock, price)
    if not alive(state["agents"].get("quote")):
        state["agents"]["quote"] = spawn("quote", [sys.executable, QUOTE_AGENT, "--conf", conf, "--mock-price", mock])
        save_state(state)
    wait_until("the pool's quote (yed_getinfo miner.quoteKind)", lambda: rpc("yed_getinfo")["miner"]["quoteKind"] == "quote", 60)
    print("  quote: the node holds a $%.2f quote; its blocks carry the tag" % price)


def fill_windows():
    """Mine until the mint price is defined: ACTIVATION_BLOCKS tagged blocks at most."""
    def price_defined():
        return rpc("yed_getprice").get("pMint") not in (None, 0) and "NO_PRICE" not in rpc("yed_getstats")["haltMask"]
    start = rpc("getblockcount")
    for i in range(ACTIVATION_BLOCKS):
        if i % 10 == 0 and price_defined():
            break
        generate(1)
    print("    windows: %d tagged blocks -> height %d, pMint %s" % (rpc("getblockcount") - start, rpc("getblockcount"), rpc("yed_getprice").get("pMint")))


def register_attestors(n):
    """N registrations from the node's wallet (idempotent: existing registrations count), then ARMED."""
    have = rpc("yed_listattestors")
    todo = max(0, n - len(have))
    if todo:
        print("  attestors: registering %d (%d YEC bonded for %d blocks each; %d already registered)" % (todo, ATTEST_BOND_YEC, ATTEST_LOCK_BLOCKS, len(have)))
    for i in range(todo):
        for attempt in range(5):
            try:
                result = rpc("yed_registerattestor", ATTEST_BOND_YEC, ATTEST_LOCK_BLOCKS)
                break
            except RpcError as error:
                if attempt == 4 or "rejected by the mempool" not in str(error):
                    raise
                time.sleep(2)
        print("    registered: txid %s, bond %s" % (result["txid"][:16], result["bondAddress"]))
        generate(1)
        settle()
    info = rpc("yed_getinfo")["attest"]
    if info["status"] == "ARMED":
        print("  attestors: ARMED, %d seated" % info["seatedCount"])
        return
    generate(BOND_MATURITY, "bonds matured (BOND_MATURITY=%d)" % BOND_MATURITY)
    info = wait_until("TRIGGERED", lambda: _status_at_least("TRIGGERED"), 60)
    print("    %s at height %d; arms at %d" % (info["status"], info["triggerHeight"], info["armHeight"]))
    while rpc("getblockcount") < info["armHeight"] + 1:
        generate(1)
    info = wait_until("ARMED", lambda: _status_at_least("ARMED"), 60)
    print("  attestors: ARMED at height %d, %d seated" % (rpc("getblockcount"), info["seatedCount"]))


def _status_at_least(want):
    order = ["UNARMED", "TRIGGERED", "ARMED"]
    info = rpc("yed_getinfo")["attest"]
    return info if order.index(info["status"]) >= order.index(want) else None


def start_attest_agents(state, price):
    bus = os.path.join(STATE_DIR, "bus")
    os.makedirs(bus, exist_ok=True)
    seqs = sorted(int(rec["seq"]) for rec in rpc("yed_listattestors") if rec.get("seq") is not None)
    state["seqs"] = seqs
    for seq in seqs:
        conf = os.path.join(STATE_DIR, "attest-%d.toml" % seq)
        write_private(conf, ATTEST_CONF % {"seq": seq, "url": RPC_URL, "user": RPC_USER, "password": RPC_PASSWORD, "every": ATTEST_INTERVAL,
                                            "heartbeat": ATTEST_HEARTBEAT_BLOCKS, "ref_lag": REF_LAG, "bus": bus})
        mock = os.path.join(STATE_DIR, "price-attest-%d" % seq)
        write_price(mock, price)
        if not alive(state["agents"].get("attest-%d" % seq)):
            state["agents"]["attest-%d" % seq] = spawn("attest-%d" % seq, [ATTEST_AGENT, "--conf", conf, "attest", "--mock-price", mock])
    conf = os.path.join(STATE_DIR, "subscribe.toml")
    write_private(conf, SUBSCRIBE_CONF % {"url": RPC_URL, "user": RPC_USER, "password": RPC_PASSWORD, "bus": bus})
    if not alive(state["agents"].get("subscribe")):
        state["agents"]["subscribe"] = spawn("subscribe", [ATTEST_AGENT, "--conf", conf, "subscribe"])
    save_state(state)
    if rpc("yed_getinfo")["attest"]["poolFresh"] < M_SELECT:
        generate(ATTEST_INTERVAL + REF_LAG, "mined into an attestation tick")
    info = wait_until("poolFresh >= %d (see %s/attest-*.log, subscribe.log)" % (M_SELECT, STATE_DIR),
                      lambda: (lambda a: a if a["poolFresh"] >= M_SELECT else None)(rpc("yed_getinfo")["attest"]), 180)
    print("  attestations: poolFresh %d, pool holds %d" % (info["poolFresh"], info["poolSize"]))


def start_walk(state, price):
    if not alive(state["agents"].get("walk")):
        state["agents"]["walk"] = spawn("walk", [sys.executable, os.path.abspath(__file__), "_walk", "--price", str(price)])
        save_state(state)


def walk(args):
    """The price walk: every tick the quote's and every attestor's mock price takes a small random
    step and stays within WALK_BAND_PCT of the base; written together, so pools and attestors agree."""
    base = args.price
    value = base
    while True:
        value *= 1 + random.gauss(0, WALK_VOL_PCT / 100)
        value = min(max(value, base * (1 - WALK_BAND_PCT / 100)), base * (1 + WALK_BAND_PCT / 100))
        for name in os.listdir(STATE_DIR):
            if name.startswith("price-") and not name.endswith(".tmp"):
                write_price(os.path.join(STATE_DIR, name), value)
        print("%s $%.4f" % (time.strftime("%H:%M:%S"), value), flush=True)
        time.sleep(WALK_TICK)


# ------------------------------------------------------------------------------------ commands

def up(args):
    for path, what in ((QUOTE_AGENT, "the quote agent"), (ATTEST_AGENT, "yellowback-attest (cd %s && cargo build --locked --release)" % ATTEST_CRATE)):
        if not os.access(path, os.X_OK):
            raise SystemExit("%s not found at %s" % (what, path))
    info = rpc("yed_getinfo")
    if info["upgrade"]["status"] != "active" or not info["upgrade"].get("attestorSetId"):
        raise SystemExit("the node is not armed with an attestor set (yed_getinfo.upgrade: %r); the chart's arming Job does that" % info["upgrade"])
    os.makedirs(STATE_DIR, exist_ok=True)
    # Resumable: an agent still running from an earlier `up` is kept (a foreign `helm upgrade` from a
    # chart without the payout lookup restarts the node without its flag; `up` again puts it back).
    state = load_state()
    state["agents"] = {name: pid for name, pid in (state.get("agents") or {}).items() if alive(pid)}
    state.update({"price": args.price, "created": state.get("created") or time.strftime("%Y-%m-%d %H:%M:%S"), "rpc": RPC_URL})
    if state["agents"]:
        print("resuming: %s still running" % ", ".join(sorted(state["agents"])))
    save_state(state)
    print("[1/5] the pool")
    ensure_payout()
    print("[2/5] the quote agent at $%.2f, then the price windows" % args.price)
    start_quote(state, args.price)
    fill_windows()
    print("[3/5] the attestors (%d)" % args.attestors)
    register_attestors(args.attestors)
    print("[4/5] the attest agents and the subscriber (dir transport at %s/bus)" % STATE_DIR)
    start_attest_agents(state, args.price)
    if args.no_walk:
        print("[5/5] no price walk (--no-walk): a constant quote beside constant attestations is not pinned)")
    else:
        print("[5/5] the price walk (±%.0f%% band, %.1f%% per %ds tick)" % (WALK_BAND_PCT, WALK_VOL_PCT, WALK_TICK))
        start_walk(state, args.price)
    print(summary())


def down(args):
    state = load_state()
    for name, pid in sorted((state.get("agents") or {}).items()):
        kill(name, pid)
    state["agents"] = {}
    save_state(state)
    print("personas stopped; the chain stays as it is (ARMED; the attestations go stale after a few blocks and minting halts until `up`)")


def summary():
    info = rpc("yed_getinfo")
    price = rpc("yed_getprice")
    stats = rpc("yed_getstats")
    a = info["attest"]
    fill = price["fill"]
    lines = ["node: height %d, attest %s (%d seated, poolFresh %d), pool payout %s, quote %s" % (
        info["height"], a["status"], a["seatedCount"], a["poolFresh"], info["miner"]["payoutAddress"], info["miner"]["quoteKind"]),
        "price: pMint %s µUSD, xMint %s (quote tags fast/mid/slow %d/%d/%d of %d/%d/%d)" % (
            price.get("pMint"), price.get("xMint"), fill["fast"]["quoteTags"], fill["mid"]["quoteTags"], fill["slow"]["quoteTags"],
            fill["fast"]["window"], fill["mid"]["window"], fill["slow"]["window"]),
        "mint gate: %s (halts %s, classes %s)" % ("allowed" if stats["mintingAllowed"] else "HALTED", stats["haltMask"], stats["mintableClasses"])]
    try:
        est = rpc("yed_estimatecollateral", 10000, 48)
        lines.append("mint: $100.00 for 48 blocks needs %.8f YEC collateral (class %s, bundle seqs %s)" % (est["requiredZat"] / 1e8, est["termClass"], est.get("bundleSeqs")))
    except RpcError as error:
        lines.append("mint: %s" % error)
    return "\n".join(lines)


def status(args):
    state = load_state()
    agents = state.get("agents") or {}
    if not agents:
        print("personas: not running (`make kind-personas-up`)")
    for name, pid in sorted(agents.items()):
        print("  %-12s %s" % (name, "running (pid %d)" % pid if alive(pid) else "DEAD (see %s/%s.log)" % (STATE_DIR, name)))
    print(summary())


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("up")
    p.add_argument("--price", type=float, default=50.0, help="the YEC/USD price the pool quotes and the attestors sign (default 50, the devnet's)")
    p.add_argument("--attestors", type=int, default=ATTEST_ARM_MIN, help="registrations (default %d = ATTEST_ARM_MIN)" % ATTEST_ARM_MIN)
    p.add_argument("--no-walk", action="store_true")
    p.set_defaults(func=up)
    sub.add_parser("down").set_defaults(func=down)
    sub.add_parser("status").set_defaults(func=status)
    p = sub.add_parser("_walk")
    p.add_argument("--price", type=float, required=True)
    p.set_defaults(func=walk)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
