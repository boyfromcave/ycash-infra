#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Prefix harvest (prefix format v1, FORMAT.md): Zcash-testnet history for the Ycash testnet,
and Ycash-mainnet history for the shadow-fork testnets and the mainnet bootstrap bundle.

Python 3 standard library only; run it as `python3 -I harvest.py <command>`.

Commands:
  tip          print the node's block height (getblockchaininfo .blocks)
  chaininfo    print "<blocks> <headers> <ibd-complete 0|1>" from getblockchaininfo (for scripts)
  split-height the split height H_S: the default rule from a tip, or check a chosen one
  export       fetch blocks 0..LAST from a node into raw chunk streams (<name>.blocks)
  pack         verify the raw streams, gzip -n -9 each chunk, write manifest.json and SHA256SUMS
  verify       re-verify a finished directory offline, from its .blocks.gz files alone
  main-checkpoints  extract Ycash's compiled mainnet checkpoints from a chainparams.cpp (the
               vendored data/ycash-main-checkpoints.txt is this command's output at a pinned commit)
  constants    print the pinned images and commits (for scripts)

`--network` picks the history: `zcash-testnet` (the default, Zebra) or `ycash-mainnet` (ycashd).

What `verify` checks, for every block: the u32 length framing, the header (140 bytes,
compactsize, an Equihash solution of the size the height requires: 1,344 bytes for (200, 9),
400 bytes for Ycash's (192, 7) from the Ycash fork at mainnet 570,000), the SHA-256d hash
against the target in nBits, every transaction parsed to the block's last byte with the Merkle
root recomputed, `hashPrevBlock` against the previous block's hash from the genesis on, and the
network's checkpoint set: for zcash-testnet Zebra's source checkpoints (the vendored
test-checkpoints.txt) and Ycash's compiled testnet pins; for ycash-mainnet Ycash's compiled
mainnet checkpoints (the vendored ycash-main-checkpoints.txt) and the Overwinter, Sapling and
Ycash-fork activation hashes. Both vendored lists are sha256-pinned. For a finished directory also
SHA256SUMS, every manifest field, and the per-chunk raw/gz sizes and digests. The Equihash
solution itself is not verified here: the node does that on import.
"""

import argparse
import base64
import copy
import gzip
import hashlib
import http.client
import json
import os
import re
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

# Ycash mainnet (network "ycash-mainnet"). The exporting node: the ycashd image node-image.yml built
# from ycash6 upgrade/vault 71e74a9efc81 (ghcr.io, public). Any honest ycashd returns the same block
# bytes; the pin keeps the manifest a function of this commit, so reruns compare equal.
YCASHD_IMAGE = "ghcr.io/boyfromcave/ycashd:ycash6-71e74a9efc81@sha256:78f4a969c8bcffcf69a80da26c19a6b01c5932736f471a76fc3ee4c4c236c9b6"
# CMainParams checkpointData in boyfromcave/ycash6 src/chainparams.cpp at this commit (upgrade/vault,
# lines 251-279; ycash-dd upgrade/vault fec0be1d1 lines 238-261 carry the same 18 entries), vendored
# as data/ycash-main-checkpoints.txt (`main-checkpoints` output) with this sha256.
YCASH_CHECKPOINTS_COMMIT = "71e74a9efc8118ab72ad9b526e09b454f4e79b64"
YCASH_MAIN_CHECKPOINTS_SHA256 = "7ddc3bb48ec9ac6ff56e1bc5b18926584479d07a1faa128a5a35377b58a5c44f"
YCASH_MAIN_CHECKPOINTS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "ycash-main-checkpoints.txt")

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
# GitHub release assets must be under 2 GiB; pack refuses a bigger chunk file on every network.
MAX_CHUNK_GZ_BYTES = 2 ** 31 - 1

# Ycash mainnet. The genesis is Zcash's (ycash6 src/chainparams.cpp:236); the Ycash fork is at
# 570,000 (:130-132), where Equihash moves from (200, 9) to (192, 7) (src/consensus/upgrades.cpp:42-43:
# a 400-byte solution, 2^7 indices of 192/(7+1)+1 = 25 bits).
MAINNET_NAME = "ycash-mainnet"
TREESTATE_FILE = "treestate.json"   # ycash-mainnet: z_gettreestate at the last height, beside the chunks
MAINNET_GENESIS_HASH = "00040fe8ec8471911baa1db1266ea15dd06b4a8a5c453883c000b031973dce08"
MAINNET_MAGIC = "24e92764"           # pchMessageStart, ycash6 src/chainparams.cpp:223-226 (import framing)
YCASH_FORK_HEIGHT = 570000
YCASH_EQUIHASH_SOLUTION_BYTES = 400  # Equihash (192, 7)
# The compiled activation hashes below any split height (ycash6 upgrade/vault src/chainparams.cpp
# :123-124 Overwinter, :127-128 Sapling, :131-132 the Ycash fork block, UPGRADE_YCASH hashActivationBlock).
YCASH_MAIN_ACTIVATIONS = {
    347500: "0000000003761c0d0c3974b54bdb425613bbb1eaadd6e70b764de82f195ea243",
    419200: "00000000025a57200d898ac7f21e26bf29028bbe96ec46e05b2c17cc9db9e4f3",
    570000: "0000014fbc5917ba8bcacf3336faf588d86b32443aa3a490a587af5750c77ec5",
}
# The default split height: the most recent height of the form k*SPLIT_STEP - 1 at least
# SPLIT_MIN_DEPTH blocks below the synced tip, so every chunk holds exactly 10,000 blocks and the
# block after the split is a round k*10,000
# below the synced tip (testnet plan Revision 4, N3-S).
SPLIT_STEP = 10000
SPLIT_MIN_DEPTH = 1000


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


def chunk_ranges(last_height, net=None):
    """Chunk k covers [S*k, min(S*k + S - 1, last)], S the network's chunk span (FORMAT.md):
    50,000 blocks on zcash-testnet, 10,000 on ycash-mainnet."""
    span = (net or TESTNET).chunk_blocks
    if last_height < 0:
        raise ValueError("last height must be >= 0")
    return [(f, min(f + span - 1, last_height)) for f in range(0, last_height + 1, span)]


def chunk_name(first, last, gz=True, net=None):
    return "%s-%07d-%07d.blocks%s" % ((net or TESTNET).file_prefix, first, last, ".gz" if gz else "")


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


def load_main_checkpoints(path=YCASH_MAIN_CHECKPOINTS_FILE):
    """The vendored Ycash mainnet checkpoint list ("<height> <hash>" lines), sha256-pinned."""
    with open(path, "rb") as f:
        data = f.read()
    got = hashlib.sha256(data).hexdigest()
    if got != YCASH_MAIN_CHECKPOINTS_SHA256:
        raise VerifyError("%s: sha256 %s, pinned %s" % (path, got, YCASH_MAIN_CHECKPOINTS_SHA256))
    cps = {}
    for line in data.decode("ascii").splitlines():
        h, hx = line.split()
        cps[int(h)] = hx
    return cps


def main_checkpoints():
    """Ycash's compiled mainnet checkpoints and activation hashes; a height both list must agree."""
    cps = {h: ("ycash checkpoint", hx) for h, hx in load_main_checkpoints().items()}
    for h, hx in YCASH_MAIN_ACTIVATIONS.items():
        if h in cps and cps[h][1] != hx:
            raise VerifyError("checkpoint and activation hash disagree at %d" % h)
        cps[h] = ("ycash activation" if h not in cps else "ycash checkpoint+activation", hx)
    if cps.get(0, (None, MAINNET_GENESIS_HASH))[1] != MAINNET_GENESIS_HASH:
        raise VerifyError("the checkpoint list's genesis is not the mainnet genesis")
    cps[0] = ("genesis", MAINNET_GENESIS_HASH)
    return cps


_CHECKPOINT_ENTRY = re.compile(r'\(\s*(\d+)\s*,\s*(?:consensus\.hashGenesisBlock|uint256S\("0x([0-9a-f]{64})"\))\s*\)')
_ACTIVATION = re.compile(r'vUpgrades\[Consensus::(UPGRADE_[A-Z0-9_]+)\]\.nActivationHeight\s*=\s*(\d+)\s*;'
                         r'\s*consensus\.vUpgrades\[Consensus::\1\]\.hashActivationBlock\s*=\s*uint256S\("(?:0x)?([0-9a-f]{64})"\)')


def extract_main_checkpoints(chainparams_text):
    """From a node's src/chainparams.cpp: CMainParams' checkpointData as {height: hash} (the genesis
    entry resolved through the class's `assert(consensus.hashGenesisBlock == ...)`), and its
    activation hashes as {name: (height, hash)}. `//` comments are dropped first, so a
    commented-out entry never counts."""
    m = re.search(r"\nclass CMainParams\b(.*?)\nclass ", chainparams_text, re.S)
    if not m:
        raise VerifyError("no CMainParams class")
    body = re.sub(r"//[^\n]*", "", m.group(1))
    g = re.search(r'assert\(consensus\.hashGenesisBlock\s*==\s*uint256S\("0x([0-9a-f]{64})"\)\)', body)
    cd = re.search(r"checkpointData\s*=\s*\(CCheckpointData\)\s*\{(.*?)\};", body, re.S)
    if not g or not cd:
        raise VerifyError("CMainParams lacks the genesis assert or checkpointData")
    cps = {}
    for h, hx in _CHECKPOINT_ENTRY.findall(cd.group(1)):
        if int(h) in cps:
            raise VerifyError("checkpoint %s listed twice" % h)
        cps[int(h)] = hx or g.group(1)
    if cps.get(0) != g.group(1):
        raise VerifyError("checkpointData does not start at the genesis")
    acts = {name: (int(h), hx) for name, h, hx in _ACTIVATION.findall(body)}
    return cps, acts


def checkpoints_text(cps):
    return "".join("%d %s\n" % (h, cps[h]) for h in sorted(cps))


# --- networks ---------------------------------------------------------------------------------

class Network:
    """What differs between the two histories the format carries (FORMAT.md, "Networks")."""

    def __init__(self, name, file_prefix, chunk_blocks, genesis, max_last_height, smoke_last_height,
                 solution_switch_height, solution_bytes_after, load_checkpoints, sources, rpc_port):
        self.name, self.file_prefix, self.chunk_blocks, self.genesis = name, file_prefix, chunk_blocks, genesis
        self.max_last_height, self.smoke_last_height = max_last_height, smoke_last_height
        self.solution_switch_height, self.solution_bytes_after = solution_switch_height, solution_bytes_after
        self._load_checkpoints, self.sources, self.rpc_port = load_checkpoints, sources, rpc_port
        self._checkpoints = None

    def solution_bytes(self, height):
        if self.solution_switch_height is not None and height >= self.solution_switch_height:
            return self.solution_bytes_after
        return EQUIHASH_SOLUTION_BYTES

    def checkpoints(self):
        if self._checkpoints is None:
            self._checkpoints = self._load_checkpoints()
        return self._checkpoints

    def derive(self, **kw):
        """A copy with some fields replaced (tests: a scaled-down mainnet). `checkpoints=` takes a dict."""
        n = copy.copy(self)
        cps = kw.pop("checkpoints", None)
        for k, v in kw.items():
            if not hasattr(n, k):
                raise AttributeError(k)
            setattr(n, k, v)
        n._checkpoints = cps
        if cps is not None:
            n._load_checkpoints = lambda: cps
        return n


TESTNET = Network(
    NETWORK, FILE_PREFIX, CHUNK_BLOCKS, GENESIS_HASH, PREFIX_LAST_HEIGHT, SMOKE_LAST_HEIGHT,
    None, None, all_checkpoints,
    {"zebra_image": ZEBRA_IMAGE, "zebra_checkpoints_commit": ZEBRA_CHECKPOINTS_COMMIT, "pack_image": PACK_IMAGE},
    18232)
# ycash-mainnet: 10,000-block chunks, so each chunk file stays far under GitHub's 2 GiB asset limit
# (it would need a 215 KB average block over 10,000 blocks; pack refuses one anyway).
MAINNET = Network(
    MAINNET_NAME, "ycash-mainnet-prefix-v1", 10000, MAINNET_GENESIS_HASH, None, 20000,
    YCASH_FORK_HEIGHT, YCASH_EQUIHASH_SOLUTION_BYTES, main_checkpoints,
    {"ycashd_image": YCASHD_IMAGE, "ycash_checkpoints_commit": YCASH_CHECKPOINTS_COMMIT, "pack_image": PACK_IMAGE},
    8832)
NETWORKS = {n.name: n for n in (TESTNET, MAINNET)}


def default_split_height(tip, min_depth=SPLIT_MIN_DEPTH, step=SPLIT_STEP):
    """The most recent height of the form k*`step` - 1 (k >= 1) at least `min_depth` blocks below
    `tip`: 3,089,999 for a tip of 3,091,234. Chunks of `step` blocks then all come out full."""
    hs = (tip - min_depth + 1) // step * step - 1
    if hs < 0:
        raise ValueError("tip %d is too low: no height k*%d - 1 is %d blocks below it" % (tip, step, min_depth))
    return hs


def check_split_height(hs, tip, min_depth=SPLIT_MIN_DEPTH):
    if hs < 0 or tip - hs < min_depth:
        raise ValueError("split height %d is not at least %d blocks below the tip %d" % (hs, min_depth, tip))
    return hs


CROSSCHECK_EVERY = 100000


def crosscheck_heights(last_height, net=None):
    """ycash-mainnet: the heights a second, independent node must confirm. Blocks above the newest
    compiled checkpoint are trusted only to the node that served them, so: every multiple of
    100,000 strictly between that checkpoint and the last height, and the last height itself.
    None on zcash-testnet (its prefix is below Zebra's and Ycash's checkpoints)."""
    net = net or TESTNET
    if net.name != MAINNET_NAME:
        return []
    top = max(net.checkpoints())
    if last_height <= top:
        return []
    first = (top // CROSSCHECK_EVERY + 1) * CROSSCHECK_EVERY
    return list(range(first, last_height, CROSSCHECK_EVERY)) + [last_height]


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


def parse_block(b, solution_bytes=EQUIHASH_SOLUTION_BYTES):
    """Check one serialized block; return (hash, prev_hash), internal byte order."""
    return parse_block_info(b, solution_bytes)[:2]


def parse_block_info(b, solution_bytes=EQUIHASH_SOLUTION_BYTES):
    """parse_block, plus the transaction count: (hash, prev_hash, n_tx)."""
    if len(b) > MAX_BLOCK_BYTES:
        raise VerifyError("block of %d bytes exceeds %d" % (len(b), MAX_BLOCK_BYTES))
    if len(b) < HEADER_BYTES + 3:
        raise VerifyError("block of %d bytes is shorter than a header" % len(b))
    sol_len, off = read_compactsize(b, HEADER_BYTES)
    if sol_len != solution_bytes:
        raise VerifyError("Equihash solution of %d bytes, expected %d" % (sol_len, solution_bytes))
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
    return h, b[4:36], n_tx


def block_time(b):
    """nTime from a serialized header (version 4, prev 32, merkle 32, reserved 32, then time)."""
    return int.from_bytes(b[100:104], "little")


class ChainVerifier:
    """Feed blocks in height order; checks the hash chain and the checkpoints."""

    def __init__(self, first_height=0, prev_hash=None, checkpoints=None, hash_at=(), net=None):
        self.net = net or TESTNET
        self.height = first_height
        self.prev = prev_hash if prev_hash is not None else (b"\0" * 32 if first_height == 0 else None)
        self.checkpoints = self.net.checkpoints() if checkpoints is None else checkpoints
        self.hash_at = set(hash_at)
        self.hashes = {}
        self.checked = []
        self.chaintx = 0       # transactions in blocks first_height..height-1
        self.last_time = None  # nTime of the last block added

    def add(self, block):
        try:
            h, prev, n_tx = parse_block_info(block, self.net.solution_bytes(self.height))
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
        self.chaintx += n_tx
        self.last_time = block_time(block)
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


def verify_chunks(open_chunk, last_height, log=print, net=None, info=None):
    """Verify every chunk 0..last in order. open_chunk(first, last) -> a binary file object.
    Returns (per-chunk [(blocks, raw_bytes, raw_sha256)], hashes, checked checkpoint heights).
    `info`, a dict, receives the last block's hash, time and the chain's transaction count
    ("split") and the hashes at the cross-check heights ("crosscheck_hashes")."""
    net = net or TESTNET
    xh = crosscheck_heights(last_height, net)
    v = ChainVerifier(0, hash_at=set(hash_heights(last_height)) | set(xh), net=net)
    stats = []
    for first, last in chunk_ranges(last_height, net):
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
        log("verified %s: %d blocks, %d raw bytes" % (chunk_name(first, last, net=net), count, r.n))
    expected_cps = sorted(h for h in v.checkpoints if h <= last_height)
    if v.checked != expected_cps:
        raise VerifyError("checkpoint coverage mismatch")
    if info is not None:
        info["split"] = {"height": last_height, "hash": display(v.prev), "time": v.last_time, "chaintx": v.chaintx}
        info["crosscheck_hashes"] = {str(h): v.hashes[str(h)] for h in xh}
    keep = set(map(str, hash_heights(last_height)))
    hashes = {k: x for k, x in v.hashes.items() if k in keep}
    log("%s: hash chain from the genesis to %d: ok; %d checkpoints matched (%s)"
        % (net.name, last_height, len(v.checked),
           "Zebra source + Ycash compiled" if net.name == NETWORK else "Ycash compiled checkpoints + activation hashes"))
    return stats, hashes, v.checked


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


def fetch_block(rpc, height, net=None):
    bh = rpc.call("getblockhash", height)
    raw = bytes.fromhex(rpc.call("getblock", bh, 0))
    got = display(parse_block(raw, (net or TESTNET).solution_bytes(height))[0])
    if got != bh:
        raise VerifyError("height %d: getblockhash %s, block hashes to %s" % (height, bh, got))
    return raw


def export(rpc, last_height, raw_dir, workers=4, window=512, log=print, net=None):
    net = net or TESTNET
    os.makedirs(raw_dir, exist_ok=True)
    v = ChainVerifier(0, net=net)
    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for first, last in chunk_ranges(last_height, net):
            path = os.path.join(raw_dir, chunk_name(first, last, gz=False, net=net))
            tmp = path + ".part"
            n_bytes = 0
            with open(tmp, "wb") as out:
                for start in range(first, last + 1, window):
                    heights = range(start, min(start + window, last + 1))
                    for raw in pool.map(lambda h: fetch_block(rpc, h, net), heights):
                        v.add(raw)
                        out.write(len(raw).to_bytes(4, "little"))
                        out.write(raw)
                        n_bytes += 4 + len(raw)
                    if (start - first) % 10240 == 0 or (start - first) % net.chunk_blocks == 0:
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


def build_manifest(last_height, stats, gz_info, hashes, net=None, extra=None):
    net = net or TESTNET
    chunks = []
    for (first, last), (blocks, raw_bytes, raw_sha), (gz_sha, gz_bytes) in zip(chunk_ranges(last_height, net), stats, gz_info):
        chunks.append({"file": chunk_name(first, last, net=net), "first_height": first, "last_height": last,
                       "blocks": blocks, "raw_bytes": raw_bytes, "raw_sha256": raw_sha,
                       "gz_bytes": gz_bytes, "gz_sha256": gz_sha})
    return {"format": FORMAT, "network": net.name, "first_height": 0, "last_height": last_height,
            "chunks": chunks, "hashes": hashes, "sources": dict(net.sources), **(extra or {})}


def check_treestate(ts, split):
    """The z_gettreestate answer must be for the last block: same height, hash and time."""
    if not isinstance(ts, dict):
        raise VerifyError("%s is not a JSON object" % TREESTATE_FILE)
    for k in ("height", "hash", "time"):
        if ts.get(k) != split[k]:
            raise VerifyError("%s: %s %r, the last block's is %r" % (TREESTATE_FILE, k, ts.get(k), split[k]))
    if not isinstance(ts.get("sapling"), dict) or not isinstance(ts.get("sprout"), dict):
        raise VerifyError("%s lacks the sprout or sapling tree state" % TREESTATE_FILE)


def mainnet_extra(info, crosscheck, treestate_text):
    """The ycash-mainnet manifest fields (FORMAT.md): split, crosscheck, treestate. `crosscheck` maps
    "<height>" to the hash a second, independent node returned; each must equal the chain's."""
    want = info["crosscheck_hashes"]
    crosscheck = {str(k): v for k, v in (crosscheck or {}).items()}
    if sorted(crosscheck, key=int) != sorted(want, key=int):
        raise VerifyError("cross-check heights %s, required %s" % (sorted(crosscheck, key=int), sorted(want, key=int)))
    for h, hx in want.items():
        if crosscheck[h] != hx:
            raise VerifyError("height %s: the cross-check node has %s, the harvested chain %s" % (h, crosscheck[h], hx))
    try:
        ts = json.loads(treestate_text)
    except ValueError as e:
        raise VerifyError("%s is not JSON: %s" % (TREESTATE_FILE, e))
    if treestate_text != canonical_json(ts):
        raise VerifyError("%s is not in canonical form" % TREESTATE_FILE)
    check_treestate(ts, info["split"])
    return {"split": info["split"], "crosscheck": dict(want),
            "treestate": {"file": TREESTATE_FILE, "sha256": hashlib.sha256(treestate_text.encode("utf-8")).hexdigest()}}


def sha256sums_text(out_dir, names):
    return "".join("%s  %s\n" % (file_sha256(os.path.join(out_dir, n))[0], n) for n in sorted(names))


def _gzip_chunk(src, dst, remove_raw):
    with open(src, "rb") as fi, open(dst + ".part", "wb") as fo:
        subprocess.run(["gzip", "-n", "-9"], stdin=fi, stdout=fo, check=True)
    os.replace(dst + ".part", dst)
    if remove_raw:
        os.remove(src)
    return file_sha256(dst)


def pack(raw_dir, out_dir, last_height, log=print, net=None, jobs=1, remove_raw=False,
         crosscheck=None, treestate=None):
    """Verify the raw streams, then gzip each chunk (`jobs` at a time: each chunk is compressed on
    its own, so the bytes do not depend on `jobs`), then write manifest.json and SHA256SUMS.
    remove_raw deletes each raw stream once its .gz is written (a mainnet disk saver).
    ycash-mainnet also takes `crosscheck` ({height: hash} from a second node) and `treestate`
    (the node's z_gettreestate answer at the last height, a dict), checked before anything is written."""
    net = net or TESTNET
    info = {}
    stats, hashes, _ = verify_chunks(lambda first, last: open(os.path.join(raw_dir, chunk_name(first, last, gz=False, net=net)), "rb"),
                                     last_height, log, net, info)
    extra, ts_text = None, None
    if net.name == MAINNET_NAME:
        if treestate is None:
            raise VerifyError("ycash-mainnet: the tree state at the last height is required (--treestate)")
        ts_text = canonical_json(treestate)
        extra = mainnet_extra(info, crosscheck, ts_text)
        log("cross-check: %d heights agree with the second node; tree state at %d" % (len(extra["crosscheck"]), last_height))
    os.makedirs(out_dir, exist_ok=True)
    ranges = chunk_ranges(last_height, net)
    with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        futs = [pool.submit(_gzip_chunk, os.path.join(raw_dir, chunk_name(f, l, gz=False, net=net)),
                            os.path.join(out_dir, chunk_name(f, l, net=net)), remove_raw) for f, l in ranges]
        gz_info = []
        for (f, l), fut in zip(ranges, futs):
            gz_info.append(fut.result())
            log("packed %s: %d bytes" % (chunk_name(f, l, net=net), gz_info[-1][1]))
    for (f, l), (_, size) in zip(ranges, gz_info):
        if size > MAX_CHUNK_GZ_BYTES:
            raise VerifyError("%s is %d bytes, over the %d-byte release asset limit"
                              % (chunk_name(f, l, net=net), size, MAX_CHUNK_GZ_BYTES))
    manifest = build_manifest(last_height, stats, gz_info, hashes, net, extra)
    names = [c["file"] for c in manifest["chunks"]] + ["manifest.json"]
    if ts_text is not None:
        with open(os.path.join(out_dir, TREESTATE_FILE), "w", encoding="utf-8", newline="\n") as f:
            f.write(ts_text)
        names.append(TREESTATE_FILE)
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8", newline="\n") as f:
        f.write(canonical_json(manifest))
    with open(os.path.join(out_dir, "SHA256SUMS"), "w", encoding="ascii", newline="\n") as f:
        f.write(sha256sums_text(out_dir, names))
    return manifest


def verify_dir(out_dir, log=print, net=None):
    """Offline re-verification of a finished directory, from the .gz files alone. The network is
    the manifest's; `net`, when given, must carry the same name (tests pass a scaled-down one)."""
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
    name = m.get("network")
    if net is None:
        if name not in NETWORKS:
            raise VerifyError("manifest network %r is not one of %s" % (name, sorted(NETWORKS)))
        net = NETWORKS[name]
    elif name != net.name:
        raise VerifyError("manifest network %r, expected %r" % (name, net.name))
    last_height = m.get("last_height")
    top = net.max_last_height
    if not isinstance(last_height, int) or last_height < 0 or (top is not None and last_height > top):
        raise VerifyError("manifest last_height %r out of range" % (last_height,))
    expected_names = [chunk_name(first, last, net=net) for first, last in chunk_ranges(last_height, net)]
    listed = expected_names + ["manifest.json"] + ([TREESTATE_FILE] if net.name == MAINNET_NAME else [])
    if sorted(sums) != sorted(listed):
        raise VerifyError("SHA256SUMS lists %s, expected %s" % (sorted(sums), sorted(listed)))
    if sums_text != "".join("%s  %s\n" % (sums[n], n) for n in sorted(sums)):
        raise VerifyError("SHA256SUMS is not sorted by name")
    info = {}
    stats, hashes, _ = verify_chunks(lambda first, last: gzip.open(os.path.join(out_dir, chunk_name(first, last, net=net)), "rb"),
                                     last_height, log, net, info)
    extra = None
    if net.name == MAINNET_NAME:
        with open(os.path.join(out_dir, TREESTATE_FILE), encoding="utf-8") as f:
            extra = mainnet_extra(info, m.get("crosscheck"), f.read())
        log("split %d: hash %s, time %d, chaintx %d; %d cross-check heights; %s matches the last block"
            % (last_height, info["split"]["hash"], info["split"]["time"], info["split"]["chaintx"],
               len(extra["crosscheck"]), TREESTATE_FILE))
    gz_info = [file_sha256(os.path.join(out_dir, n)) for n in expected_names]
    for n, (_, size) in zip(expected_names, gz_info):
        if size > MAX_CHUNK_GZ_BYTES:
            raise VerifyError("%s is %d bytes, over the release asset limit" % (n, size))
    want = build_manifest(last_height, stats, gz_info, hashes, net, extra)
    if m != want:
        diff = sorted(k for k in set(m) | set(want) if m.get(k) != want.get(k))
        raise VerifyError("manifest.json differs from the recomputed one in: %s" % ", ".join(diff))
    log("manifest.json: every field matches the recomputed manifest")
    log("OK: %s %s heights 0..%d, %d chunks" % (m["format"], m["network"], last_height, len(expected_names)))
    return m


# --- CLI --------------------------------------------------------------------------------------

def _rpc_from_args(a):
    url = a.rpc_url or "http://127.0.0.1:%d" % NETWORKS[a.network].rpc_port
    return RPC(url, cookie_file=a.cookie_file, user=a.rpc_user, password=os.environ.get("RPC_PASSWORD"))


def _uint(s):
    h = int(s)
    if h < 0:
        raise argparse.ArgumentTypeError("must be >= 0")
    return h


def _check_height(net, h):
    if net.max_last_height is not None and h > net.max_last_height:
        raise ValueError("%s: last height must be in 0..%d" % (net.name, net.max_last_height))
    return h


def main(argv=None):
    p = argparse.ArgumentParser(prog="harvest.py", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    def net_arg(sp):
        sp.add_argument("--network", choices=sorted(NETWORKS), default=NETWORK)

    def rpc_args(sp):
        net_arg(sp)
        sp.add_argument("--rpc-url", help="http://host:port (default: 127.0.0.1 and the network's RPC port)")
        sp.add_argument("--cookie-file", help="the node's .cookie (\"__cookie__:<token>\"); omit if cookie auth is off")
        sp.add_argument("--rpc-user", help="basic-auth user (password from $RPC_PASSWORD), instead of a cookie")

    sp = sub.add_parser("tip", help="print the node's height")
    rpc_args(sp)
    sp = sub.add_parser("chaininfo", help='print "<blocks> <headers> <ibd-complete 0|1>"')
    rpc_args(sp)
    sp = sub.add_parser("split-height", help="the default split height from a tip, or check a chosen one")
    sp.add_argument("--tip", type=_uint, required=True)
    sp.add_argument("--height", type=_uint, help="a chosen split height to check instead")
    sp.add_argument("--min-depth", type=_uint, default=SPLIT_MIN_DEPTH)
    sp.add_argument("--step", type=_uint, default=SPLIT_STEP)
    sp = sub.add_parser("export", help="fetch blocks 0..LAST into raw chunk streams")
    rpc_args(sp)
    sp.add_argument("--last-height", type=_uint)
    sp.add_argument("--raw-dir", required=True)
    sp.add_argument("--workers", type=int, default=4)
    sp = sub.add_parser("pack", help="verify raw streams, gzip, manifest.json, SHA256SUMS")
    net_arg(sp)
    sp.add_argument("--last-height", type=_uint)
    sp.add_argument("--raw-dir", required=True)
    sp.add_argument("--out-dir", required=True)
    sp.add_argument("--jobs", type=int, default=1, help="chunks compressed at once (the bytes do not depend on it)")
    sp.add_argument("--remove-raw", action="store_true", help="delete each raw stream once its .gz is written")
    sp.add_argument("--crosscheck", help="ycash-mainnet: the `crosscheck` command's JSON from a second node")
    sp.add_argument("--treestate", help="ycash-mainnet: the `treestate` command's JSON (z_gettreestate at the last height)")
    sp = sub.add_parser("treestate", help="ycash-mainnet: write z_gettreestate at the last height as canonical JSON")
    rpc_args(sp)
    sp.add_argument("--last-height", type=_uint, required=True)
    sp.add_argument("--out", required=True)
    sp = sub.add_parser("crosscheck", help="ycash-mainnet: ask a second, independent node for the cross-check hashes")
    rpc_args(sp)
    sp.add_argument("--last-height", type=_uint, required=True)
    sp.add_argument("--out", required=True)
    sp.add_argument("--compare-treestate", help="also require this node's z_gettreestate to equal this file")
    sp = sub.add_parser("verify", help="re-verify a finished directory offline")
    sp.add_argument("dir")
    sp = sub.add_parser("main-checkpoints", help="print CMainParams' checkpoints from a chainparams.cpp")
    sp.add_argument("--chainparams", required=True, help="path to src/chainparams.cpp, or - for stdin")
    sp.add_argument("--check", action="store_true",
                    help="compare with the vendored list (bytes and sha256) and the activation hashes; exit 1 on a difference")
    sp = sub.add_parser("constants", help="print the pins as shell assignments")
    net_arg(sp)
    a = p.parse_args(argv)

    try:
        if a.cmd in ("export", "pack"):
            net = NETWORKS[a.network]
            a.last_height = _check_height(net, a.last_height if a.last_height is not None else
                                          (net.max_last_height if net.max_last_height is not None else -1))
            if a.last_height < 0:
                raise ValueError("%s: --last-height is required (the split height)" % net.name)
        if a.cmd == "tip":
            info = _rpc_from_args(a).call("getblockchaininfo")
            print(info["blocks"])
        elif a.cmd == "chaininfo":
            info = _rpc_from_args(a).call("getblockchaininfo")
            print(int(info["blocks"]), int(info.get("headers", info["blocks"])),
                  1 if info.get("initial_block_download_complete") else 0)
        elif a.cmd == "split-height":
            if a.height is not None:
                print(check_split_height(a.height, a.tip, a.min_depth))
            else:
                if a.step < 1:
                    raise ValueError("--step must be >= 1")
                print(default_split_height(a.tip, a.min_depth, a.step))
        elif a.cmd == "export":
            export(_rpc_from_args(a), a.last_height, a.raw_dir, workers=a.workers, net=NETWORKS[a.network])
        elif a.cmd == "pack":
            def load(path):
                if not path:
                    return None
                with open(path, encoding="utf-8") as f:
                    return json.load(f)
            pack(a.raw_dir, a.out_dir, a.last_height, net=NETWORKS[a.network], jobs=a.jobs, remove_raw=a.remove_raw,
                 crosscheck=load(a.crosscheck), treestate=load(a.treestate))
        elif a.cmd == "treestate":
            ts = _rpc_from_args(a).call("z_gettreestate", str(a.last_height))
            if ts.get("height") != a.last_height:
                raise VerifyError("z_gettreestate answered for height %r" % ts.get("height"))
            with open(a.out, "w", encoding="utf-8", newline="\n") as f:
                f.write(canonical_json(ts))
            print("tree state at %d: %s" % (a.last_height, ts.get("hash")))
        elif a.cmd == "crosscheck":
            rpc = _rpc_from_args(a)
            heights = crosscheck_heights(a.last_height, NETWORKS[a.network])
            got = {str(h): rpc.call("getblockhash", h) for h in heights}
            if a.compare_treestate:
                with open(a.compare_treestate, encoding="utf-8") as f:
                    mine = f.read()
                theirs = canonical_json(rpc.call("z_gettreestate", str(a.last_height)))
                if theirs != mine:
                    raise VerifyError("the cross-check node's z_gettreestate at %d differs from %s" % (a.last_height, a.compare_treestate))
            with open(a.out, "w", encoding="utf-8", newline="\n") as f:
                f.write(canonical_json(got))
            print("cross-check node: %d heights%s" % (len(got), ", tree state equal" if a.compare_treestate else ""))
        elif a.cmd == "verify":
            verify_dir(a.dir)
        elif a.cmd == "main-checkpoints":
            if a.chainparams == "-":
                text = sys.stdin.read()
            else:
                with open(a.chainparams, encoding="utf-8") as f:
                    text = f.read()
            cps, acts = extract_main_checkpoints(text)
            out = checkpoints_text(cps)
            if not a.check:
                sys.stdout.write(out)
            else:
                with open(YCASH_MAIN_CHECKPOINTS_FILE, encoding="ascii") as f:
                    vendored = f.read()
                got_sha = hashlib.sha256(out.encode("ascii")).hexdigest()
                compiled = {h: hx for h, hx in acts.values() if h in YCASH_MAIN_ACTIVATIONS}
                problems = []
                if out != vendored:
                    problems.append("the extracted list differs from %s" % YCASH_MAIN_CHECKPOINTS_FILE)
                if got_sha != YCASH_MAIN_CHECKPOINTS_SHA256:
                    problems.append("extracted sha256 %s, pinned %s" % (got_sha, YCASH_MAIN_CHECKPOINTS_SHA256))
                if compiled != YCASH_MAIN_ACTIVATIONS:
                    problems.append("activation hashes %s, harvest.py has %s" % (compiled, YCASH_MAIN_ACTIVATIONS))
                if problems:
                    raise VerifyError("; ".join(problems))
                print("OK: %d checkpoints (sha256 %s) and %d activation hashes match" % (len(cps), got_sha, len(compiled)))
        elif a.cmd == "constants":
            net = NETWORKS[a.network]
            pairs = [("NETWORK", net.name), ("PACK_IMAGE", PACK_IMAGE)]
            if net is TESTNET:
                pairs += [("ZEBRA_IMAGE", ZEBRA_IMAGE), ("ZEBRA_CHECKPOINTS_COMMIT", ZEBRA_CHECKPOINTS_COMMIT),
                          ("PREFIX_LAST_HEIGHT", PREFIX_LAST_HEIGHT), ("SMOKE_LAST_HEIGHT", SMOKE_LAST_HEIGHT)]
            else:
                pairs += [("YCASHD_IMAGE", YCASHD_IMAGE), ("YCASH_CHECKPOINTS_COMMIT", YCASH_CHECKPOINTS_COMMIT),
                          ("SMOKE_LAST_HEIGHT", net.smoke_last_height), ("CHUNK_BLOCKS", net.chunk_blocks),
                          ("SPLIT_STEP", SPLIT_STEP), ("SPLIT_MIN_DEPTH", SPLIT_MIN_DEPTH),
                          ("RPC_PORT", net.rpc_port), ("MAGIC", MAINNET_MAGIC)]
            for k, v in pairs:
                print("%s=%s" % (k, v))
    except (VerifyError, OSError, ValueError, KeyError, RuntimeError) as e:
        print("FAILED: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
