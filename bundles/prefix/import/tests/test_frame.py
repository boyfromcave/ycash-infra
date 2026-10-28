#!/usr/bin/env python3
"""Unit tests for frame.py, on real Zcash testnet blocks 0..10 (tests/data, README "Test data").

Run: python3 -I bundles/prefix/import/tests/test_frame.py
"""

import gzip
import hashlib
import json
import os
import shutil
import struct
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True  # no __pycache__ in the tree
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import frame  # noqa: E402
import make_prefix  # noqa: E402

BLOCKS = make_prefix.read_hex_blocks(os.path.join(HERE, "data", "zcash-testnet-blocks-0-10.hex"))
# Hashes of the fixture blocks, as Zebra and zcashd display them.
H0 = "05a60a92d99d85997cce3b87616c089f6124d7342af37106edc76126334a2c38"
H1 = "025579869bcf52a989337342f5f57a84f3a28b968f7d6a8307902b065a668d23"
H10 = "079f4c752729be63e6341ee9bce42fbbe37236aba22e3deb82405f3c2805c112"
MAGIC = bytes.fromhex("fa1af9bf")


def node_scan(data, magic, max_block=frame.MAX_BLOCK_SIZE):
    """The record scan of LoadExternalBlockFile (ycash6 src/main.cpp:7673-7720): find the magic's
    first byte, compare four bytes, read the length, skip a length outside 80..MAX_BLOCK_SIZE,
    read the block and resume right after it."""
    pos, out = 0, []
    while True:
        i = data.find(magic[:1], pos)
        if i < 0 or i + 8 > len(data):
            return out
        if data[i:i + 4] != magic:
            pos = i + 1
            continue
        (n,) = struct.unpack_from("<I", data, i + 4)
        if n < 80 or n > max_block or i + 8 + n > len(data):
            pos = i + 1
            continue
        out.append(data[i + 8:i + 8 + n])
        pos = i + 8 + n


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="frame-test-")
        self.prefix = os.path.join(self.tmp, "prefix")
        self.out = os.path.join(self.tmp, "out")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def build(self, span=5, blocks=BLOCKS):
        return make_prefix.build(blocks, self.prefix, chunk_span=span)

    def frame(self, span=5, **kw):
        return frame.frame_prefix(self.prefix, self.out, chunk_span=span, **kw)

    def assertRefused(self, fragment, span=5, **kw):
        with self.assertRaises(frame.FrameError) as cm:
            self.frame(span, **kw)
        self.assertIn(fragment, str(cm.exception))
        self.assertEqual(os.listdir(self.out) if os.path.isdir(self.out) else [], [],
                         "a refusal leaves no framed file behind")

    def rewrite_manifest(self, edit):
        p = os.path.join(self.prefix, "manifest.json")
        with open(p, encoding="utf-8") as f:
            m = json.load(f)
        edit(m)
        with open(p, "w", encoding="utf-8") as f:
            f.write(json.dumps(m, indent=2, sort_keys=True) + "\n")
        make_prefix.write_sums(self.prefix)


class TestHash(unittest.TestCase):
    def test_fixture_hashes(self):
        self.assertEqual(frame.block_hash(BLOCKS[0]), H0)
        self.assertEqual(frame.block_hash(BLOCKS[1]), H1)
        self.assertEqual(frame.block_hash(BLOCKS[10]), H10)
        self.assertEqual(frame.prev_hash(BLOCKS[1]), H0)
        self.assertEqual(frame.TESTNET_GENESIS, H0)

    def test_magic_and_expect_parsing(self):
        self.assertEqual(frame.parse_magic("FA1AF9BF"), MAGIC)
        with self.assertRaises(ValueError):
            frame.parse_magic("fa1af9")
        self.assertEqual(frame.parse_expect(["10:" + H10]), {10: H10})
        with self.assertRaises(ValueError):
            frame.parse_expect(["10:" + H10.upper()])


