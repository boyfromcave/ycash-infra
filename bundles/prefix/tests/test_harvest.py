# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Offline unit tests for harvest.py, on real Zcash testnet blocks (tests/vectors/SOURCE).

Run: python3 -I -m unittest discover -s bundles/prefix/tests -t bundles/prefix
"""

import base64
import gzip
import hashlib
import http.server
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
import harvest as H  # noqa: E402

VEC = os.path.join(HERE, "vectors")


def vec(height):
    """The vendored Zcash testnet block at `height` (block-test-0-207-500.txt for 207,500)."""
    s = "%07d" % height
    with open(os.path.join(VEC, "block-test-%s-%s-%s.txt" % (s[0], s[1:4], s[4:7]))) as f:
        return bytes.fromhex(f.read().strip())


def stream(blocks):
    return b"".join(len(b).to_bytes(4, "little") + b for b in blocks)


def write_raw(raw_dir, last_height, blocks):
    os.makedirs(raw_dir, exist_ok=True)
    with open(os.path.join(raw_dir, H.chunk_name(0, last_height, gz=False)), "wb") as f:
        f.write(stream(blocks))


QUIET = lambda *a: None  # noqa: E731
GENESIS_TEN = list(range(0, 11))


class Vectors(unittest.TestCase):
    def test_vectors_match_their_recorded_sha256(self):
        with open(os.path.join(VEC, "SHA256SUMS")) as f:
            for line in f:
                digest, name = line.split()
                with open(os.path.join(VEC, name), "rb") as g:
                    self.assertEqual(hashlib.sha256(g.read()).hexdigest(), digest, name)

    def test_genesis_hash(self):
        h, prev = H.parse_block(vec(0))
        self.assertEqual(H.display(h), H.GENESIS_HASH)
        self.assertEqual(prev, b"\0" * 32)

    def test_header_layout(self):
        b = vec(1)
        n, off = H.read_compactsize(b, H.HEADER_BYTES)
        self.assertEqual(b[H.HEADER_BYTES:H.HEADER_BYTES + 3], bytes.fromhex("fd4005"))
        self.assertEqual((n, off), (1344, H.HEADER_BYTES + 3))
        # the hash covers version..nonce, the compactsize and the solution, nothing more
        self.assertEqual(H.parse_block(b)[0], H.sha256d(b[:H.HEADER_BYTES + 3 + 1344]))

    def test_ycash_compiled_pins_on_real_blocks(self):
        for h in (207500, 280000):
            self.assertEqual(H.display(H.parse_block(vec(h))[0]), H.YCASH_CHECKPOINTS[h])

    def test_linked_runs(self):
        for run in (GENESIS_TEN, [207499, 207500, 207501], [279999, 280000, 280001]):
            v = H.ChainVerifier(run[0], prev_hash=H.parse_block(vec(run[0]))[1], checkpoints={})
            for h in run:
                v.add(vec(h))

    def test_shielded_transactions_parse_and_merkle(self):
        # v2 JoinSplit, v3 Overwinter, v4 Sapling: parse to the last byte and match the Merkle root
        for h in (2259, 207501, 914678, 925483):
            H.parse_block(vec(h))

    def test_body_tamper_breaks_merkle(self):
        b = bytearray(vec(207501))
        b[-100] ^= 1
        with self.assertRaisesRegex(H.VerifyError, "Merkle"):
            H.parse_block(bytes(b))

    def test_header_tamper_breaks_pow_or_link(self):
        b = bytearray(vec(5))
        b[110] ^= 0xFF  # nonce byte: the hash changes, so it no longer meets the target or the next block's link
        v = H.ChainVerifier(0, checkpoints={})
        for h in range(0, 5):
            v.add(vec(h))
        try:
            v.add(bytes(b))
        except H.VerifyError:
            return
        with self.assertRaisesRegex(H.VerifyError, "hashPrevBlock"):
            v.add(vec(6))

    def test_trailing_bytes_rejected(self):
        with self.assertRaisesRegex(H.VerifyError, "trailing"):
            H.parse_block(vec(1) + b"\0")


class Chain(unittest.TestCase):
    def test_chain_link_failure(self):
        v = H.ChainVerifier(0, checkpoints={})
        v.add(vec(0))
        v.add(vec(1))
        with self.assertRaisesRegex(H.VerifyError, r"height 2: hashPrevBlock"):
            v.add(vec(3))

    def test_genesis_must_have_null_prev_and_hash(self):
        v = H.ChainVerifier(0, checkpoints={})
        with self.assertRaisesRegex(H.VerifyError, "height 0: hashPrevBlock"):
            v.add(vec(1))

    def test_checkpoint_mismatch_detected(self):
        bad = {1: ("zebra", "00" * 32)}
        v = H.ChainVerifier(0, checkpoints=bad)
        v.add(vec(0))
        with self.assertRaisesRegex(H.VerifyError, "height 1: hash .* zebra checkpoint"):
            v.add(vec(1))

    def test_ycash_checkpoint_mismatch_detected(self):
        cps = {207500: ("ycash", H.YCASH_CHECKPOINTS[280000])}
        v = H.ChainVerifier(207499, prev_hash=H.parse_block(vec(207499))[1], checkpoints=cps)
        v.add(vec(207499))
        with self.assertRaisesRegex(H.VerifyError, "height 207500: .* ycash checkpoint"):
            v.add(vec(207500))

    def test_checkpoints_genuine_block_passes(self):
        v = H.ChainVerifier(279999, prev_hash=H.parse_block(vec(279999))[1])
        for h in (279999, 280000, 280001):
            v.add(vec(h))
        self.assertEqual(v.checked, [280000])


class Checkpoints(unittest.TestCase):
    def test_vendored_file_pinned(self):
        cps = H.load_zebra_checkpoints()
        below = [h for h in cps if h <= H.PREFIX_LAST_HEIGHT]
        self.assertEqual(len(below), 1276)
        self.assertEqual(cps[0], H.GENESIS_HASH)
        self.assertEqual(cps[38000], H.YCASH_CHECKPOINTS[38000])
        self.assertEqual(cps[280000], H.YCASH_CHECKPOINTS[280000])

    def test_tampered_file_refused(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        p = os.path.join(d, "cp.txt")
        with open(H.ZEBRA_CHECKPOINTS_FILE, "rb") as f:
            data = f.read()
        with open(p, "wb") as f:
            f.write(data.replace(b"400 000393", b"400 100393", 1))
        with self.assertRaisesRegex(H.VerifyError, "sha256"):
            H.load_zebra_checkpoints(p)

    def test_merged_set(self):
        cps = H.all_checkpoints()
        self.assertEqual(cps[207500][0], "ycash")
        self.assertEqual(cps[280000][0], "zebra+ycash")
        self.assertEqual(sum(1 for h in cps if h <= H.PREFIX_LAST_HEIGHT), 1277)


class ChunkMath(unittest.TestCase):
    def test_full(self):
        r = H.chunk_ranges(510247)
        self.assertEqual(len(r), 11)
        self.assertEqual(r[0], (0, 49999))
        self.assertEqual(r[9], (450000, 499999))
        self.assertEqual(r[-1], (500000, 510247))
        self.assertEqual(sum(last - first + 1 for first, last in r), 510248)
        self.assertEqual(H.chunk_name(*r[-1]), "zcash-testnet-prefix-v1-0500000-0510247.blocks.gz")

    def test_smoke(self):
        self.assertEqual(H.chunk_ranges(4799), [(0, 4799)])
        self.assertEqual(H.chunk_name(0, 4799), "zcash-testnet-prefix-v1-0000000-0004799.blocks.gz")

    def test_edges(self):
        self.assertEqual(H.chunk_ranges(0), [(0, 0)])
        self.assertEqual(H.chunk_ranges(49999), [(0, 49999)])
        self.assertEqual(H.chunk_ranges(50000), [(0, 49999), (50000, 50000)])

    def test_hash_heights(self):
        hs = H.hash_heights(510247)
        self.assertEqual(hs[:3], [0, 10000, 20000])
        self.assertEqual(hs[-2:], [510000, 510247])
        self.assertEqual(len(hs), 53)
        self.assertEqual(H.hash_heights(4799), [0, 4799])
        self.assertEqual(H.hash_heights(20000), [0, 10000, 20000])


class PackVerify(unittest.TestCase):
    """The pack/verify path end to end on the genesis and the next ten blocks (last height 10)."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d)
        write_raw(os.path.join(self.d, "raw"), 10, [vec(h) for h in GENESIS_TEN])

    def pack(self, name):
        out = os.path.join(self.d, name)
        H.pack(os.path.join(self.d, "raw"), out, 10, log=QUIET)
        return out

    def test_determinism(self):
        a, b = self.pack("a"), self.pack("b")
        names = sorted(os.listdir(a))
        self.assertEqual(names, ["SHA256SUMS", "manifest.json", "zcash-testnet-prefix-v1-0000000-0000010.blocks.gz"])
        self.assertEqual(names, sorted(os.listdir(b)))
        for n in names:
            with open(os.path.join(a, n), "rb") as fa, open(os.path.join(b, n), "rb") as fb:
                self.assertEqual(fa.read(), fb.read(), n)

    def test_manifest_shape(self):
        out = self.pack("a")
        with open(os.path.join(out, "manifest.json"), encoding="utf-8") as f:
            text = f.read()
        m = json.loads(text)
        self.assertEqual(text, json.dumps(m, sort_keys=True, indent=2) + "\n")
        self.assertEqual(m["format"], "ycash-prefix/1")
        self.assertEqual(m["network"], "zcash-testnet")
        self.assertEqual((m["first_height"], m["last_height"]), (0, 10))
        self.assertEqual(set(m["hashes"]), {"0", "10"})
        self.assertEqual(m["hashes"]["0"], H.GENESIS_HASH)
        self.assertEqual(m["hashes"]["10"], H.display(H.parse_block(vec(10))[0]))
        c = m["chunks"][0]
        self.assertEqual(sorted(c), ["blocks", "file", "first_height", "gz_bytes", "gz_sha256", "last_height", "raw_bytes", "raw_sha256"])
        self.assertEqual(c["blocks"], 11)
        self.assertEqual(c["raw_bytes"], sum(4 + len(vec(h)) for h in GENESIS_TEN))
        self.assertEqual(sorted(m["sources"]), ["pack_image", "zebra_checkpoints_commit", "zebra_image"])
        with open(os.path.join(out, c["file"]), "rb") as f:
            gz = f.read()
        self.assertEqual(gz[3], 0, "gzip -n: no FNAME flag")
        self.assertEqual(gz[4:8], b"\0\0\0\0", "gzip -n: MTIME is zero")
        self.assertEqual(gzip.decompress(gz), stream([vec(h) for h in GENESIS_TEN]))
        with open(os.path.join(out, "SHA256SUMS")) as f:
            lines = f.read().splitlines()
        self.assertEqual([line.split("  ")[1] for line in lines], ["manifest.json", c["file"]])

    def test_verify_ok_and_tamper(self):
        out = self.pack("a")
        H.verify_dir(out, log=QUIET)
        gzname = os.path.join(out, H.chunk_name(0, 10))
        # a re-compressed chunk with valid content but different bytes fails SHA256SUMS
        with open(gzname, "rb") as f:
            raw = gzip.decompress(f.read())
        with open(gzname, "wb") as f:
            f.write(gzip.compress(raw, mtime=0, compresslevel=1))
        with self.assertRaisesRegex(H.VerifyError, "SHA256SUMS"):
            H.verify_dir(out, log=QUIET)

    def test_verify_catches_consistent_lie(self):
        # a chunk, manifest and SHA256SUMS that agree with each other but hold a broken chain
        blocks = [vec(h) for h in GENESIS_TEN]
        blocks[5], blocks[6] = blocks[6], blocks[5]
        out = os.path.join(self.d, "lie")
        os.makedirs(out)
        name = H.chunk_name(0, 10)
        with open(os.path.join(out, name), "wb") as f:
            f.write(gzip.compress(stream(blocks), mtime=0))
        man = H.build_manifest(10, [(11, 0, "")], [H.file_sha256(os.path.join(out, name))], {})
        with open(os.path.join(out, "manifest.json"), "w") as f:
            f.write(H.canonical_json(man))
        with open(os.path.join(out, "SHA256SUMS"), "w") as f:
            f.write(H.sha256sums_text(out, [name, "manifest.json"]))
        with self.assertRaisesRegex(H.VerifyError, "height 5: hashPrevBlock"):
            H.verify_dir(out, log=QUIET)

    def test_pack_refuses_missing_block(self):
        write_raw(os.path.join(self.d, "raw"), 10, [vec(h) for h in GENESIS_TEN[:-1]])
        with self.assertRaisesRegex(H.VerifyError, "ends at height 9"):
            self.pack("a")

    def test_cli_verify(self):
        out = self.pack("a")
        self.assertEqual(H.main(["verify", out]), 0)


