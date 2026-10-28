#!/usr/bin/env python3
"""Frame a Zcash-testnet prefix (format v1) for `ycashd -loadblock`.

Reads the prefix directory (`manifest.json`, `SHA256SUMS`, the `.blocks.gz` chunks), checks it as
data, and writes one `-loadblock` file per chunk. Each block becomes one record

    <4-byte network magic> <4-byte little-endian length> <block>

which is the record layout `LoadExternalBlockFile` scans for (ycash6 src/main.cpp:7673,
ycash-dd src/main.cpp:5782). The prefix itself is magic-neutral (`<LE u32 length> <block>`).

The prefix is untrusted input. Nothing in it is executed; this script only reads bytes. Before
anything is written it checks:
  * `SHA256SUMS` names exactly `manifest.json` and the manifest's chunks, each file name matches
    the v1 pattern, and every sha256 matches the file;
  * the manifest: format, network, contiguous chunks cut by the v1 rule, gz sizes and sha256s;
while streaming each chunk it checks the decompressed size and sha256, the block count, every
block's length, the hash chain, the genesis hash, every height listed in the manifest's `hashes`
and every `--expect HEIGHT:HASH`. Any failure removes the partial output and exits 2.

Python standard library only. Run with `python3 -I`.
"""

import argparse
import gzip
import hashlib
import json
import os
import re
import struct
import zlib
import sys

FORMAT = "ycash-prefix/1"
NETWORK = "zcash-testnet"
CHUNK_SPAN = 50_000
# Zcash testnet genesis (ycash6 src/chainparams.cpp:552, ycash-dd :494).
TESTNET_GENESIS = "05a60a92d99d85997cce3b87616c089f6124d7342af37106edc76126334a2c38"
# Ycash testnet magic on both node lines (ycash6 src/chainparams.cpp:539-542, ycash-dd :480-483).
TESTNET_MAGIC = "fa1af9bf"
# LoadExternalBlockFile skips a record whose length is < 80 or > MAX_BLOCK_SIZE (2,000,000 on
# both lines): refuse such a block here instead of letting the node skip it silently.
MIN_BLOCK = 80
MAX_BLOCK_SIZE = 2_000_000
# Zcash header: version..nonce is 140 bytes, then the compactsize-prefixed Equihash solution.
HEADER_FIXED = 140