class TestRoundTrip(Base):
    def test_round_trip_multi_chunk(self):
        self.build(span=5)  # chunks 0..4, 5..9, 10..10
        s = self.frame(span=5)
        self.assertEqual((s["first_height"], s["last_height"], s["blocks"], s["chunks"]), (0, 10, 11, 3))
        self.assertEqual(s["tip_hash"], H10)
        self.assertEqual([os.path.basename(p) for p in s["files"]],
                         ["blk-0000000-0000004.dat", "blk-0000005-0000009.dat", "blk-0000010-0000010.dat"])
        data = b""
        for p in s["files"]:
            with open(p, "rb") as f:
                data += f.read()
        # Fixed-offset parse: every record is magic, LE length, block.
        pos, got = 0, []
        while pos < len(data):
            self.assertEqual(data[pos:pos + 4], MAGIC)
            (n,) = struct.unpack_from("<I", data, pos + 4)
            got.append(data[pos + 8:pos + 8 + n])
            pos += 8 + n
        self.assertEqual(got, BLOCKS)
        # The node's own scan finds the same blocks in the same order.
        self.assertEqual(node_scan(data, MAGIC), BLOCKS)
        # Unframing gives back the raw stream byte for byte.
        raw = b"".join(struct.pack("<I", len(b)) + b for b in got)
        want = b""
        for name in sorted(n for n in os.listdir(self.prefix) if n.endswith(".blocks.gz")):
            with gzip.open(os.path.join(self.prefix, name)) as g:
                want += g.read()
        self.assertEqual(raw, want)

    def test_single_chunk_default_span(self):
        self.build(span=50_000)
        s = self.frame(span=50_000)
        self.assertEqual(s["chunks"], 1)
        self.assertEqual(s["hashes"], {"0": H0, "10": H10})

    def test_other_magic(self):
        self.build()
        magic = bytes.fromhex("24e92764")
        s = self.frame(magic=magic)
        with open(s["files"][0], "rb") as f:
            data = f.read()
        self.assertEqual(data[:4], magic)
        self.assertEqual(node_scan(data, magic), BLOCKS[:5])
        self.assertEqual(node_scan(data, MAGIC), [])
        self.assertEqual(s["magic"], "24e92764")

    def test_expect_checked_and_ignored_above_tip(self):
        self.build()
        s = self.frame(expect={1: H1, 38000: "00" * 32})
        self.assertEqual(s["hashes"]["1"], H1)
        self.assertNotIn("38000", s["hashes"])
        shutil.rmtree(self.out)
        self.assertRefused("--expect says", expect={1: H10})

    def test_refuses_non_empty_output(self):
        self.build()
        os.makedirs(self.out)
        with open(os.path.join(self.out, "stale.dat"), "wb") as f:
            f.write(b"x")
        with self.assertRaises(frame.FrameError) as cm:
            self.frame()
        self.assertIn("not empty", str(cm.exception))

    def test_cli(self):
        self.build(span=50_000)
        summary = os.path.join(self.tmp, "s.json")
        rc = frame.main(["--prefix", self.prefix, "--out", self.out, "--summary", summary])
        self.assertEqual(rc, 0)
        with open(summary, encoding="utf-8") as f:
            self.assertEqual(json.load(f)["tip_hash"], H10)


