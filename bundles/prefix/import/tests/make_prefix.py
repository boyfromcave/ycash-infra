#!/usr/bin/env python3
"""Build a small format-v1 prefix from hex blocks, for the import tests only.

The real prefix comes from the harvest job. This writes the same layout (chunks of
`<LE u32 length> <block>` gzip'd, manifest.json, SHA256SUMS) from a file with one hex block per
line, heights 0..N-1, so frame.py and import.sh can be exercised without the harvest.
"""

import argparse
import gzip
import hashlib
import json
import os
import struct
import sys


def chunk_name(first, last):
    return "zcash-testnet-prefix-v1-%07d-%07d.blocks.gz" % (first, last)


def block_hash(block):
    n = block[140]
    hlen = 1 + n if n < 0xFD else 3 + struct.unpack_from("<H", block, 141)[0]
    return hashlib.sha256(hashlib.sha256(block[:140 + hlen]).digest()).digest()[::-1].hex()


def build(blocks, out_dir, chunk_span=50_000, last=None):
    last = len(blocks) - 1 if last is None else last
    os.makedirs(out_dir, exist_ok=True)
    chunks = []
    for k in range(last // chunk_span + 1):
        first, cl = chunk_span * k, min(chunk_span * k + chunk_span - 1, last)
        raw = b"".join(struct.pack("<I", len(b)) + b for b in blocks[first:cl + 1])
        name = chunk_name(first, cl)
        gz = gzip.compress(raw, compresslevel=9, mtime=0)
        with open(os.path.join(out_dir, name), "wb") as f:
            f.write(gz)
        chunks.append({
            "file": name, "first_height": first, "last_height": cl, "blocks": cl - first + 1,
            "raw_bytes": len(raw), "raw_sha256": hashlib.sha256(raw).hexdigest(),
            "gz_bytes": len(gz), "gz_sha256": hashlib.sha256(gz).hexdigest(),
        })
    heights = sorted(set(range(0, last + 1, 10_000)) | {last})
    manifest = {
        "format": "ycash-prefix/1", "network": "zcash-testnet",
        "first_height": 0, "last_height": last, "chunks": chunks,
        "hashes": {str(h): block_hash(blocks[h]) for h in heights},
        "sources": {"zebra_image": "test", "zebra_checkpoints_commit": "test", "pack_image": "test"},
    }
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        f.write(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    write_sums(out_dir)
    return manifest


def write_sums(out_dir):
    names = sorted(n for n in os.listdir(out_dir) if n == "manifest.json" or n.endswith(".blocks.gz"))
    lines = []
    for n in names:
        with open(os.path.join(out_dir, n), "rb") as f:
            lines.append("%s  %s\n" % (hashlib.sha256(f.read()).hexdigest(), n))
    with open(os.path.join(out_dir, "SHA256SUMS"), "w", encoding="ascii") as f:
        f.writelines(lines)


def read_hex_blocks(path):
    with open(path, encoding="ascii") as f:
        return [bytes.fromhex(line.strip()) for line in f if line.strip()]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--hex", required=True, help="one hex block per line, heights from 0")
    ap.add_argument("--out", required=True)
    ap.add_argument("--chunk-span", type=int, default=50_000)
    a = ap.parse_args(argv)
    m = build(read_hex_blocks(a.hex), a.out, a.chunk_span)
    print("prefix 0..%d in %d chunks at %s" % (m["last_height"], len(m["chunks"]), a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