class FakeZebra(http.server.BaseHTTPRequestHandler):
    """getblockhash / getblock <hash> 0 / getblockchaininfo over JSON-RPC with cookie auth."""
    blocks = {}
    cookie = "__cookie__:dGVzdA=="
    fail_next = [0]

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers.get("Authorization") != "Basic " + base64.b64encode(self.cookie.encode()).decode():
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.fail_next[0]:
            self.fail_next[0] -= 1
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        req = json.loads(body)
        m, p = req["method"], req["params"]
        by_hash = {H.display(H.parse_block(b)[0]): b for b in self.blocks.values()}
        if m == "getblockhash":
            result = H.display(H.parse_block(self.blocks[p[0]])[0])
        elif m == "getblock" and p[1] == 0:
            result = by_hash[p[0]].hex()
        elif m == "getblockchaininfo":
            result = {"blocks": max(self.blocks)}
        else:
            result = None
        out = json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


class Export(unittest.TestCase):
    def setUp(self):
        FakeZebra.blocks = {h: vec(h) for h in GENESIS_TEN}
        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeZebra)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.shutdown)
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d)
        self.cookie = os.path.join(self.d, ".cookie")
        with open(self.cookie, "w") as f:
            f.write(FakeZebra.cookie)
        self.url = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def test_export_pack_verify(self):
        FakeZebra.fail_next[0] = 2  # two 503s: the client retries
        rpc = H.RPC(self.url, cookie_file=self.cookie)
        rpc_fast = H.RPC(self.url, cookie_file=self.cookie)
        self.assertEqual(rpc_fast.call("getblockchaininfo")["blocks"], 10)
        raw = os.path.join(self.d, "raw")
        H.export(rpc, 10, raw, workers=3, window=4, log=QUIET)
        with open(os.path.join(raw, H.chunk_name(0, 10, gz=False)), "rb") as f:
            self.assertEqual(f.read(), stream([vec(h) for h in GENESIS_TEN]))
        out = os.path.join(self.d, "out")
        H.pack(raw, out, 10, log=QUIET)
        H.verify_dir(out, log=QUIET)

    def test_bad_cookie(self):
        with open(self.cookie, "w") as f:
            f.write("__cookie__:wrong")
        with self.assertRaisesRegex(RuntimeError, "HTTP 401"):
            H.RPC(self.url, cookie_file=self.cookie, retries=0).call("getblockchaininfo")

    def test_wrong_block_for_hash(self):
        rpc = H.RPC(self.url, cookie_file=self.cookie)
        orig = rpc.call
        # a node that answers getblock with a different block than getblockhash named
        rpc.call = lambda m, *p: vec(2).hex() if m == "getblock" else orig(m, *p)
        with self.assertRaisesRegex(H.VerifyError, "height 1: getblockhash"):
            H.fetch_block(rpc, 1)