CHUNK_RE = re.compile(r"^zcash-testnet-prefix-v1-(\d{7})-(\d{7})\.blocks\.gz$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
READ_SIZE = 1 << 20


class FrameError(Exception):
    """The prefix failed a check. The message says which."""


def sha256_file(path):
    h = hashlib.sha256()
    size = 0
    with open(path, "rb") as f:
        while True:
            b = f.read(READ_SIZE)
            if not b:
                break
            h.update(b)
            size += len(b)
    return h.hexdigest(), size


def chunk_name(first, last):
    return "zcash-testnet-prefix-v1-%07d-%07d.blocks.gz" % (first, last)


def block_hash(block):
    """SHA-256d of the header including the Equihash solution, displayed byte-reversed."""
    if len(block) < HEADER_FIXED + 1:
        raise FrameError("block shorter than a header")
    n = block[HEADER_FIXED]
    if n < 0xFD:
        hlen = 1 + n
    elif n == 0xFD:
        hlen = 3 + struct.unpack_from("<H", block, HEADER_FIXED + 1)[0]
    elif n == 0xFE:
        hlen = 5 + struct.unpack_from("<I", block, HEADER_FIXED + 1)[0]
    else:
        raise FrameError("solution length does not fit a block")
    end = HEADER_FIXED + hlen
    if end > len(block):
        raise FrameError("solution runs past the end of the block")
    d = hashlib.sha256(hashlib.sha256(block[:end]).digest()).digest()
    return d[::-1].hex()


def prev_hash(block):
    return block[4:36][::-1].hex()


def parse_magic(text):
    t = text.lower()
    if not re.fullmatch(r"[0-9a-f]{8}", t):
        raise ValueError("magic must be 8 hex digits, e.g. fa1af9bf")
    return bytes.fromhex(t)


def parse_expect(items):
    out = {}
    for item in items or []:
        m = re.fullmatch(r"(\d+):([0-9a-f]{64})", item)
        if not m:
            raise ValueError("--expect takes HEIGHT:HASH (64 lowercase hex): %r" % item)
        out[int(m.group(1))] = m.group(2)
    return out


def load_manifest(prefix_dir, chunk_span):
    path = os.path.join(prefix_dir, "manifest.json")
    try:
        with open(path, "rb") as f:
            m = json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError) as e:
        raise FrameError("manifest.json unreadable: %s" % e)
    if not isinstance(m, dict):
        raise FrameError("manifest.json is not an object")
    if m.get("format") != FORMAT:
        raise FrameError("manifest format %r, expected %r" % (m.get("format"), FORMAT))
    if m.get("network") != NETWORK:
        raise FrameError("manifest network %r, expected %r" % (m.get("network"), NETWORK))
    first, last = m.get("first_height"), m.get("last_height")
    if not (type(first) is int and type(last) is int and first == 0 and last >= 0):
        raise FrameError("manifest first_height must be 0 and last_height an integer >= 0")
    chunks = m.get("chunks")
    if not isinstance(chunks, list) or not chunks:
        raise FrameError("manifest has no chunks")
    expected_count = last // chunk_span + 1
    if len(chunks) != expected_count:
        raise FrameError("manifest has %d chunks, the v1 rule gives %d" % (len(chunks), expected_count))
    for k, c in enumerate(chunks):
        if not isinstance(c, dict):
            raise FrameError("chunk %d is not an object" % k)
        cf, cl = chunk_span * k, min(chunk_span * k + chunk_span - 1, last)
        for key in ("first_height", "last_height", "blocks", "raw_bytes", "gz_bytes"):
            if type(c.get(key)) is not int or c[key] < 0:
                raise FrameError("chunk %d: %s is not a non-negative integer" % (k, key))
        for key in ("raw_sha256", "gz_sha256"):
            if not isinstance(c.get(key), str) or not HEX64_RE.match(c[key]):
                raise FrameError("chunk %d: %s is not a sha256" % (k, key))
        if (c["first_height"], c["last_height"]) != (cf, cl):
            raise FrameError("chunk %d covers %d..%d, the v1 rule gives %d..%d"
                             % (k, c["first_height"], c["last_height"], cf, cl))
        if c["blocks"] != cl - cf + 1:
            raise FrameError("chunk %d: blocks %d, its range holds %d" % (k, c["blocks"], cl - cf + 1))
        if c.get("file") != chunk_name(cf, cl):
            raise FrameError("chunk %d: file %r, expected %r" % (k, c.get("file"), chunk_name(cf, cl)))
    hashes = m.get("hashes")
    if not isinstance(hashes, dict):
        raise FrameError("manifest hashes is not an object")
    checked = {}
    for k, v in hashes.items():
        if not re.fullmatch(r"0|[1-9]\d*", k) or not isinstance(v, str) or not HEX64_RE.match(v):
            raise FrameError("manifest hashes entry %r: %r is not height: hash" % (k, v))
        h = int(k)
        if h > last:
            raise FrameError("manifest hash at %d is above last_height %d" % (h, last))
        checked[h] = v
    want = set(range(0, last + 1, 10_000)) | {last}
    if not want <= set(checked):
        raise FrameError("manifest hashes lack heights %s" % sorted(want - set(checked))[:5])
    m["_hashes"] = checked
    return m


