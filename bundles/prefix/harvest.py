#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Zcash-testnet prefix harvest for the Ycash testnet (prefix format v1, FORMAT.md).

Python 3 standard library only; run it as `python3 -I harvest.py <command>`.

Commands:
  tip        print the node's block height (getblockchaininfo .blocks)
  export     fetch blocks 0..LAST from a Zebra node into raw chunk streams (<name>.blocks)
  pack       verify the raw streams, gzip -n -9 each chunk, write manifest.json and SHA256SUMS
  verify     re-verify a finished directory offline, from its .blocks.gz files alone
  constants  print the pinned images and commits (for scripts)

What `verify` checks, for every block: the u32 length framing, the header (140 bytes,
compactsize, a 1,344-byte Equihash 200,9 solution), the SHA-256d hash against the target in
nBits, every transaction parsed to the block's last byte with the Merkle root recomputed,
`hashPrevBlock` against the previous block's hash from the genesis on, Zebra's source
checkpoints (the vendored test-checkpoints.txt, sha256-pinned), and Ycash's compiled testnet
checkpoints. For a finished directory also SHA256SUMS, every manifest field, and the per-chunk
raw/gz sizes and digests. The Equihash solution itself is not verified here: the node does
that on import.
"""

import argparse
import base64
import gzip
import hashlib
import http.client
import json
import os
import subprocess
import sys
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

# --- pins (one place; the Dockerfile, run-local.sh and the workflow read these) -------------

FORMAT = "ycash-prefix/1"
NETWORK = "zcash-testnet"
FILE_PREFIX = "zcash-testnet-prefix-v1"

# Zebra 7.0.0 (git tag v7.0.0 = e8db87eb69254e0d4eedd058eadd48bdfa09065a, the image's
# org.opencontainers.image.revision label); the multi-arch index digest on Docker Hub.
ZEBRA_IMAGE = "docker.io/zfnd/zebra:7.0.0@sha256:a70d2be8ffef3a4b6e37355724e36a0e6c1838e46baa28bfb216739f00cf2d34"
# The pack image's base: gzip and Python come from here (Debian trixie, Python 3.13.18).
PACK_IMAGE = "docker.io/library/python:3.13.18-slim-trixie@sha256:76baad6037690d6e8c4397fbcaef17bca6f19eecef822b708fe8fa3417d30bb5"
# zebra-chain/src/parameters/checkpoint/test-checkpoints.txt at this commit (Zebra v7.0.0),
# vendored as data/zebra-test-checkpoints.txt with this sha256.
ZEBRA_CHECKPOINTS_COMMIT = "e8db87eb69254e0d4eedd058eadd48bdfa09065a"
ZEBRA_CHECKPOINTS_SHA256 = "5d391844bbf7c67932125c9b0bdf0cef91b89460d13a3b8b6f7e3921cc9f5177"
ZEBRA_CHECKPOINTS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "zebra-test-checkpoints.txt")

# --- chain facts ------------------------------------------------------------------------------

PREFIX_LAST_HEIGHT = 510247          # the Ycash testnet forks at 510,248 (ycash6 src/chainparams.cpp:434)
SMOKE_LAST_HEIGHT = 4799
CHUNK_BLOCKS = 50000
HASH_EVERY = 10000
GENESIS_HASH = "05a60a92d99d85997cce3b87616c089f6124d7342af37106edc76126334a2c38"
# Ycash's compiled testnet pins below the fork, ycash6 upgrade/vault 1c10c93cc src/chainparams.cpp:
# the 38,000 checkpoint (:571) and the Overwinter / Sapling activation hashes (:428, :432).
YCASH_CHECKPOINTS = {
    38000: "001e9a2d2e2892b88e9998cf7b079b41d59dd085423a921fe8386cecc42287b8",
    207500: "0000257c4331b098045023fcfbfa2474681f4564ab483f84e4e1ad078e4acf44",
    280000: "000420e7fcc3a49d729479fb0b560dd7b8617b178a08e9e389620a9d1dd6361a",
}
HEADER_BYTES = 140
EQUIHASH_SOLUTION_BYTES = 1344       # Equihash (200, 9), all of Zcash testnet below the fork
MAX_BLOCK_BYTES = 2000000


class VerifyError(Exception):
    pass


# --- primitives -------------------------------------------------------------------------------

def sha256d(b):
    return hashlib.sha256(hashlib.sha256(b).digest()).digest()


def display(h):
    """Internal byte order -> the byte-reversed hex zcashd and Zebra display."""
    return h[::-1].hex()


def read_compactsize(b, off):
    if off >= len(b):
        raise VerifyError("truncated compactsize")
    n = b[off]
    if n < 0xfd:
        return n, off + 1
    width = {0xfd: 2, 0xfe: 4, 0xff: 8}[n]
    if off + 1 + width > len(b):
        raise VerifyError("truncated compactsize")
    v = int.from_bytes(b[off + 1:off + 1 + width], "little")
    if v < {2: 0xfd, 4: 0x10000, 8: 0x100000000}[width]:
        raise VerifyError("non-canonical compactsize")
    return v, off + 1 + width


def chunk_ranges(last_height):
    """Chunk k covers [50,000k, min(50,000k + 49,999, last)] (FORMAT.md)."""
    if last_height < 0:
        raise ValueError("last height must be >= 0")
    return [(f, min(f + CHUNK_BLOCKS - 1, last_height)) for f in range(0, last_height + 1, CHUNK_BLOCKS)]


def chunk_name(first, last, gz=True):
    return "%s-%07d-%07d.blocks%s" % (FILE_PREFIX, first, last, ".gz" if gz else "")


def hash_heights(last_height):
    hs = list(range(0, last_height + 1, HASH_EVERY))
    if hs[-1] != last_height:
        hs.append(last_height)
    return hs


def load_zebra_checkpoints(path=ZEBRA_CHECKPOINTS_FILE):
    with open(path, "rb") as f:
        data = f.read()
    got = hashlib.sha256(data).hexdigest()
    if got != ZEBRA_CHECKPOINTS_SHA256:
        raise VerifyError("%s: sha256 %s, pinned %s" % (path, got, ZEBRA_CHECKPOINTS_SHA256))
    cps = {}
    for line in data.decode("ascii").splitlines():
        if not line.strip():
            continue
        h, hx = line.split()
        cps[int(h)] = hx
    return cps


def all_checkpoints():
    """Zebra's source checkpoints and Ycash's compiled ones; a height both list must agree."""
    cps = {h: ("zebra", hx) for h, hx in load_zebra_checkpoints().items()}
    for h, hx in YCASH_CHECKPOINTS.items():
        if h in cps and cps[h][1] != hx:
            raise VerifyError("Zebra and Ycash disagree at %d" % h)
        cps[h] = ("zebra+ycash" if h in cps else "ycash", hx)
    cps.setdefault(0, ("genesis", GENESIS_HASH))
    return cps


# --- block parsing ----------------------------------------------------------------------------

def _skip(b, off, n):
    if off + n > len(b):
        raise VerifyError("truncated transaction")
    return off + n


def parse_tx(b, off):
    """Return the end offset of the v1..v4 transaction at `off` (Zcash protocol spec §7.1)."""
    start = off
    off = _skip(b, off, 4)
    header = int.from_bytes(b[start:start + 4], "little")
    overwintered = bool(header >> 31)
    version = header & 0x7FFFFFFF
    if overwintered:
        off = _skip(b, off, 4)                       # nVersionGroupId
        if version not in (3, 4):
            raise VerifyError("unsupported overwintered tx version %d" % version)
    elif version not in (1, 2):
        raise VerifyError("unsupported tx version %d" % version)
    n, off = read_compactsize(b, off)                # vin
    for _ in range(n):
        off = _skip(b, off, 36)
        s, off = read_compactsize(b, off)
        off = _skip(b, off, s + 4)
    n, off = read_compactsize(b, off)                # vout
    for _ in range(n):
        off = _skip(b, off, 8)
        s, off = read_compactsize(b, off)
        off = _skip(b, off, s)
    off = _skip(b, off, 4)                           # nLockTime
    if overwintered:
        off = _skip(b, off, 4)                       # nExpiryHeight
    n_spend = n_output = 0
    if overwintered and version == 4:
        off = _skip(b, off, 8)                       # valueBalance
        n_spend, off = read_compactsize(b, off)
        off = _skip(b, off, 384 * n_spend)
        n_output, off = read_compactsize(b, off)
        off = _skip(b, off, 948 * n_output)
    if version >= 2:
        n_js, off = read_compactsize(b, off)
        js_bytes = 304 + (192 if version >= 4 else 296) + 2 * 601
        off = _skip(b, off, js_bytes * n_js)
        if n_js:
            off = _skip(b, off, 32 + 64)             # joinSplitPubKey, joinSplitSig
    if overwintered and version == 4 and (n_spend or n_output):
        off = _skip(b, off, 64)                      # bindingSig
    return off


def merkle_root(txids):
    level = list(txids)
    while len(level) > 1:
        if len(level) % 2:
            level.append(level[-1])
        level = [sha256d(level[i] + level[i + 1]) for i in range(0, len(level), 2)]
    return level[0]


def parse_block(b):
    """Check one serialized block; return (hash, prev_hash), internal byte order."""
    if len(b) > MAX_BLOCK_BYTES:
        raise VerifyError("block of %d bytes exceeds %d" % (len(b), MAX_BLOCK_BYTES))
    if len(b) < HEADER_BYTES + 3:
        raise VerifyError("block of %d bytes is shorter than a header" % len(b))
    sol_len, off = read_compactsize(b, HEADER_BYTES)
    if sol_len != EQUIHASH_SOLUTION_BYTES:
        raise VerifyError("Equihash solution of %d bytes, expected %d" % (sol_len, EQUIHASH_SOLUTION_BYTES))
    off = _skip(b, off, sol_len)
    h = sha256d(b[:off])
    bits = int.from_bytes(b[104:108], "little")
    exp, mant = bits >> 24, bits & 0x007FFFFF
    if bits & 0x00800000 or mant == 0:
        raise VerifyError("invalid nBits %08x" % bits)
    target = mant >> (8 * (3 - exp)) if exp <= 3 else mant << (8 * (exp - 3))
    if int.from_bytes(h, "little") > target:
        raise VerifyError("hash %s above the nBits target" % display(h))
    n_tx, off = read_compactsize(b, off)
    if n_tx == 0:
        raise VerifyError("block with no transactions")
    txids = []
    for _ in range(n_tx):
        end = parse_tx(b, off)
        txids.append(sha256d(b[off:end]))
        off = end
    if off != len(b):
        raise VerifyError("%d trailing bytes after the last transaction" % (len(b) - off))
    if merkle_root(txids) != b[36:68]:
        raise VerifyError("Merkle root mismatch in block %s" % display(h))
    return h, b[4:36]


class ChainVerifier:
    """Feed blocks in height order; checks the hash chain and the checkpoints."""

    def __init__(self, first_height=0, prev_hash=None, checkpoints=None, hash_at=()):
        self.height = first_height
        self.prev = prev_hash if prev_hash is not None else (b"\0" * 32 if first_height == 0 else None)
        self.checkpoints = all_checkpoints() if checkpoints is None else checkpoints
        self.hash_at = set(hash_at)
        self.hashes = {}
        self.checked = []

    def add(self, block):
        try:
            h, prev = parse_block(block)
        except VerifyError as e:
            raise VerifyError("height %d: %s" % (self.height, e))
        if self.prev is not None and prev != self.prev:
            raise VerifyError("height %d: hashPrevBlock %s, previous block is %s" % (self.height, display(prev), display(self.prev)))
        hx = display(h)
        cp = self.checkpoints.get(self.height)
        if cp is not None:
            if hx != cp[1]:
                raise VerifyError("height %d: hash %s, %s checkpoint %s" % (self.height, hx, cp[0], cp[1]))
            self.checked.append(self.height)
        if self.height in self.hash_at:
            self.hashes[str(self.height)] = hx
        self.prev = h
        self.height += 1
        return hx


def iter_stream(f):
    """Yield the blocks of a raw block stream (u32 LE length, block bytes)."""
    while True:
        n = f.read(4)
        if not n:
            return
        if len(n) != 4:
            raise VerifyError("truncated length prefix")
        length = int.from_bytes(n, "little")
        if length > MAX_BLOCK_BYTES:
            raise VerifyError("length prefix %d exceeds %d" % (length, MAX_BLOCK_BYTES))
        b = f.read(length)
        if len(b) != length:
            raise VerifyError("truncated block")
        yield b


class _HashingReader:
    def __init__(self, f):
        self.f, self.sha, self.n = f, hashlib.sha256(), 0

    def read(self, n):
        b = self.f.read(n)
        self.sha.update(b)
        self.n += len(b)
        return b


def verify_chunks(open_chunk, last_height, log=print):
    """Verify every chunk 0..last in order. open_chunk(first, last) -> a binary file object.
    Returns (per-chunk [(blocks, raw_bytes, raw_sha256)], hashes, checked checkpoint heights)."""
    v = ChainVerifier(0, hash_at=hash_heights(last_height))
    stats = []
    for first, last in chunk_ranges(last_height):
        if v.height != first:
            raise VerifyError("chunk %d..%d starts after height %d" % (first, last, v.height))
        with open_chunk(first, last) as f:
            r = _HashingReader(f)
            count = 0
            for block in iter_stream(r):
                if v.height > last:
                    raise VerifyError("chunk %d..%d holds more than %d blocks" % (first, last, last - first + 1))
                v.add(block)
                count += 1
        if v.height != last + 1:
            raise VerifyError("chunk %d..%d ends at height %d" % (first, last, v.height - 1))
        stats.append((count, r.n, r.sha.hexdigest()))
        log("verified %s: %d blocks, %d raw bytes" % (chunk_name(first, last), count, r.n))
    expected_cps = sorted(h for h in v.checkpoints if h <= last_height)
    if v.checked != expected_cps:
        raise VerifyError("checkpoint coverage mismatch")
    log("hash chain from the genesis to %d: ok; %d checkpoints matched (Zebra source + Ycash compiled)"
        % (last_height, len(v.checked)))
    return stats, v.hashes, v.checked


# --- RPC --------------------------------------------------------------------------------------

class RPC:
    """JSON-RPC over HTTP, one persistent connection per thread, retries with backoff."""

    def __init__(self, url, cookie_file=None, user=None, password=None, retries=8, timeout=120):
        u = urllib.parse.urlsplit(url)
        if u.scheme != "http" or not u.hostname:
            raise ValueError("rpc url must be http://host:port")
        self.host, self.port = u.hostname, u.port or 18232
        self.path = u.path or "/"
        self.cookie_file, self.user, self.password = cookie_file, user, password
        self.retries, self.timeout = retries, timeout
        self.local = threading.local()
        self.ids = 0
        self.lock = threading.Lock()

    def _auth(self):
        cred = None
        if self.cookie_file:
            with open(self.cookie_file, encoding="ascii") as f:
                cred = f.read().strip()          # "__cookie__:<token>", re-read each time: a restart rotates it
        elif self.user is not None:
            cred = "%s:%s" % (self.user, self.password or "")
        return {"Authorization": "Basic " + base64.b64encode(cred.encode()).decode()} if cred else {}

    def _conn(self, fresh=False):
        c = getattr(self.local, "conn", None)
        if c is None or fresh:
            if c is not None:
                c.close()
            c = self.local.conn = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
        return c

    def call(self, method, *params):
        with self.lock:
            self.ids += 1
            rid = self.ids
        body = json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": list(params)})
        delay, last_err = 0.5, None
        for attempt in range(self.retries + 1):
            try:
                c = self._conn(fresh=attempt > 0)
                headers = {"Content-Type": "application/json"}
                headers.update(self._auth())
                c.request("POST", self.path, body=body, headers=headers)
                resp = c.getresponse()
                data = resp.read()
                if resp.status in (401, 403):
                    raise RuntimeError("%s: HTTP %d (RPC auth: pass --cookie-file or --rpc-user)" % (method, resp.status))
                if resp.status >= 500 and not data.strip().startswith(b"{"):
                    raise ConnectionError("HTTP %d" % resp.status)
                reply = json.loads(data)
                if reply.get("error"):
                    raise RuntimeError("%s%r: %s" % (method, params, reply["error"]))
                return reply["result"]
            except (OSError, http.client.HTTPException, ValueError) as e:
                last_err = e
                if attempt < self.retries:
                    time.sleep(delay)
                    delay = min(delay * 2, 30)
        raise ConnectionError("%s%r failed after %d attempts: %s" % (method, params, self.retries + 1, last_err))


def fetch_block(rpc, height):
    bh = rpc.call("getblockhash", height)
    raw = bytes.fromhex(rpc.call("getblock", bh, 0))
    got = display(parse_block(raw)[0])
    if got != bh:
        raise VerifyError("height %d: getblockhash %s, block hashes to %s" % (height, bh, got))
    return raw


def export(rpc, last_height, raw_dir, workers=4, window=512, log=print):
    os.makedirs(raw_dir, exist_ok=True)
    v = ChainVerifier(0)
    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for first, last in chunk_ranges(last_height):
            path = os.path.join(raw_dir, chunk_name(first, last, gz=False))
            tmp = path + ".part"
            n_bytes = 0
            with open(tmp, "wb") as out:
                for start in range(first, last + 1, window):
                    heights = range(start, min(start + window, last + 1))
                    for raw in pool.map(lambda h: fetch_block(rpc, h), heights):
                        v.add(raw)
                        out.write(len(raw).to_bytes(4, "little"))
                        out.write(raw)
                        n_bytes += 4 + len(raw)
                    if (start - first) % 10240 == 0:
                        log("export: height %d, %.0f s" % (start, time.monotonic() - t0))
            os.replace(tmp, path)
            log("export: wrote %s (%d bytes)" % (os.path.basename(path), n_bytes))
    log("export: %d blocks in %.0f s" % (last_height + 1, time.monotonic() - t0))


# --- pack and manifest ------------------------------------------------------------------------

def canonical_json(obj):
    return json.dumps(obj, sort_keys=True, indent=2, ensure_ascii=False) + "\n"


def file_sha256(path):
    h, n = hashlib.sha256(), 0
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
            n += len(b)
    return h.hexdigest(), n


def build_manifest(last_height, stats, gz_info, hashes):
    chunks = []
    for (first, last), (blocks, raw_bytes, raw_sha), (gz_sha, gz_bytes) in zip(chunk_ranges(last_height), stats, gz_info):
        chunks.append({"file": chunk_name(first, last), "first_height": first, "last_height": last,
                       "blocks": blocks, "raw_bytes": raw_bytes, "raw_sha256": raw_sha,
                       "gz_bytes": gz_bytes, "gz_sha256": gz_sha})
    return {"format": FORMAT, "network": NETWORK, "first_height": 0, "last_height": last_height,
            "chunks": chunks, "hashes": hashes,
            "sources": {"zebra_image": ZEBRA_IMAGE, "zebra_checkpoints_commit": ZEBRA_CHECKPOINTS_COMMIT,
                        "pack_image": PACK_IMAGE}}


def sha256sums_text(out_dir, names):
    return "".join("%s  %s\n" % (file_sha256(os.path.join(out_dir, n))[0], n) for n in sorted(names))


def pack(raw_dir, out_dir, last_height, log=print):
    stats, hashes, _ = verify_chunks(lambda first, last: open(os.path.join(raw_dir, chunk_name(first, last, gz=False)), "rb"),
                                     last_height, log)
    os.makedirs(out_dir, exist_ok=True)
    gz_info = []
    for first, last in chunk_ranges(last_height):
        src = os.path.join(raw_dir, chunk_name(first, last, gz=False))
        dst = os.path.join(out_dir, chunk_name(first, last))
        with open(src, "rb") as fi, open(dst + ".part", "wb") as fo:
            subprocess.run(["gzip", "-n", "-9"], stdin=fi, stdout=fo, check=True)
        os.replace(dst + ".part", dst)
        gz_info.append(file_sha256(dst))
        log("packed %s: %d bytes" % (os.path.basename(dst), gz_info[-1][1]))
    manifest = build_manifest(last_height, stats, gz_info, hashes)
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8", newline="\n") as f:
        f.write(canonical_json(manifest))
    names = [c["file"] for c in manifest["chunks"]] + ["manifest.json"]
    with open(os.path.join(out_dir, "SHA256SUMS"), "w", encoding="ascii", newline="\n") as f:
        f.write(sha256sums_text(out_dir, names))
    return manifest


def verify_dir(out_dir, log=print):
    """Offline re-verification of a finished directory, from the .gz files alone."""
    with open(os.path.join(out_dir, "SHA256SUMS"), encoding="ascii") as f:
        sums_text = f.read()
    sums = {}
    for line in sums_text.splitlines():
        digest, name = line.split("  ", 1)
        sums[name] = digest
    for name, digest in sums.items():
        if file_sha256(os.path.join(out_dir, name))[0] != digest:
            raise VerifyError("SHA256SUMS: %s does not match" % name)
    log("SHA256SUMS: %d files match" % len(sums))
    with open(os.path.join(out_dir, "manifest.json"), encoding="utf-8") as f:
        text = f.read()
    m = json.loads(text)
    if text != canonical_json(m):
        raise VerifyError("manifest.json is not in canonical form")
    last_height = m.get("last_height")
    if not isinstance(last_height, int) or not 0 <= last_height <= PREFIX_LAST_HEIGHT:
        raise VerifyError("manifest last_height %r out of range" % (last_height,))
    expected_names = [chunk_name(first, last) for first, last in chunk_ranges(last_height)]
    if sorted(sums) != sorted(expected_names + ["manifest.json"]):
        raise VerifyError("SHA256SUMS lists %s, expected %s" % (sorted(sums), sorted(expected_names + ["manifest.json"])))
    if sums_text != "".join("%s  %s\n" % (sums[n], n) for n in sorted(sums)):
        raise VerifyError("SHA256SUMS is not sorted by name")
    stats, hashes, _ = verify_chunks(lambda first, last: gzip.open(os.path.join(out_dir, chunk_name(first, last)), "rb"),
                                     last_height, log)
    gz_info = [file_sha256(os.path.join(out_dir, n)) for n in expected_names]
    want = build_manifest(last_height, stats, gz_info, hashes)
    if m != want:
        diff = sorted(k for k in set(m) | set(want) if m.get(k) != want.get(k))
        raise VerifyError("manifest.json differs from the recomputed one in: %s" % ", ".join(diff))
    log("manifest.json: every field matches the recomputed manifest")
    log("OK: %s %s heights 0..%d, %d chunks" % (m["format"], m["network"], last_height, len(expected_names)))
    return m


# --- CLI --------------------------------------------------------------------------------------

def _rpc_from_args(a):
    return RPC(a.rpc_url, cookie_file=a.cookie_file, user=a.rpc_user, password=os.environ.get("RPC_PASSWORD"))


def _height(s):
    h = int(s)
    if not 0 <= h <= PREFIX_LAST_HEIGHT:
        raise argparse.ArgumentTypeError("last height must be in 0..%d" % PREFIX_LAST_HEIGHT)
    return h


def main(argv=None):
    p = argparse.ArgumentParser(prog="harvest.py", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    def rpc_args(sp):
        sp.add_argument("--rpc-url", default="http://127.0.0.1:18232")
        sp.add_argument("--cookie-file", help="Zebra's .cookie (\"__cookie__:<token>\"); omit if cookie auth is off")
        sp.add_argument("--rpc-user", help="basic-auth user (password from $RPC_PASSWORD), instead of a cookie")

    sp = sub.add_parser("tip", help="print the node's height")
    rpc_args(sp)
    sp = sub.add_parser("export", help="fetch blocks 0..LAST into raw chunk streams")
    rpc_args(sp)
    sp.add_argument("--last-height", type=_height, default=PREFIX_LAST_HEIGHT)
    sp.add_argument("--raw-dir", required=True)
    sp.add_argument("--workers", type=int, default=4)
    sp = sub.add_parser("pack", help="verify raw streams, gzip, manifest.json, SHA256SUMS")
    sp.add_argument("--last-height", type=_height, default=PREFIX_LAST_HEIGHT)
    sp.add_argument("--raw-dir", required=True)
    sp.add_argument("--out-dir", required=True)
    sp = sub.add_parser("verify", help="re-verify a finished directory offline")
    sp.add_argument("dir")
    sp = sub.add_parser("constants", help="print the pins as shell assignments")
    a = p.parse_args(argv)

    try:
        if a.cmd == "tip":
            info = _rpc_from_args(a).call("getblockchaininfo")
            print(info["blocks"])
        elif a.cmd == "export":
            export(_rpc_from_args(a), a.last_height, a.raw_dir, workers=a.workers)
        elif a.cmd == "pack":
            pack(a.raw_dir, a.out_dir, a.last_height)
        elif a.cmd == "verify":
            verify_dir(a.dir)
        elif a.cmd == "constants":
            for k, v in (("ZEBRA_IMAGE", ZEBRA_IMAGE), ("PACK_IMAGE", PACK_IMAGE),
                         ("ZEBRA_CHECKPOINTS_COMMIT", ZEBRA_CHECKPOINTS_COMMIT),
                         ("PREFIX_LAST_HEIGHT", PREFIX_LAST_HEIGHT), ("SMOKE_LAST_HEIGHT", SMOKE_LAST_HEIGHT)):
                print("%s=%s" % (k, v))
    except (VerifyError, OSError, ValueError, KeyError, RuntimeError) as e:
        print("FAILED: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
