# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""A stand-in for the node image's ycashd-entrypoint and ycash-cli, enough for charts/ycash-testnet/files/
snapshot.sh: no consensus, a chain that is a function of the height, and a node's state kept as files in its
datadir (the CLI reads and writes them; no RPC server).

- `ycashd-entrypoint -stopatheight=H ...` (a sync): writes a datadir at H (blocks, chainstate, vaults,
  yellowback, and the files a bundle leaves out), stores MOCK_AHEAD blocks above H unconnected, prints the
  -stopatheight line and exits 0.
- `ycashd-entrypoint -connect=0 ...` (offline): connects what the datadir stores and serves the CLI until
  `ycash-cli stop`.
- MOCK_SALT changes the block hashes (another chain); MOCK_NO_YED makes yed_getstatehash unknown.
"""
import hashlib
import json
import os
import sys
import time

NET = os.environ.get("NETDIR", "testnet-yb-fast")
SALT = os.environ.get("MOCK_SALT", "")
AHEAD = int(os.environ.get("MOCK_AHEAD", "3"))


def h256(*parts):
    return hashlib.sha256("|".join(str(p) for p in parts).encode()).hexdigest()


def bhash(h):
    return h256("block", h, SALT)


def netdir(datadir):
    return os.path.join(datadir, NET)


def write(path, data):
    """Atomically: the CLI and the node read and write the state concurrently."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        f.write(data)
    os.replace(tmp, path)


def read_state(datadir):
    with open(os.path.join(netdir(datadir), "mock-state.json")) as f:
        return json.load(f)


def write_state(datadir, st):
    write(os.path.join(netdir(datadir), "mock-state.json"), json.dumps(st))


def entrypoint(argv):
    datadir = os.environ.get("YCASHD_DATADIR", "/var/lib/ycash")
    args = dict(a.lstrip("-").split("=", 1) for a in argv if "=" in a)
    nd = netdir(datadir)
    if "stopatheight" in args:
        h = int(args["stopatheight"])
        for rel, data in {
            "blocks/blk00000.dat": f"blocks to {h + AHEAD}",
            "blocks/rev00000.dat": f"undo to {h}",
            "blocks/index/000003.ldb": f"index {h}",
            "blocks/index/LOCK": "",
            "blocks/index/LOG": f"log {time.time()}",
            "blocks/insight-index/000001.ldb": "insight",
            "chainstate/000005.ldb": f"utxo at {h}",
            "chainstate/LOCK": "",
            "vaults/000002.ldb": f"vaults at {h}",
            "yellowback/000002.ldb": f"yed at {h}",
            "yellowback/carriers.dat": "wallet carriers",
            "wallet.dat": "keys", "peers.dat": "peers", "debug.log": "log", ".lock": "",
            "database/log.0000000001": "db",
        }.items():
            write(os.path.join(nd, rel), data)
        write_state(datadir, {"active": h, "stored": h + AHEAD, "chainstate": f"utxo at {h}"})
        print(f"-stopatheight: the active chain is at height {h}; shutting down", flush=True)
        return 0
    # what the datadir holds (a restored bundle has no mock-state.json: the format leaves it out)
    with open(os.path.join(nd, "blocks/blk00000.dat")) as f:
        stored = int(f.read().split()[-1])
    with open(os.path.join(nd, "chainstate/000005.ldb")) as f:
        chainstate = f.read()
    st = {"stored": stored, "chainstate": chainstate}
    st["active"] = st["stored"]      # it connects the stored blocks above the stop height too
    st["running"] = True
    write_state(datadir, st)
    while read_state(datadir).get("running"):
        time.sleep(0.05)
    return 0


def cli(argv):
    datadir = next(a.split("=", 1)[1] for a in argv if a.startswith("-datadir="))
    rest = [a for a in argv if not a.startswith("-")]
    method, params = rest[0], rest[1:]
    st = read_state(datadir)
    if not st.get("running"):
        print("error: couldn't connect to server", file=sys.stderr)
        return 1
    a = st["active"]
    state_of = lambda h: h256(st["chainstate"], h)  # noqa: E731
    if method == "getblockcount":
        out = a
    elif method == "getblockhash":
        out = bhash(int(params[0]))
    elif method == "getbestblockhash":
        out = bhash(a)
    elif method == "getblockheader":
        h = next(i for i in range(st["stored"] + 1) if bhash(i) == params[0])
        out = {"height": h, "chainwork": "%064x" % (h * 1000), "time": 1_800_000_000 + 75 * h}
    elif method == "invalidateblock":
        h = next(i for i in range(st["stored"] + 1) if bhash(i) == params[0])
        st["active"] = h - 1
        st["invalid"] = h
        out = None
    elif method == "reconsiderblock":
        st.pop("invalid", None)
        st["active"] = st["stored"]
        out = None
    elif method == "gettxoutsetinfo":
        out = {"height": a, "hash_serialized": h256("utxo", state_of(a))}
    elif method == "vault_getinfo":
        out = {"statehash": h256("vault", state_of(a)), "dbtip": {"hash": bhash(a), "height": a}}
    elif method == "yed_getstatehash":
        if os.environ.get("MOCK_NO_YED"):
            print("error code: -32601\nerror message:\nMethod not found", file=sys.stderr)
            return 1
        out = {"height": a, "blockhash": bhash(a), "statehash": h256("yed", state_of(a))}
    elif method == "getnetworkinfo":
        out = {"subversion": "/MagicBean:6.22.0-rc1/"}
    elif method == "stop":
        st["running"] = False
        out = "Ycash server stopping"
    else:
        print(f"error: unknown method {method}", file=sys.stderr)
        return 1
    write_state(datadir, st)
    if out is not None:
        print(out if isinstance(out, (str, int)) else json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    tool = os.path.basename(sys.argv[1])
    sys.exit(entrypoint(sys.argv[2:]) if tool == "ycashd-entrypoint" else cli(sys.argv[2:]))