def check_sums(prefix_dir, manifest):
    path = os.path.join(prefix_dir, "SHA256SUMS")
    try:
        with open(path, "rb") as f:
            text = f.read().decode("ascii")
    except (OSError, UnicodeDecodeError) as e:
        raise FrameError("SHA256SUMS unreadable: %s" % e)
    sums = {}
    for line in text.splitlines():
        m = re.fullmatch(r"([0-9a-f]{64})  (\S+)", line)
        if not m:
            raise FrameError("SHA256SUMS line is not '<sha256>  <name>': %r" % line[:120])
        name = m.group(2)
        if name != "manifest.json" and not CHUNK_RE.match(name):
            raise FrameError("SHA256SUMS names an unexpected file %r" % name)
        if name in sums:
            raise FrameError("SHA256SUMS names %s twice" % name)
        sums[name] = m.group(1)
    names = sorted(sums)
    expected = sorted(["manifest.json"] + [c["file"] for c in manifest["chunks"]])
    if names != expected:
        raise FrameError("SHA256SUMS names %s, the manifest needs %s" % (names, expected))
    if list(sums) != names:
        raise FrameError("SHA256SUMS is not sorted by name")
    for name, want in sums.items():
        got, size = sha256_file(os.path.join(prefix_dir, name))
        if got != want:
            raise FrameError("%s: sha256 %s, SHA256SUMS says %s" % (name, got, want))
    for c in manifest["chunks"]:
        if sums[c["file"]] != c["gz_sha256"]:
            raise FrameError("%s: SHA256SUMS and manifest gz_sha256 disagree" % c["file"])
        size = os.path.getsize(os.path.join(prefix_dir, c["file"]))
        if size != c["gz_bytes"]:
            raise FrameError("%s: %d bytes, manifest gz_bytes %d" % (c["file"], size, c["gz_bytes"]))
    return sums


def read_exact(f, n):
    b = f.read(n)
    if len(b) != n:
        raise FrameError("chunk ends inside a record")
    return b


def frame_chunk(prefix_dir, chunk, out_path, magic, state, expect):
    """Stream one chunk into out_path. state carries the previous hash across chunks."""
    raw = hashlib.sha256()
    raw_bytes = 0
    height = chunk["first_height"]
    src = os.path.join(prefix_dir, chunk["file"])
    try:
        with gzip.open(src, "rb") as g, open(out_path, "wb") as out:
            while True:
                head = g.read(4)
                if not head:
                    break
                if len(head) != 4:
                    raise FrameError("%s: chunk ends inside a length" % chunk["file"])
                (n,) = struct.unpack("<I", head)
                if height > chunk["last_height"]:
                    raise FrameError("%s: more blocks than %d" % (chunk["file"], chunk["blocks"]))
                if n < MIN_BLOCK or n > MAX_BLOCK_SIZE:
                    raise FrameError("height %d: block length %d outside %d..%d" % (height, n, MIN_BLOCK, MAX_BLOCK_SIZE))
                block = read_exact(g, n)
                raw.update(head)
                raw.update(block)
                raw_bytes += 4 + n
                h = block_hash(block)
                if height == 0:
                    if h != state["genesis"]:
                        raise FrameError("genesis hash %s, expected %s" % (h, state["genesis"]))
                elif prev_hash(block) != state["prev"]:
                    raise FrameError("height %d: hashPrevBlock %s does not link to %s"
                                     % (height, prev_hash(block), state["prev"]))
                for label, table in (("manifest", state["hashes"]), ("--expect", expect)):
                    if height in table and table[height] != h:
                        raise FrameError("height %d: hash %s, %s says %s" % (height, h, label, table[height]))
                out.write(magic)
                out.write(head)
                out.write(block)
                state["prev"] = h
                height += 1
    except (OSError, EOFError, zlib.error, struct.error, ValueError) as e:
        raise FrameError("%s: %s" % (chunk["file"], e))
    if height != chunk["last_height"] + 1:
        raise FrameError("%s: %d blocks, manifest says %d"
                         % (chunk["file"], height - chunk["first_height"], chunk["blocks"]))
    if raw_bytes != chunk["raw_bytes"]:
        raise FrameError("%s: %d raw bytes, manifest says %d" % (chunk["file"], raw_bytes, chunk["raw_bytes"]))
    if raw.hexdigest() != chunk["raw_sha256"]:
        raise FrameError("%s: raw sha256 %s, manifest says %s" % (chunk["file"], raw.hexdigest(), chunk["raw_sha256"]))
    return raw_bytes


