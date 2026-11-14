#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Check a state bundle directory against bundles/state/FORMAT.md, offline: `ycash-state/1` (the testnet
bundle), `ycash-state/2` (mainnet and other single-producer bundles) and `kogany-state/1` / `kogany-state/2`
(a kogany state cache; v2 records its storage mode, archive or pruned).

  python3 -I bundles/state/verify.py [--tree] DIR      DIR holds the tarball, manifest.json, SHA256SUMS, ...

`--tree` also recomputes a v2 or kogany bundle's tree hash from the tarball's members (a full read of the
tarball; without it the members' headers are still checked).

It checks the files and their hashes, the manifest's and the statements' canonical form and agreement,
and the tarball's entries (names, types, the fixed headers). It does not start a node: whether the state
inside is the state the statements name is what a node checks (the snapshotter's restore-check,
ycash-bootstrap). Exit status 0 when every check passes; each failure is printed.
"""
import hashlib
import json
import os
import re
import sys
import tarfile

FORMAT = "ycash-state/1"
FORMAT_V2 = "ycash-state/2"
KOGANY_FORMAT = "kogany-state/1"
KOGANY_FORMAT_V2 = "kogany-state/2"
KOGANY_FORMATS = (KOGANY_FORMAT, KOGANY_FORMAT_V2)
STORAGE_MODES = ("archive", "pruned")
# Zakura's Mainnet/Testnet retention floor (zakura-state constants.rs MIN_PRUNING_RETENTION): a pruned
# kogany keeps the raw transactions of at least this many blocks below its finalized tip.
MIN_PRUNING_RETENTION = 10_000
FORMATS = (FORMAT, FORMAT_V2)
NETWORKS = ("testnet-yb-fast", "testnet-yb-slow", "testnet-legacy", "testnet", "main")
STATEMENT_FIELDS = ("network", "height", "blockhash", "chainwork", "utxo_hash_serialized", "vault_statehash", "yed_statehash")
MANIFEST_FIELDS = ("format", "line", "version", "flavour", "profile", "tarball", "sha256", "bytes", "created", "producer", "verifiers")
V2_STATEMENT_FIELDS = STATEMENT_FIELDS + ("finalsaplingroot", "chainsupply_zat")
V2_MANIFEST_FIELDS = MANIFEST_FIELDS + ("commit", "tree_sha256", "pins")
TOP_DIRS = ("blocks", "chainstate", "vaults", "yellowback")
LEFT_OUT = re.compile(r"(^|/)(LOCK|LOG|LOG\.old)$")
KOGANY_LEFT_OUT = re.compile(r"(^|/)(LOCK|LOG|LOG\.old.*)$")
HEX64 = re.compile(r"[0-9a-f]{64}")

# ycash6's compiled mainnet pins at 65cb4ae0f (`src/chainparams.cpp`): checkpointData, the Ycash fork
# block (UPGRADE_YCASH.hashActivationBlock, 570,000) and the chain-supply checkpoint block (2,800,000).
# Identical to kogany's qa/kogany_checkpoints.py MAINNET_PINS. A v2 `main` bundle at H names every pin
# at or below H in its manifest `pins`, each equal to this table.
MAINNET_PINS = {
    0: "00040fe8ec8471911baa1db1266ea15dd06b4a8a5c453883c000b031973dce08",
    2500: "00000006dc968f600be11a86cbfbf7feb61c7577f45caced2e82b6d261d19744",
    15000: "00000000b6bc56656812a5b8dcad69d6ad4446dec23b5ec456c18641fb5381ba",
    67500: "000000006b366d2c1649a6ebb4787ac2b39c422f451880bc922e3a6fbd723616",
    100000: "000000001c5c82cd6baccfc0879e3830fd50d5ede17fa2c37a9a253c610eb285",
    133337: "0000000002776ccfaf06cc19857accf3e20c01965282f916b8a886e3e4a05be9",
    180000: "000000001205b742eac4a1b3959635bdf8aeada078d6a996df89740f7b54351d",
    222222: "000000000cafb9e56445a6cabc8057b57ee6fcc709e7adbfa195e5c7fac61343",
    270000: "00000000025c1cfa0258e33ab050aaa9338a3d4aaa3eb41defefc887779a9729",
    304600: "00000000028324e022a45014c4a4dc51e95d41e6bceb6ad554c5b65d5cea3ea5",
    410100: "0000000002c565958f783a24a4ac17cde898ff525e75ed9baf66861b0b9fcada",
    497000: "0000000000abd333f0acca6ffdf78a167699686d6a7d25c33fca5f295061ffff",
    525000: "0000000001a36c500378be8862d9bf1bea8f1616da6e155971b608139cc7e39b",
    570000: "0000014fbc5917ba8bcacf3336faf588d86b32443aa3a490a587af5750c77ec5",
    572760: "00000008db657f58222e38e354c18ccbb6c74cf525ef4f3a95f0f8a324a3166d",
    980000: "00000510ccc6bae2ddb38b9313ffb9686397f6cd0dee243462baeaf8911d0791",
    1035353: "00000543378a75f173914390c672838c9fbd9dc86ae647ffae18ed6b626edb30",
    1575000: "000002b856230b06caa3412058e6490fab256cee9d9d9fb68eae59b4ebd94471",
    2250000: "000003f98b7497fdcd8a6b6d10a93a887c5d47127e24a9dc3a40cb65754d21e7",
    2800000: "000003170414909d5104f4a71708eca4e5b545d231c412c2d3e0e3f33874facb",
}


def tree_line(digest, path):
    """One line of a bundle's tree hash: `<sha256>  <path>\\n`, per regular file, in tar order."""
    return ("%s  %s\n" % (digest, path)).encode()


def canonical(obj):
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def tarball_name(m):
    return f"ycash6-{m['network']}-{m['height']}-{m['flavour']}.tar.gz"


def check_tar(path, network, flavour, errors, tree=False, kogany=False, kogany_nf=0):
    """Check the entries; with tree, return the tree hash of the members (else None)."""
    names = []
    nf_seen = 0
    th = hashlib.sha256() if tree else None
    with tarfile.open(path, "r|gz") as t:
        for e in t:
            names.append(e.name)
            n = e.name.rstrip("/")
            if n.startswith("/") or ".." in n.split("/"):
                errors.append(f"tar: unsafe path {e.name}")
                continue
            parts = n.split("/")
            if kogany:
                if parts[0] == "non_finalized_state":
                    nf_seen += e.isfile()
                    if len(parts) > 1 and parts[1] != "mainnet":
                        errors.append(f"tar: {e.name} is not under non_finalized_state/mainnet/")
                elif parts[0] != "state" or (len(parts) > 1 and not re.fullmatch(r"v\d+", parts[1])) or \
                        (len(parts) > 2 and parts[2] != "mainnet"):
                    errors.append(f"tar: {e.name} is not under state/v<major>/mainnet/ or non_finalized_state/mainnet/")
                if KOGANY_LEFT_OUT.search(n):
                    errors.append(f"tar: {e.name} is a file the format leaves out")
            else:
                if parts[0] != network or len(parts) < 2 or parts[1] not in TOP_DIRS:
                    errors.append(f"tar: {e.name} is not under {network}/{{{','.join(TOP_DIRS)}}}")
                if LEFT_OUT.search(n) or n == f"{network}/yellowback/carriers.dat":
                    errors.append(f"tar: {e.name} is a file the format leaves out")
                if flavour == "full" and n.startswith(f"{network}/blocks/insight-index"):
                    errors.append(f"tar: {e.name}: insight-index is in the full-insight flavour only")
            if not (e.isfile() or e.isdir()):
                errors.append(f"tar: {e.name} is neither a file nor a directory")
            if e.mtime != 0 or e.uid != 0 or e.gid != 0 or e.uname or e.gname:
                errors.append(f"tar: {e.name} has a non-fixed header (mtime {e.mtime}, owner {e.uid}:{e.gid} {e.uname}:{e.gname})")
            if th is not None and e.isfile():
                h = hashlib.sha256()
                f = t.extractfile(e)
                while chunk := f.read(1 << 20):
                    h.update(chunk)
                th.update(tree_line(h.hexdigest(), n))
    if names != sorted(names, key=lambda s: s.rstrip("/").encode()):
        errors.append("tar: entries are not in bytewise name order")
    if not kogany:
        for d in ("blocks", "chainstate"):
            if f"{network}/{d}" not in {n.rstrip("/") for n in names}:
                errors.append(f"tar: no {network}/{d}/")
        if flavour == "full-insight" and not any(n.startswith(f"{network}/blocks/insight-index/") and
                                                 not n.endswith("/") for n in names):
            errors.append(f"tar: full-insight without a file under {network}/blocks/insight-index/")
    elif nf_seen != kogany_nf:
        errors.append(f"tar: {nf_seen} non-finalized block file(s), the manifest says {kogany_nf}")
    return th.hexdigest() if th is not None else None


def check_sums(d, errors):
    """SHA256SUMS lists every other file, sorted, matching. Returns the directory's other files."""
    try:
        with open(os.path.join(d, "SHA256SUMS"), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        errors.append(f"SHA256SUMS: {e}")
        return None
    listed = []
    for line in lines:
        mm = re.fullmatch(r"([0-9a-f]{64})  (\S+)", line)
        if not mm:
            errors.append(f"SHA256SUMS: malformed line {line!r}")
            continue
        digest, name = mm.groups()
        listed.append(name)
        p = os.path.join(d, name)
        if os.path.basename(name) != name or not os.path.isfile(p):
            errors.append(f"SHA256SUMS: {name} is missing")
        elif sha256(p) != digest:
            errors.append(f"SHA256SUMS: {name} does not match")
    present = sorted(n for n in os.listdir(d) if n != "SHA256SUMS" and not n.endswith(".minisig"))
    if listed != sorted(listed, key=str.encode):
        errors.append("SHA256SUMS: not sorted by name")
    if sorted(listed) != present:
        errors.append(f"SHA256SUMS lists {sorted(listed)}, the directory has {present}")
    return present


def kogany_tarball_name(m):
    """`kogany-main-<H>-state-<state_format>.tar.gz`, with `-pruned` before `.tar.gz` for a pruned v2 bundle."""
    suffix = "-pruned" if m.get("storage_mode") == "pruned" else ""
    return f"kogany-main-{m['height']}-state-{m['state_format']}{suffix}.tar.gz"


def check_storage_mode(m, errors):
    """`kogany-state/2`: `storage_mode` and `lowest_retained_height` (FORMAT.md). An archive bundle has
    every raw transaction (`null`); a pruned one has none below `lowest_retained_height` but genesis's (0:
    pruned mode, nothing deleted yet), and keeps at least Zakura's Mainnet floor below its finalized tip."""
    mode, low = m["storage_mode"], m["lowest_retained_height"]
    if mode not in STORAGE_MODES:
        errors.append(f"manifest: storage_mode {mode!r}, expected one of {STORAGE_MODES}")
        return
    if mode == "archive":
        if low is not None:
            errors.append(f"manifest: an archive bundle has lowest_retained_height null, not {low!r}")
        return
    if not isinstance(low, int) or isinstance(low, bool) or low < 0 or low > m["height"]:
        errors.append(f"manifest: lowest_retained_height {low!r} is not a height in 0..{m['height']}")
        return
    nf = m.get("non_finalized_blocks", 0)
    finalized = m["height"] - (nf if isinstance(nf, int) else 0)
    if low > 0 and finalized - low + 1 < MIN_PRUNING_RETENTION:
        errors.append(f"manifest: lowest_retained_height {low} keeps {finalized - low + 1} blocks below the "
                      f"finalized tip {finalized}, fewer than Zakura's floor {MIN_PRUNING_RETENTION}")


def verify_kogany(d, m, raw, tree, errors):
    """`kogany-state/1` and `/2` (FORMAT.md): a stopped kogany state cache, valid only for its state format;
    v2 also names its storage mode."""
    need = ("format", "line", "network", "height", "blockhash", "state_format", "tarball", "sha256", "bytes",
            "tree_sha256", "producer", "version", "agrees_with")
    if m["format"] == KOGANY_FORMAT_V2:
        need += ("non_finalized_blocks", "storage_mode", "lowest_retained_height")
    elif "storage_mode" in m or "lowest_retained_height" in m:
        errors.append("manifest: storage_mode / lowest_retained_height are kogany-state/2 fields")
    missing = [k for k in need if k not in m]
    if missing:
        return errors + [f"manifest: missing {', '.join(missing)}"]
    if m["line"] != "kogany" or m["network"] != "main":
        errors.append(f"manifest: line {m['line']!r}, network {m['network']!r}")
    if not re.fullmatch(r"\d+\.\d+\.\d+", str(m["state_format"])):
        errors.append(f"manifest: state_format {m['state_format']!r}")
    if not HEX64.fullmatch(str(m["blockhash"])):
        errors.append("manifest: blockhash is not 64 hex digits")
    pin = MAINNET_PINS.get(m["height"])
    if pin and pin != m["blockhash"]:
        errors.append(f"manifest: blockhash at {m['height']} is not ycash6's pin {pin}")
    if m["format"] == KOGANY_FORMAT_V2:
        check_storage_mode(m, errors)
    name = kogany_tarball_name(m)
    if m["tarball"] != name:
        errors.append(f"manifest: tarball {m['tarball']!r}, expected {name!r}")
    if check_sums(d, errors) is None:
        return errors
    tp = os.path.join(d, m["tarball"])
    if not os.path.isfile(tp):
        return errors + [f"{m['tarball']} is missing"]
    if sha256(tp) != m["sha256"]:
        errors.append("manifest: sha256 does not match the tarball")
    if os.path.getsize(tp) != m["bytes"]:
        errors.append("manifest: bytes does not match the tarball")
    nf = m.get("non_finalized_blocks", 0)    # absent in the first bundles: 0
    if not isinstance(nf, int) or nf < 0:
        errors.append(f"manifest: non_finalized_blocks {nf!r}")
        nf = 0
    th = check_tar(tp, "state", "full", errors, tree=tree, kogany=True, kogany_nf=nf)
    if th is not None and th != m["tree_sha256"]:
        errors.append("manifest: tree_sha256 does not match the tarball's members")
    return errors


def verify(d, tree=False):
    errors = []
    try:
        with open(os.path.join(d, "manifest.json"), encoding="utf-8") as f:
            raw = f.read()
        m = json.loads(raw)
    except (OSError, ValueError) as e:
        return [f"manifest.json: {e}"]
    if raw != canonical(m):
        errors.append("manifest.json is not canonical (sorted keys, 2-space indent, one trailing newline)")
    if m.get("format") in KOGANY_FORMATS:
        return verify_kogany(d, m, raw, tree, errors)
    if m.get("format") not in FORMATS:
        errors.append(f"manifest: format {m.get('format')!r}, expected one of {FORMATS + KOGANY_FORMATS}")
    v2 = m.get("format") == FORMAT_V2
    missing = [k for k in STATEMENT_FIELDS[:3] + (V2_MANIFEST_FIELDS if v2 else MANIFEST_FIELDS) if k not in m]
    if missing:
        return errors + [f"manifest: missing {', '.join(missing)}"]
    if m["network"] not in NETWORKS:
        errors.append(f"manifest: unknown network {m['network']!r}")
    if m["flavour"] not in ("full", "full-insight"):
        errors.append(f"manifest: flavour {m['flavour']!r}")
    if m["line"] != "ycash6":
        errors.append(f"manifest: line {m['line']!r} (a bundle is a ycash6 datadir)")
    if not HEX64.fullmatch(str(m["blockhash"])):
        errors.append("manifest: blockhash is not 64 hex digits")
    if m["tarball"] != tarball_name(m):
        errors.append(f"manifest: tarball {m['tarball']!r}, expected {tarball_name(m)!r}")
    if not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", str(m["created"])):
        errors.append(f"manifest: created {m['created']!r} is not YYYY-MM-DDTHH:MM:SSZ")
    # SHA256SUMS: every other file, sorted, matching
    present = check_sums(d, errors)
    if present is None:
        return errors
    # the tarball
    tp = os.path.join(d, m["tarball"])
    if os.path.isfile(tp):
        if sha256(tp) != m["sha256"]:
            errors.append("manifest: sha256 does not match the tarball")
        if os.path.getsize(tp) != m["bytes"]:
            errors.append("manifest: bytes does not match the tarball")
        th = check_tar(tp, m["network"], m["flavour"], errors, tree=tree and v2)
        if th is not None and th != m["tree_sha256"]:
            errors.append("manifest: tree_sha256 does not match the tarball's members")
    else:
        errors.append(f"{m['tarball']} is missing")
    # the statements: canonical, identical, the manifest's statement fields, one per verifier
    statements = sorted(n for n in present if n.startswith("statement-") and n.endswith(".json"))
    names = [n[len("statement-"):-len(".json")] for n in statements]
    if names != sorted(m["verifiers"]):
        errors.append(f"manifest: verifiers {m['verifiers']} but statements {names}")
    if v2:
        if "ycash6" not in names:
            errors.append("v2: statement-ycash6.json is required")
        if m["network"] == "main":
            want = {str(h): x for h, x in MAINNET_PINS.items() if h <= m["height"]}
            if m["pins"] != want:
                errors.append(f"manifest: pins {m['pins']} are not ycash6's compiled pins at or below {m['height']}")
        if not HEX64.fullmatch(str(m["tree_sha256"])):
            errors.append("manifest: tree_sha256 is not 64 hex digits")
        ts = m.get("treestate")
        if ts is not None and ts not in present:
            errors.append(f"manifest: treestate {ts} is missing")
        extra = set(present) - {m["tarball"], "manifest.json"} - set(statements) - ({ts} if ts else set())
        if extra:
            errors.append(f"unexpected files {sorted(extra)}")
    elif len(statements) < 2:
        errors.append(f"{len(statements)} statement(s): at least 2 (plan §4.2)")
    first = None
    for n in statements:
        with open(os.path.join(d, n), encoding="utf-8") as f:
            raw = f.read()
        s = json.loads(raw)
        if raw != canonical(s):
            errors.append(f"{n} is not canonical")
        if not set(s) <= set(V2_STATEMENT_FIELDS if v2 else STATEMENT_FIELDS) or not {"network", "height", "blockhash"} <= set(s):
            errors.append(f"{n}: fields {sorted(s)}")
        if any(m.get(k) != v for k, v in s.items()):
            errors.append(f"{n} disagrees with the manifest")
        if first is None:
            first = raw
        elif raw != first:
            errors.append(f"{n} differs from {statements[0]}")
    return errors


def main():
    args = sys.argv[1:]
    tree = "--tree" in args
    args = [a for a in args if a != "--tree"]
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    errors = verify(args[0], tree=tree)
    for e in errors:
        print(f"verify: {e}", file=sys.stderr)
    if not errors:
        print(f"verify: {args[0]}: ok")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
