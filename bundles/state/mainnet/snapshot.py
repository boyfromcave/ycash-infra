#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Turn a captured mainnet datadir (supervise.py) into a `ycash-state/2` bundle, or a stopped kogany
state cache into a `kogany-state/2` bundle, archive or pruned (bundles/state/FORMAT.md).

  snapshot.py statement  --capture S/H --bin BINDIR [--height H]   statement-ycash6.json, treestate.json
  snapshot.py pack       --capture S/H                              the tarball, its tree hash
  snapshot.py finalize   --capture S/H [--version V]                manifest.json, SHA256SUMS
  snapshot.py all        --capture S/H --bin BINDIR                 the three, then verify.py
  snapshot.py kogany     --cache DIR --height H --blockhash HASH --out DIR [--ycash-statement FILE]
                         [--storage-mode archive|pruned --lowest-retained-height L]

S/H is a capture directory: `datadir/main/{blocks,chainstate,vaults,...}` (the clone taken at the
stop, never modified), `capture.json`; the bundle is written to `S/H/bundle/`.

`statement` clones the capture once more (APFS copy-on-write) into a scratch datadir, starts ycashd
on it offline (no peers, no listening, its own RPC port), rolls back any block above H with
`invalidateblock` (the scratch copy is thrown away afterwards; the capture and the live node are
never touched), and writes the statement at H plus the pins it checked. `pack` writes the tarball
from the capture with the fixed headers of the format, and the capture's tree hash (the SHA-256 of
`<sha256>  <path>` lines of every packed file, in tar order) in the same pass; verify.py recomputes
the tree hash from the tarball, which proves the tarball holds exactly the files the statement was
taken from. Stdlib only (Python >= 3.9).
"""

import argparse
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tarfile
import time

FORMAT = "ycash-state/2"
KOGANY_FORMAT = "kogany-state/2"
TOP_DIRS = ("blocks", "chainstate", "vaults", "yellowback")
LEFT_OUT = re.compile(r"(^|/)(LOCK|LOG|LOG\.old.*)$")
HERE = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = os.path.dirname(HERE)

# ycash6's compiled mainnet pins (65cb4ae0f `src/chainparams.cpp`: checkpointData, the Ycash fork
# block UPGRADE_YCASH.hashActivationBlock at 570,000, the chain-supply checkpoint block at 2,800,000).
# The same table is vendored in verify.py and in kogany's qa/kogany_checkpoints.py.
sys.path.insert(0, STATE_DIR)
from verify import MAINNET_PINS, canonical, check_storage_mode, kogany_tarball_name, tree_line  # noqa: E402


def clone_tree(src, dst):
    """Copy a directory tree copy-on-write where the filesystem can (APFS clonefile, Linux reflink)."""
    cmd = ["cp", "-cR"] if sys.platform == "darwin" else ["cp", "-R", "--reflink=auto"]
    subprocess.run(cmd + [src, dst], check=True)


def log(msg):
    print("snapshot: %s" % msg, flush=True)


def die(msg):
    print("snapshot: %s" % msg, file=sys.stderr, flush=True)
    sys.exit(1)


def dump(path, obj):
    with open(path + ".part", "w", encoding="utf-8") as f:
        f.write(canonical(obj))
    os.replace(path + ".part", path)


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


class Node:
    """ycashd started offline on a scratch datadir."""

    def __init__(self, bindir, datadir, rpcport):
        self.bindir, self.datadir, self.rpcport = bindir, datadir, rpcport
        self.password = secrets.token_hex(16)
        with open(os.path.join(datadir, "ycash.conf"), "w") as f:
            f.write("server=1\nrpcbind=127.0.0.1\nrpcallowip=127.0.0.1\nrpcport=%d\nrpcuser=snapshot\n"
                    "rpcpassword=%s\nlisten=0\nconnect=127.0.0.1:9\ndnsseed=0\ndisablewallet=1\nshowmetrics=0\n"
                    % (rpcport, self.password))
        self.proc = None

    def cli(self, *args, check=True):
        r = subprocess.run([os.path.join(self.bindir, "ycash-cli"), "-datadir=%s" % self.datadir,
                            "-rpcclienttimeout=0"] + [str(a) for a in args], capture_output=True, text=True)
        if check and r.returncode != 0:
            raise RuntimeError("ycash-cli %s: %s" % (args[0], (r.stderr or r.stdout).strip()))
        return r

    def json(self, *args):
        return json.loads(self.cli(*args).stdout)

    def start(self, logpath):
        out = open(logpath, "ab")
        self.proc = subprocess.Popen([os.path.join(self.bindir, "ycashd"), "-datadir=%s" % self.datadir,
                                      "-daemon=0"], stdin=subprocess.DEVNULL, stdout=out,
                                     stderr=subprocess.STDOUT, start_new_session=True)
        out.close()
        last, same = None, 0
        t0 = time.time()
        while True:
            if self.proc.poll() is not None:
                die("the offline node exited with status %d (see %s)" % (self.proc.returncode, logpath))
            r = self.cli("getblockcount", check=False)
            if r.returncode == 0:
                n = int(r.stdout)
                same = same + 1 if n == last else 0
                last = n
                if same >= 3:
                    return n
            if time.time() - t0 > 7200:
                die("the offline node did not settle in 2 h")
            time.sleep(5)

    def stop(self):
        self.cli("stop", check=False)
        try:
            self.proc.wait(timeout=1800)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def ycashd_version(bindir):
    out = subprocess.run([os.path.join(bindir, "ycashd"), "--version"], capture_output=True, text=True).stdout
    m = re.search(r"version v(\S+)", out)
    if not m:
        die("cannot read ycashd --version")
    full = m.group(1)                          # 6.22.0-rc1-65cb4ae0f
    mm = re.fullmatch(r"(.+)-([0-9a-f]{7,40})", full)
    return (mm.group(1), mm.group(2)) if mm else (full, "")


def statement(a):
    cap = os.path.abspath(a.capture)
    capture = load(os.path.join(cap, "capture.json"))
    h = a.height if a.height is not None else capture["height"]
    src = os.path.join(cap, "datadir", "main")
    if not os.path.isdir(os.path.join(src, "chainstate")):
        die("%s holds no chainstate" % src)
    out = os.path.join(cap, "bundle")
    os.makedirs(out, exist_ok=True)
    scratch = os.path.join(cap, "scratch")
    if os.path.exists(scratch):
        shutil.rmtree(scratch)
    clone_tree(src, scratch)
    node = Node(a.bin, scratch, a.rpcport)
    t0 = time.time()
    try:
        tip = node.start(os.path.join(cap, "statement-node.log"))
        log("offline node settled at %d (%.0f s)" % (tip, time.time() - t0))
        if tip < h:
            die("the capture's tip %d is below H %d" % (tip, h))
        if tip > h:
            above = node.cli("getblockhash", h + 1).stdout.strip()
            log("tip %d above %d: invalidateblock %s on the scratch copy" % (tip, h, above))
            node.cli("invalidateblock", above)
        bh = node.cli("getblockhash", h).stdout.strip()
        if node.cli("getbestblockhash").stdout.strip() != bh:
            die("the scratch node's tip is not block %d" % h)
        hdr = node.json("getblockheader", bh)
        blk = node.json("getblock", bh, 1)
        log("gettxoutsetinfo at %d" % h)
        utxo = node.json("gettxoutsetinfo")
        if utxo.get("height") not in (None, h) or utxo.get("bestblock") not in (None, bh):
            die("gettxoutsetinfo is not at %d: %s" % (h, utxo))
        vault = None
        r = node.cli("vault_getinfo", check=False)
        if r.returncode == 0:
            v = json.loads(r.stdout)
            dbtip = (v.get("dbtip") or {}).get("hash")
            if dbtip and dbtip != bh:
                die("the vault database is at %s, not %s" % (dbtip, bh))
            vault = v.get("statehash")
        yed = None
        r = node.cli("yed_getstatehash", h, check=False)
        if r.returncode == 0:
            y = json.loads(r.stdout)
            if y.get("blockhash") != bh:
                die("yed_getstatehash is not at %s" % bh)
            yed = y.get("statehash")
        pins = {}
        for ph, phash in sorted(MAINNET_PINS.items()):
            if ph > h:
                break
            got = node.cli("getblockhash", ph).stdout.strip()
            if got != phash:
                die("pin %d: the node has %s, ycash6 compiles %s" % (ph, got, phash))
            pins[str(ph)] = got
        tree = node.json("z_gettreestate", str(h))
        info = node.json("getnetworkinfo")
    finally:
        node.stop()
        shutil.rmtree(scratch, ignore_errors=True)
    supply = (blk.get("chainSupply") or {}).get("chainValueZat")
    st = {"network": "main", "height": h, "blockhash": bh, "chainwork": hdr["chainwork"],
          "utxo_hash_serialized": utxo["hash_serialized"], "vault_statehash": vault, "yed_statehash": yed,
          "finalsaplingroot": blk["finalsaplingroot"], "chainsupply_zat": supply}
    dump(os.path.join(out, "statement-ycash6.json"), st)
    dump(os.path.join(out, "treestate.json"), tree)
    version, commit = ycashd_version(a.bin)
    meta = {"time": hdr["time"], "subversion": info["subversion"], "version": version, "commit": commit,
            "pins": pins, "utxo": {k: utxo.get(k) for k in ("transactions", "txouts", "total_amount",
                                                          "disk_size", "bytes_serialized")},
            "statement_seconds": round(time.time() - t0)}
    dump(os.path.join(cap, "meta.json"), meta)
    log("statement at %d: %s" % (h, json.dumps(st, sort_keys=True)))


def bundle_entries(root, network, flavour="full"):
    """The (path, is_dir) entries under root/network/, filtered and sorted bytewise (FORMAT.md)."""
    found = []
    for top in TOP_DIRS:
        base = os.path.join(root, network, top)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            rel = os.path.relpath(dirpath, root)
            if rel.startswith(os.path.join(network, "blocks", "insight-index")) and flavour != "full-insight":
                dirnames[:] = []
                continue
            found.append((rel, True))
            for fn in filenames:
                p = os.path.join(rel, fn)
                full = os.path.join(root, p)
                if os.path.islink(full) or not os.path.isfile(full):
                    die("%s is neither a regular file nor a directory" % full)
                if LEFT_OUT.search(p) or p == os.path.join(network, "yellowback", "carriers.dat"):
                    continue
                found.append((p, False))
    found.sort(key=lambda e: e[0].encode())
    return found


class HashingReader:
    def __init__(self, f):
        self.f, self.h = f, hashlib.sha256()

    def read(self, n=-1):
        b = self.f.read(n)
        self.h.update(b)
        return b


def pack_tree(root, network, entries, tarball):
    """Write the tarball (GNU tar, fixed headers, `gzip -n -6`); return the tree hash."""
    tree = hashlib.sha256()
    with open(tarball + ".part", "wb") as out:
        gz = subprocess.Popen(["gzip", "-n", "-6"], stdin=subprocess.PIPE, stdout=out)
        with tarfile.open(fileobj=gz.stdin, mode="w|", format=tarfile.GNU_FORMAT) as t:
            for p, is_dir in entries:
                full = os.path.join(root, p)
                st = os.stat(full)
                ti = tarfile.TarInfo(p + "/" if is_dir else p)
                ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname = 0, 0, 0, "", ""
                # --mode=u=rwX,go=rX
                ti.mode = 0o755 if is_dir or (st.st_mode & 0o111) else 0o644
                if is_dir:
                    ti.type = tarfile.DIRTYPE
                    t.addfile(ti)
                    continue
                ti.size = st.st_size
                with open(full, "rb") as f:
                    r = HashingReader(f)
                    t.addfile(ti, r)
                    if os.fstat(f.fileno()).st_size != st.st_size:
                        die("%s changed while packing" % full)
                tree.update(tree_line(r.h.hexdigest(), p))
        gz.stdin.close()
        if gz.wait() != 0:
            die("gzip failed")
    os.replace(tarball + ".part", tarball)
    return tree.hexdigest()


def tarball_name(network, height, flavour="full"):
    return "ycash6-%s-%d-%s.tar.gz" % (network, height, flavour)


def pack(a):
    cap = os.path.abspath(a.capture)
    h = load(os.path.join(cap, "capture.json"))["height"]
    root = os.path.join(cap, "datadir")
    out = os.path.join(cap, "bundle")
    os.makedirs(out, exist_ok=True)
    entries = bundle_entries(root, "main")
    if not any(p == "main/chainstate" for p, _ in entries):
        die("no main/chainstate in %s" % root)
    t = os.path.join(out, tarball_name("main", h))
    t0 = time.time()
    log("packing %d entries into %s" % (len(entries), t))
    tree = pack_tree(root, "main", entries, t)
    dump(os.path.join(cap, "pack.json"), {"tree_sha256": tree, "entries": len(entries),
                                           "pack_seconds": round(time.time() - t0)})
    log("packed %d bytes in %.0f s, tree %s" % (os.path.getsize(t), time.time() - t0, tree))


def write_sums(out):
    names = sorted((n for n in os.listdir(out) if n != "SHA256SUMS" and not n.endswith(".part")), key=str.encode)
    with open(os.path.join(out, "SHA256SUMS.part"), "w") as f:
        for n in names:
            f.write("%s  %s\n" % (sha256_file(os.path.join(out, n)), n))
    os.replace(os.path.join(out, "SHA256SUMS.part"), os.path.join(out, "SHA256SUMS"))


def finalize(a):
    cap = os.path.abspath(a.capture)
    out = os.path.join(cap, "bundle")
    st = load(os.path.join(out, "statement-ycash6.json"))
    meta = load(os.path.join(cap, "meta.json"))
    pk = load(os.path.join(cap, "pack.json"))
    t = tarball_name("main", st["height"])
    tp = os.path.join(out, t)
    verifiers = sorted(n[len("statement-"):-len(".json")] for n in os.listdir(out)
                       if n.startswith("statement-") and n.endswith(".json"))
    m = dict(st)
    m.update({
        "format": FORMAT, "line": "ycash6", "profile": "", "flavour": "full",
        "version": a.version or meta["version"], "commit": meta["commit"],
        "tarball": t, "sha256": sha256_file(tp), "bytes": os.path.getsize(tp),
        "tree_sha256": pk["tree_sha256"],
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(meta["time"])),
        "producer": "ycash-infra/mainnet-snapshot", "verifiers": verifiers, "pins": meta["pins"],
        "treestate": "treestate.json",
    })
    if a.purpose:
        m["purpose"] = a.purpose
    dump(os.path.join(out, "manifest.json"), m)
    write_sums(out)
    log("manifest: %s" % canonical(m).strip())


def run_verify(out, full=True):
    args = [sys.executable, "-I", os.path.join(STATE_DIR, "verify.py")] + (["--tree"] if full else []) + [out]
    return subprocess.run(args).returncode


def kogany(a):
    """A stopped kogany (Zakura) state cache at H as a `kogany-state/2` bundle (FORMAT.md). The storage
    mode and the lowest retained height are the producer's to state (the database holds them in RocksDB,
    which this stdlib tool does not read): `getblockchaininfo.pruned` / `pruneheight` before the stop, or
    the `zakura-prune-state` summary's "new lowest retained height" for a cache pruned offline."""
    mode = getattr(a, "storage_mode", "archive") or "archive"
    low = getattr(a, "lowest_retained_height", None)
    if mode == "pruned" and low is None:
        die("--storage-mode pruned needs --lowest-retained-height (the node's pruneheight)")
    if mode == "archive" and low is not None:
        die("--lowest-retained-height is for --storage-mode pruned")
    cache = os.path.abspath(a.cache)
    vdir = None
    for major in sorted(os.listdir(os.path.join(cache, "state")), reverse=True):
        cand = os.path.join(cache, "state", major, "mainnet")
        if re.fullmatch(r"v\d+", major) and os.path.isdir(cand):
            vdir = cand
            break
    if not vdir:
        die("no state/v*/mainnet under %s" % cache)
    with open(os.path.join(vdir, "version")) as f:
        sv = f.read().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", sv):
        die("state format version %r" % sv)
    if os.path.exists(os.path.join(vdir, "LOCK")) and a.check_stopped:
        r = subprocess.run(["lsof", "+D", vdir], capture_output=True, text=True)
        if r.stdout.strip():
            die("the kogany state is open by a running process: stop koganyd first")
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    stage = os.path.join(out, ".stage")
    if os.path.exists(stage):
        shutil.rmtree(stage)
    rel = os.path.join("state", os.path.basename(os.path.dirname(vdir)), "mainnet")
    os.makedirs(os.path.dirname(os.path.join(stage, rel)))
    clone_tree(vdir, os.path.join(stage, rel))
    # the non-finalized state (the blocks above the finalized tip; kogany restores them on
    # reopen): part of the snapshot whenever the cache has any, so the bundle's tip is the node's tip
    nf = os.path.join(cache, "non_finalized_state", "mainnet")
    nf_files = sorted(os.listdir(nf)) if os.path.isdir(nf) else []
    if nf_files:
        os.makedirs(os.path.join(stage, "non_finalized_state"))
        clone_tree(nf, os.path.join(stage, "non_finalized_state", "mainnet"))
    entries = []
    for dirpath, dirnames, filenames in os.walk(stage):
        if dirpath == stage:
            continue
        r = os.path.relpath(dirpath, stage)
        entries.append((r, True))
        for fn in filenames:
            p = os.path.join(r, fn)
            if not LEFT_OUT.search(p):
                entries.append((p, False))
    entries.sort(key=lambda e: e[0].encode())
    m = {"format": KOGANY_FORMAT, "line": "kogany", "network": "main", "height": a.height,
         "blockhash": a.blockhash, "state_format": sv, "producer": "ycash-infra/mainnet-snapshot",
         "version": a.version, "agrees_with": None, "non_finalized_blocks": len(nf_files),
         "storage_mode": mode, "lowest_retained_height": low}
    errors = []
    check_storage_mode(m, errors)
    if errors:
        shutil.rmtree(stage)
        die("; ".join(errors))
    name = kogany_tarball_name(m)
    tree = pack_tree(stage, "state", entries, os.path.join(out, name))
    shutil.rmtree(stage)
    m.update({"tarball": name, "sha256": sha256_file(os.path.join(out, name)),
              "bytes": os.path.getsize(os.path.join(out, name)), "tree_sha256": tree})
    if a.ycash_statement:
        y = load(a.ycash_statement)
        if y["height"] != a.height or y["blockhash"] != a.blockhash:  # the tip: compare the same height
            die("the ycash6 statement is at %d %s, not %d %s" % (y["height"], y["blockhash"], a.height, a.blockhash))
        m["agrees_with"] = "ycash6:%s" % sha256_file(a.ycash_statement)
    pins_at = MAINNET_PINS.get(a.height)
    if pins_at and pins_at != a.blockhash:
        die("pin %d is %s, not %s" % (a.height, pins_at, a.blockhash))
    dump(os.path.join(out, "manifest.json"), m)
    write_sums(out)
    log("kogany bundle: %s" % canonical(m).strip())


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("statement", "pack", "finalize", "all"):
        sp = sub.add_parser(name)
        sp.add_argument("--capture", required=True)
        sp.add_argument("--bin", required=name in ("statement", "all"))
        sp.add_argument("--height", type=int)
        sp.add_argument("--rpcport", type=int, default=18252)
        sp.add_argument("--version", help="the release name (default: from ycashd --version)")
        sp.add_argument("--purpose", help="why this height (manifest `purpose`)")
    sp = sub.add_parser("kogany")
    sp.add_argument("--cache", required=True, help="kogany's cache dir (holds state/v<major>/mainnet)")
    sp.add_argument("--height", type=int, required=True)
    sp.add_argument("--blockhash", required=True)
    sp.add_argument("--out", required=True)
    sp.add_argument("--version", default="", help="the kogany release or commit that wrote the state")
    sp.add_argument("--ycash-statement", help="statement-ycash6.json at the same height, to agree with")
    sp.add_argument("--no-check-stopped", dest="check_stopped", action="store_false")
    sp.add_argument("--storage-mode", choices=("archive", "pruned"), default="archive",
                    help="the cache's Zakura storage mode (default archive)")
    sp.add_argument("--lowest-retained-height", type=int,
                    help="pruned: the lowest height whose raw transactions the cache keeps (pruneheight)")
    a = ap.parse_args(argv)
    if a.cmd == "statement":
        statement(a)
    elif a.cmd == "pack":
        pack(a)
    elif a.cmd == "finalize":
        finalize(a)
    elif a.cmd == "kogany":
        kogany(a)
        return run_verify(a.out)
    else:
        statement(a)
        pack(a)
        finalize(a)
        return run_verify(os.path.join(os.path.abspath(a.capture), "bundle"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