class Pins(unittest.TestCase):
    """The images and commits are pinned once, in harvest.py; everything else must agree."""

    def read(self, *p):
        with open(os.path.join(*p), encoding="utf-8") as f:
            return f.read()

    def test_dockerfile_from(self):
        froms = re.findall(r"^FROM\s+(\S+)", self.read(ROOT, "Dockerfile"), re.M)
        self.assertEqual(froms, [H.PACK_IMAGE])

    def test_no_other_image_digests(self):
        repo = os.path.dirname(os.path.dirname(ROOT))
        files = [os.path.join(ROOT, "run-local.sh"), os.path.join(ROOT, "zebrad.toml"),
                 os.path.join(ROOT, "README.md"), os.path.join(ROOT, "FORMAT.md"),
                 os.path.join(repo, ".github", "workflows", "testnet-prefix.yml")]
        for p in files:
            if not os.path.exists(p):
                continue
            for d in re.findall(r"sha256:[0-9a-f]{64}", self.read(p)):
                self.assertIn(d, (H.ZEBRA_IMAGE + H.PACK_IMAGE), "%s pins %s" % (p, d))

    def test_pins_shape(self):
        self.assertRegex(H.ZEBRA_IMAGE, r"^docker\.io/zfnd/zebra:[0-9.]+@sha256:[0-9a-f]{64}$")
        self.assertRegex(H.PACK_IMAGE, r"@sha256:[0-9a-f]{64}$")
        self.assertRegex(H.ZEBRA_CHECKPOINTS_COMMIT, r"^[0-9a-f]{40}$")


if __name__ == "__main__":
    unittest.main()
