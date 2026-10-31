#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Check a state bundle directory against bundles/state/FORMAT.md (`ycash-state/1`), offline.

  python3 -I bundles/state/verify.py DIR      DIR holds the tarball, manifest.json, SHA256SUMS, statement-*.json

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
NETWORKS = ("testnet-yb-fast", "testnet-yb-slow", "testnet-legacy", "testnet", "main")
STATEMENT_FIELDS = ("network", "height", "blockhash", "chainwork", "utxo_hash_serialized", "vault_statehash", "yed_statehash")
MANIFEST_FIELDS = ("format", "line", "version", "flavour", "profile", "tarball", "sha256", "bytes", "created", "producer", "verifiers")
TOP_DIRS = ("blocks", "chainstate", "vaults", "yellowback")
LEFT_OUT = re.compile(r"(^|/)(LOCK|LOG|LOG\.old)$")
HEX64 = re.compile(r"[0-9a-f]{64}")


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


def check_tar(path, network, flavour, errors):
    names = []
    with tarfile.open(path, "r:gz") as t:
        for e in t:
            names.append(e.name)
            n = e.name.rstrip("/")
            if n.startswith("/") or ".." in n.split("/"):
                errors.append(f"tar: unsafe path {e.name}")
                continue
            parts = n.split("/")
            if parts[0] != network or len(parts) < 2 or parts[1] not in TOP_DIRS:
                errors.append(f"tar: {e.name} is not under {network}/{{{','.join(TOP_DIRS)}}}")
            if not (e.isfile() or e.isdir()):
                errors.append(f"tar: {e.name} is neither a file nor a directory")
            if e.mtime != 0 or e.uid != 0 or e.gid != 0 or e.uname or e.gname:
                errors.append(f"tar: {e.name} has a non-fixed header (mtime {e.mtime}, owner {e.uid}:{e.gid} {e.uname}:{e.gname})")
            if LEFT_OUT.search(n) or n == f"{network}/yellowback/carriers.dat":
                errors.append(f"tar: {e.name} is a file the format leaves out")
            if flavour == "full" and n.startswith(f"{network}/blocks/insight-index"):
                errors.append(f"tar: {e.name}: insight-index is in the full-insight flavour only")
    if names != sorted(names, key=lambda s: s.rstrip("/").encode()):
        errors.append("tar: entries are not in bytewise name order")
    for d in ("blocks", "chainstate"):
        if f"{network}/{d}" not in {n.rstrip("/") for n in names}:
            errors.append(f"tar: no {network}/{d}/")


def verify(d):
    errors = []
    try:
        with open(os.path.join(d, "manifest.json"), encoding="utf-8") as f:
            raw = f.read()
        m = json.loads(raw)
    except (OSError, ValueError) as e:
        return [f"manifest.json: {e}"]
    if raw != canonical(m):
        errors.append("manifest.json is not canonical (sorted keys, 2-space indent, one trailing newline)")
    if m.get("format") != FORMAT:
        errors.append(f"manifest: format {m.get('format')!r}, expected {FORMAT}")
    missing = [k for k in STATEMENT_FIELDS[:3] + MANIFEST_FIELDS if k not in m]
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
    try:
        with open(os.path.join(d, "SHA256SUMS"), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        return errors + [f"SHA256SUMS: {e}"]
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
    present = sorted(n for n in os.listdir(d) if n != "SHA256SUMS")
    if listed != sorted(listed, key=str.encode):
        errors.append("SHA256SUMS: not sorted by name")
    if sorted(listed) != present:
        errors.append(f"SHA256SUMS lists {sorted(listed)}, the directory has {present}")
    # the tarball
    tp = os.path.join(d, m["tarball"])
    if os.path.isfile(tp):
        if sha256(tp) != m["sha256"]:
            errors.append("manifest: sha256 does not match the tarball")
        if os.path.getsize(tp) != m["bytes"]:
            errors.append("manifest: bytes does not match the tarball")
        check_tar(tp, m["network"], m["flavour"], errors)
    else:
        errors.append(f"{m['tarball']} is missing")
    # the statements: canonical, identical, the manifest's statement fields, one per verifier
    statements = sorted(n for n in present if n.startswith("statement-") and n.endswith(".json"))
    names = [n[len("statement-"):-len(".json")] for n in statements]
    if names != sorted(m["verifiers"]):
        errors.append(f"manifest: verifiers {m['verifiers']} but statements {names}")
    if len(statements) < 2:
        errors.append(f"{len(statements)} statement(s): at least 2 (plan §4.2)")
    first = None
    for n in statements:
        with open(os.path.join(d, n), encoding="utf-8") as f:
            raw = f.read()
        s = json.loads(raw)
        if raw != canonical(s):
            errors.append(f"{n} is not canonical")
        if not set(s) <= set(STATEMENT_FIELDS) or not {"network", "height", "blockhash"} <= set(s):
            errors.append(f"{n}: fields {sorted(s)}")
        if any(m.get(k) != v for k, v in s.items()):
            errors.append(f"{n} disagrees with the manifest")
        if first is None:
            first = raw
        elif raw != first:
            errors.append(f"{n} differs from {statements[0]}")
    return errors


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    errors = verify(sys.argv[1])
    for e in errors:
        print(f"verify: {e}", file=sys.stderr)
    if not errors:
        print(f"verify: {sys.argv[1]}: ok")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