class TestRefusals(Base):
    def test_corrupted_chunk(self):
        self.build()
        p = os.path.join(self.prefix, make_prefix.chunk_name(5, 9))
        with open(p, "r+b") as f:
            f.seek(40)
            b = f.read(1)
            f.seek(40)
            f.write(bytes([b[0] ^ 0xFF]))
        self.assertRefused("sha256")

    def test_corrupted_chunk_with_matching_sums(self):
        # SHA256SUMS regenerated over the corrupt file: the manifest's gz_sha256 still refuses it.
        self.build()
        p = os.path.join(self.prefix, make_prefix.chunk_name(0, 4))
        with open(p, "r+b") as f:
            f.seek(30)
            f.write(b"\x00\x00\x00\x00")
        make_prefix.write_sums(self.prefix)
        self.assertRefused("SHA256SUMS and manifest gz_sha256 disagree")

    def test_consistent_but_wrong_payload(self):
        # A chunk whose manifest and sums were all rebuilt around a damaged block: the raw stream
        # is self-consistent, so the block checks must catch it.
        bad = list(BLOCKS)
        bad[3] = bad[3][:200] + bytes([bad[3][200] ^ 1]) + bad[3][201:]  # inside the solution
        self.build(blocks=bad)
        self.assertRefused("does not link")

    def test_reordered_blocks(self):
        bad = list(BLOCKS)
        bad[6], bad[7] = bad[7], bad[6]
        self.build(blocks=bad)
        self.assertRefused("does not link")

    def test_wrong_genesis(self):
        self.build()
        self.assertRefused("genesis hash", genesis="00" * 32)

    def test_manifest_hash_mismatch(self):
        self.build()
        self.rewrite_manifest(lambda m: m["hashes"].__setitem__("10", H1))
        self.assertRefused("manifest says")

    def test_missing_hash_height(self):
        self.build()
        self.rewrite_manifest(lambda m: m["hashes"].pop("10"))
        self.assertRefused("lack heights")

    def test_bad_chunk_rule(self):
        self.build(span=5)
        self.assertRefused("the v1 rule gives", span=4)

    def test_extra_file_in_sums(self):
        self.build()
        with open(os.path.join(self.prefix, "SHA256SUMS"), "a", encoding="ascii") as f:
            f.write("%s  ../../etc/passwd\n" % ("0" * 64))
        self.assertRefused("unexpected file")

    def test_missing_sums_entry(self):
        self.build()
        p = os.path.join(self.prefix, "SHA256SUMS")
        with open(p, encoding="ascii") as f:
            lines = f.readlines()
        with open(p, "w", encoding="ascii") as f:
            f.writelines(lines[1:])
        self.assertRefused("the manifest needs")

    def test_wrong_format(self):
        self.build()
        self.rewrite_manifest(lambda m: m.__setitem__("format", "ycash-prefix/2"))
        self.assertRefused("manifest format")

    def test_truncated_gzip(self):
        self.build()
        p = os.path.join(self.prefix, make_prefix.chunk_name(10, 10))
        with open(p, "rb") as f:
            gz = f.read()
        with open(p, "wb") as f:
            f.write(gz[:-20])

        def fix(m):
            c = m["chunks"][2]
            c["gz_bytes"] = len(gz) - 20
            c["gz_sha256"] = hashlib.sha256(gz[:-20]).hexdigest()
        self.rewrite_manifest(fix)
        self.assertRefused(make_prefix.chunk_name(10, 10))

    def test_damaged_deflate_with_matching_sums(self):
        self.build(span=50_000)
        p = os.path.join(self.prefix, make_prefix.chunk_name(0, 10))
        with open(p, "rb") as f:
            gz = bytearray(f.read())
        for i in range(100, 400):
            gz[i] ^= 0x5A
        with open(p, "wb") as f:
            f.write(gz)

        def fix(m):
            c = m["chunks"][0]
            c["gz_sha256"] = hashlib.sha256(gz).hexdigest()
        self.rewrite_manifest(fix)
        self.assertRefused(make_prefix.chunk_name(0, 10), span=50_000)

    def test_oversized_length(self):
        raw = struct.pack("<I", frame.MAX_BLOCK_SIZE + 1) + b"\x00" * 16
        os.makedirs(self.prefix)
        self.build(span=50_000)
        name = make_prefix.chunk_name(0, 10)
        gz = gzip.compress(raw, mtime=0)
        with open(os.path.join(self.prefix, name), "wb") as f:
            f.write(gz)

        def fix(m):
            c = m["chunks"][0]
            c["gz_bytes"], c["gz_sha256"] = len(gz), hashlib.sha256(gz).hexdigest()
        self.rewrite_manifest(fix)
        self.assertRefused("outside 80..2000000", span=50_000)


if __name__ == "__main__":
    unittest.main()