def frame_prefix(prefix_dir, out_dir, magic=None, chunk_span=CHUNK_SPAN, genesis=TESTNET_GENESIS, expect=None):
    """Check the prefix and write the -loadblock files. Returns a summary dict."""
    magic = magic if magic is not None else bytes.fromhex(TESTNET_MAGIC)
    expect = dict(expect or {})
    manifest = load_manifest(prefix_dir, chunk_span)
    check_sums(prefix_dir, manifest)
    last = manifest["last_height"]
    for h in list(expect):
        if h > last:
            del expect[h]  # a smoke prefix stops below some checkpoints
    os.makedirs(out_dir, exist_ok=True)
    if os.listdir(out_dir):
        raise FrameError("output directory %s is not empty" % out_dir)
    state = {"prev": None, "genesis": genesis, "hashes": manifest["_hashes"]}
    files, written = [], []
    total = 0
    try:
        for c in manifest["chunks"]:
            name = "blk-%07d-%07d.dat" % (c["first_height"], c["last_height"])
            path = os.path.join(out_dir, name)
            written.append(path)
            total += frame_chunk(prefix_dir, c, path, magic, state, expect)
            files.append(path)
    except BaseException:
        for p in written:
            try:
                os.remove(p)
            except OSError:
                pass
        raise
    return {
        "format": manifest["format"],
        "network": manifest["network"],
        "first_height": manifest["first_height"],
        "last_height": last,
        "tip_hash": state["prev"],
        "blocks": last + 1,
        "chunks": len(files),
        "raw_bytes": total,
        "magic": magic.hex(),
        "files": files,
        "hash_heights": sorted(set(manifest["_hashes"]) | set(expect)),
        "hashes": {str(h): v for h, v in sorted({**manifest["_hashes"], **expect}.items())},
        "sources": manifest.get("sources", {}),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--prefix", required=True, help="prefix directory (manifest.json, SHA256SUMS, chunks)")
    ap.add_argument("--out", required=True, help="directory for the framed -loadblock files")
    ap.add_argument("--magic", default=TESTNET_MAGIC, help="network magic, 8 hex digits (default %(default)s)")
    ap.add_argument("--genesis", default=TESTNET_GENESIS, help="expected hash at height 0")
    ap.add_argument("--expect", action="append", metavar="HEIGHT:HASH",
                    help="an extra hash the prefix must carry (ignored above last_height)")
    ap.add_argument("--chunk-span", type=int, default=CHUNK_SPAN, help=argparse.SUPPRESS)
    ap.add_argument("--summary", help="write the summary JSON here")
    a = ap.parse_args(argv)
    try:
        magic = parse_magic(a.magic)
        expect = parse_expect(a.expect)
    except ValueError as e:
        ap.error(str(e))
    try:
        s = frame_prefix(a.prefix, a.out, magic, a.chunk_span, a.genesis.lower(), expect)
    except FrameError as e:
        print("frame.py: refused: %s" % e, file=sys.stderr)
        return 2
    text = json.dumps(s, indent=2, sort_keys=True) + "\n"
    if a.summary:
        with open(a.summary, "w", encoding="utf-8") as f:
            f.write(text)
    print("framed %d blocks (heights %d..%d, %d chunks, %d raw bytes), tip %s"
          % (s["blocks"], s["first_height"], s["last_height"], s["chunks"], s["raw_bytes"], s["tip_hash"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
