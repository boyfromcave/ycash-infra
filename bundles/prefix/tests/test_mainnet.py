# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Offline tests of the ycash-mainnet history (FORMAT.md, "Networks"): the vendored checkpoint list,
the split-height rule, the cross-check heights, and the verifier, on real Ycash mainnet blocks 0..20
and on a synthetic mainnet-shaped chain (a scaled-down Ycash fork where the Equihash solution
shrinks from 1,344 to 400 bytes).

Run: python3 -I -m unittest discover -s bundles/prefix/tests
"""

import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
import harvest as H  # noqa: E402

QUIET = lambda *a: None  # noqa: E731
REPO = os.path.dirname(os.path.dirname(ROOT))
# a ycash6 clone beside this repository (the workspace layout), or YCASH6_TREE
YCASH6 = os.environ.get("YCASH6_TREE") or next(
    (p for p in (os.path.join(os.path.dirname(REPO), "ycash6"), os.path.join(os.path.dirname(os.path.dirname(REPO)), "ycash6"))
     if os.path.isdir(os.path.join(p, ".git")) or os.path.isfile(os.path.join(p, ".git"))), "")


def real_blocks():
    with open(os.path.join(HERE, "vectors", "ycash-mainnet-blocks-0-20.hex")) as f:
        return [bytes.fromhex(line.strip()) for line in f if line.strip()]


def stream(blocks):
    return b"".join(len(b).to_bytes(4, "little") + b for b in blocks)


# --- a synthetic mainnet-shaped chain ---------------------------------------------------------

FORK = 25  # the scaled-down Ycash fork: (200, 9) below, (192, 7) from here


def coinbase(height):
    script = bytes([3]) + height.to_bytes(3, "little")
    return (b"\x01\x00\x00\x00" + b"\x01" + b"\0" * 32 + b"\xff" * 4 + bytes([len(script)]) + script + b"\xff" * 4
            + b"\x01" + (125000000).to_bytes(8, "little") + b"\x01\x51" + b"\0" * 4)


def make_block(height, prev, sol_bytes):
    tx = coinbase(height)
    merkle = H.sha256d(tx)
    for nonce in range(1000):
        cs = b"\xfd" + sol_bytes.to_bytes(2, "little")
        header = (b"\x04\x00\x00\x00" + prev + merkle + b"\0" * 32 + (1600000000 + 75 * height).to_bytes(4, "little")
                  + (0x207fffff).to_bytes(4, "little") + nonce.to_bytes(32, "little") + cs + b"\0" * sol_bytes)
        b = header + b"\x01" + tx
        try:
            h = H.parse_block(b, sol_bytes)[0]
            return b, h
        except H.VerifyError:
            continue
    raise AssertionError("no nonce")


def synthetic_chain(n):
    blocks, prev = [], b"\0" * 32
    for h in range(n):
        b, prev = make_block(h, prev, 400 if h >= FORK else 1344)
        blocks.append(b)
    return blocks


SYN = synthetic_chain(41)
SYN_HASH = [H.display(H.parse_block(b, 400 if i >= FORK else 1344)[0]) for i, b in enumerate(SYN)]


def syn_net(**over):
    cps = {0: ("genesis", SYN_HASH[0]), 20: ("ycash checkpoint", SYN_HASH[20]), FORK: ("ycash activation", SYN_HASH[FORK])}
    kw = dict(chunk_blocks=10, solution_switch_height=FORK, genesis=SYN_HASH[0], checkpoints=cps)
    kw.update(over)
    return H.MAINNET.derive(**kw)


def treestate(last):
    return {"hash": SYN_HASH[last], "height": last, "time": H.block_time(SYN[last]),
            "sprout": {"commitments": {"finalRoot": "aa" * 32}}, "sapling": {"commitments": {"finalRoot": "bb" * 32}}}


class Vendoring(unittest.TestCase):
    def test_vendored_list_pinned_and_shaped(self):
        cps = H.load_main_checkpoints()
        self.assertEqual(len(cps), 18)
        self.assertEqual(cps[0], H.MAINNET_GENESIS_HASH)
        self.assertEqual(max(cps), 2250000)
        with open(H.YCASH_MAIN_CHECKPOINTS_FILE, "rb") as f:
            data = f.read()
        self.assertEqual(hashlib.sha256(data).hexdigest(), H.YCASH_MAIN_CHECKPOINTS_SHA256)
        self.assertEqual(data.decode(), H.checkpoints_text(cps))

    def test_tampered_list_refused(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        p = os.path.join(d, "cp.txt")
        with open(H.YCASH_MAIN_CHECKPOINTS_FILE, "rb") as f:
            data = f.read()
        with open(p, "wb") as f:
            f.write(data.replace(b"2250000 000003f9", b"2250000 000003f8"))
        with self.assertRaisesRegex(H.VerifyError, "sha256"):
            H.load_main_checkpoints(p)

    def test_merged_set_has_fork_block(self):
        cps = H.main_checkpoints()
        self.assertEqual(cps[570000], ("ycash activation", "0000014fbc5917ba8bcacf3336faf588d86b32443aa3a490a587af5750c77ec5"))
        self.assertEqual(cps[0][0], "genesis")
        self.assertEqual(len(cps), 21)

    SNIPPET = '''
class CMainParams : public CChainParams {
        assert(consensus.hashGenesisBlock == uint256S("0x%s"));
        consensus.vUpgrades[Consensus::UPGRADE_YCASH].nActivationHeight = 570000;
        consensus.vUpgrades[Consensus::UPGRADE_YCASH].hashActivationBlock =
            uint256S("0000014fbc5917ba8bcacf3336faf588d86b32443aa3a490a587af5750c77ec5");
        checkpointData = (CCheckpointData) {
            boost::assign::map_list_of
            (      0, consensus.hashGenesisBlock)
            // (   1, uint256S("0x%s"))  a commented-out entry never counts
            (   2500, uint256S("0x00000006dc968f600be11a86cbfbf7feb61c7577f45caced2e82b6d261d19744")),
            1, 2, 3
        };
};
class CTestNetParams : public CChainParams {
        checkpointData = (CCheckpointData) { boost::assign::map_list_of (0, uint256S("0x%s")), 1, 2, 3 };
};
''' % (H.MAINNET_GENESIS_HASH, "11" * 32, "22" * 32)

    def test_extract_from_a_snippet(self):
        cps, acts = H.extract_main_checkpoints(self.SNIPPET)
        self.assertEqual(cps, {0: H.MAINNET_GENESIS_HASH, 2500: "00000006dc968f600be11a86cbfbf7feb61c7577f45caced2e82b6d261d19744"})
        self.assertEqual(acts["UPGRADE_YCASH"], (570000, H.YCASH_MAIN_ACTIVATIONS[570000]))
        with self.assertRaisesRegex(H.VerifyError, "CMainParams"):
            H.extract_main_checkpoints("class CTestNetParams {};\nclass X")

    def test_extract_matches_the_pinned_ycash6_commit(self):
        """The vendoring check proper, when a ycash6 clone is at hand (YCASH6_TREE; CI fetches the file instead)."""
        if not YCASH6:
            self.skipTest("no ycash6 tree at %s" % YCASH6)
        r = subprocess.run(["git", "-C", YCASH6, "show", H.YCASH_CHECKPOINTS_COMMIT + ":src/chainparams.cpp"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if r.returncode:
            self.skipTest("commit %s not in %s" % (H.YCASH_CHECKPOINTS_COMMIT, YCASH6))
        cps, acts = H.extract_main_checkpoints(r.stdout.decode())
        with open(H.YCASH_MAIN_CHECKPOINTS_FILE) as f:
            self.assertEqual(H.checkpoints_text(cps), f.read())
        self.assertEqual({h: x for h, x in acts.values() if h in H.YCASH_MAIN_ACTIVATIONS}, H.YCASH_MAIN_ACTIVATIONS)


class SplitHeight(unittest.TestCase):
    def test_default_rule(self):
        self.assertEqual(H.default_split_height(3091234), 3089999)
        self.assertEqual(H.default_split_height(3090999), 3089999)   # exactly 1,000 deep
        self.assertEqual(H.default_split_height(3090998), 3079999)
        self.assertEqual(H.default_split_height(10999), 9999)
        with self.assertRaises(ValueError):
            H.default_split_height(10998)
        self.assertEqual(H.default_split_height(20, min_depth=5, step=10), 9)
        # the default always fills every chunk
        for tip in (11000, 2345678, 3091234):
            hs = H.default_split_height(tip)
            self.assertEqual((hs + 1) % 10000, 0)
            self.assertTrue(all(l - f + 1 == 10000 for f, l in H.chunk_ranges(hs, H.MAINNET)))

    def test_chosen_height(self):
        self.assertEqual(H.check_split_height(3090000, 3091000), 3090000)  # an explicit height: any value
        with self.assertRaisesRegex(ValueError, "at least 1000"):
            H.check_split_height(3090001, 3091000)

    def test_cli(self):
        self.assertEqual(H.main(["split-height", "--tip", "999"]), 1)
        self.assertEqual(H.main(["split-height", "--tip", "3091234", "--height", "3091000"]), 1)

    def test_crosscheck_heights(self):
        self.assertEqual(H.crosscheck_heights(2250000, H.MAINNET), [])
        self.assertEqual(H.crosscheck_heights(2250001, H.MAINNET), [2250001])
        self.assertEqual(H.crosscheck_heights(3089999, H.MAINNET),
                         [2300000, 2400000, 2500000, 2600000, 2700000, 2800000, 2900000, 3000000, 3089999])
        self.assertEqual(H.crosscheck_heights(3100000, H.MAINNET)[-2:], [3000000, 3100000])
        self.assertEqual(H.crosscheck_heights(510247), [])  # zcash-testnet: none


class Chunks(unittest.TestCase):
    def test_mainnet_chunking(self):
        r = H.chunk_ranges(3089999, H.MAINNET)   # the default rule's shape: every chunk full
        self.assertEqual(len(r), 309)
        self.assertEqual(r[0], (0, 9999))
        self.assertEqual(r[-1], (3080000, 3089999))
        self.assertEqual(H.chunk_name(*r[-1], net=H.MAINNET), "ycash-mainnet-prefix-v1-3080000-3089999.blocks.gz")
        # an explicit split height on a multiple of 10,000 is still accepted: a one-block last chunk
        self.assertEqual(H.chunk_ranges(3090000, H.MAINNET)[-1], (3090000, 3090000))

    def test_solution_sizes(self):
        self.assertEqual(H.MAINNET.solution_bytes(569999), 1344)
        self.assertEqual(H.MAINNET.solution_bytes(570000), 400)
        self.assertEqual(H.TESTNET.solution_bytes(10 ** 6), 1344)


class RealBlocks(unittest.TestCase):
    def test_genesis_and_chain(self):
        blocks = real_blocks()
        self.assertEqual(len(blocks), 21)
        v = H.ChainVerifier(0, net=H.MAINNET)
        for b in blocks:
            v.add(b)
        self.assertEqual(v.checked, [0])
        self.assertEqual(v.chaintx, 21)

    def test_testnet_genesis_refused(self):
        sys.path.insert(0, HERE)
        from test_harvest import vec
        with self.assertRaisesRegex(H.VerifyError, "height 0: hash .* genesis"):
            H.ChainVerifier(0, net=H.MAINNET).add(vec(0))

    def test_pack_verify_real(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        raw, out = os.path.join(d, "raw"), os.path.join(d, "out")
        os.makedirs(raw)
        with open(os.path.join(raw, H.chunk_name(0, 20, gz=False, net=H.MAINNET)), "wb") as f:
            f.write(stream(real_blocks()))
        hs = H.display(H.parse_block(real_blocks()[20])[0])
        ts = {"hash": hs, "height": 20, "time": H.block_time(real_blocks()[20]), "sprout": {}, "sapling": {}}
        m = H.pack(raw, out, 20, log=QUIET, net=H.MAINNET, treestate=ts)
        self.assertEqual(m["network"], "ycash-mainnet")
        self.assertEqual(sorted(m["sources"]), ["pack_image", "ycash_checkpoints_commit", "ycashd_image"])
        self.assertEqual(m["split"], {"height": 20, "hash": hs, "time": ts["time"], "chaintx": 21})
        self.assertEqual(sorted(os.listdir(out)), ["SHA256SUMS", "manifest.json", "treestate.json",
                                                   "ycash-mainnet-prefix-v1-0000000-0000020.blocks.gz"])
        self.assertEqual(H.main(["verify", out]), 0)


class Synthetic(unittest.TestCase):
    """A scaled-down mainnet: chunks of 10, the fork at 25, checkpoints at 0, 20 and 25."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d)
        self.raw = os.path.join(self.d, "raw")
        self.net = syn_net()

    def write_raw(self, blocks, last, net=None):
        net = net or self.net
        os.makedirs(self.raw, exist_ok=True)
        for first, l in H.chunk_ranges(last, net):
            with open(os.path.join(self.raw, H.chunk_name(first, l, gz=False, net=net)), "wb") as f:
                f.write(stream(blocks[first:l + 1]))

    def pack(self, last=40, name="out", **kw):
        kw.setdefault("crosscheck", {"40": SYN_HASH[40]} if last == 40 else {})
        kw.setdefault("treestate", treestate(last))
        out = os.path.join(self.d, name)
        return out, H.pack(self.raw, out, last, log=QUIET, net=self.net, jobs=3, **kw)

    def test_round_trip_deterministic(self):
        self.write_raw(SYN, 40)
        a, m = self.pack(name="a")
        b, _ = self.pack(name="b", remove_raw=False)
        for n in os.listdir(a):
            with open(os.path.join(a, n), "rb") as fa, open(os.path.join(b, n), "rb") as fb:
                self.assertEqual(fa.read(), fb.read(), n)
        self.assertEqual(len(m["chunks"]), 5)
        self.assertEqual(m["chunks"][-1]["first_height"], 40)
        self.assertEqual(set(m["hashes"]), {"0", "40"})
        self.assertEqual(m["crosscheck"], {"40": SYN_HASH[40]})
        self.assertEqual(m["split"]["chaintx"], 41)
        self.assertEqual(m["treestate"]["file"], "treestate.json")
        H.verify_dir(a, log=QUIET, net=self.net)
        with self.assertRaisesRegex(H.VerifyError, "manifest network"):
            H.verify_dir(a, log=QUIET, net=H.TESTNET)

    def test_remove_raw(self):
        self.write_raw(SYN, 40)
        self.pack(remove_raw=True)
        self.assertEqual(os.listdir(self.raw), [])

    def test_fork_solution_size_enforced(self):
        bad = list(SYN)
        bad[FORK], _ = make_block(FORK, H.parse_block(SYN[FORK - 1])[0], 1344)
        self.write_raw(bad, 30)
        with self.assertRaisesRegex(H.VerifyError, "height 25: Equihash solution of 1344 bytes, expected 400"):
            self.pack(30)

    def test_fork_block_hash_enforced(self):
        net = syn_net(checkpoints={0: ("genesis", SYN_HASH[0]), FORK: ("ycash activation", "00" * 32)})
        self.net = net
        self.write_raw(SYN, 30)
        with self.assertRaisesRegex(H.VerifyError, "height 25: hash .* ycash activation"):
            self.pack(30)

    def test_checkpoint_coverage(self):
        self.write_raw(SYN, 22)
        self.net = syn_net(checkpoints={0: ("genesis", SYN_HASH[0]), 20: ("ycash checkpoint", SYN_HASH[19])})
        with self.assertRaisesRegex(H.VerifyError, "height 20: .* ycash checkpoint"):
            self.pack(22)

    def test_crosscheck_required_and_compared(self):
        self.write_raw(SYN, 40)
        with self.assertRaisesRegex(H.VerifyError, "cross-check heights"):
            self.pack(crosscheck={})
        with self.assertRaisesRegex(H.VerifyError, "height 40: the cross-check node has"):
            self.pack(crosscheck={"40": SYN_HASH[39]})

    def test_treestate_required_and_matched(self):
        self.write_raw(SYN, 40)
        with self.assertRaisesRegex(H.VerifyError, "tree state at the last height is required"):
            self.pack(treestate=None)
        ts = treestate(40)
        ts["hash"] = SYN_HASH[39]
        with self.assertRaisesRegex(H.VerifyError, "treestate.json: hash"):
            self.pack(treestate=ts)

    def test_verify_catches_edits(self):
        self.write_raw(SYN, 40)
        out, _ = self.pack()
        mpath = os.path.join(out, "manifest.json")
        with open(mpath) as f:
            m = json.load(f)
        # a consistent lie about the crosscheck: re-sign SHA256SUMS too, verify still refuses
        m["crosscheck"]["40"] = SYN_HASH[39]
        with open(mpath, "w") as f:
            f.write(H.canonical_json(m))
        names = [n for n in os.listdir(out) if n != "SHA256SUMS"]
        with open(os.path.join(out, "SHA256SUMS"), "w") as f:
            f.write(H.sha256sums_text(out, names))
        with self.assertRaisesRegex(H.VerifyError, "cross-check node has"):
            H.verify_dir(out, log=QUIET, net=self.net)

    def test_chunk_size_limit(self):
        self.write_raw(SYN, 40)
        old = H.MAX_CHUNK_GZ_BYTES
        H.MAX_CHUNK_GZ_BYTES = 40
        self.addCleanup(setattr, H, "MAX_CHUNK_GZ_BYTES", old)
        with self.assertRaisesRegex(H.VerifyError, "release asset limit"):
            self.pack()

    def test_gzip_bytes(self):
        self.write_raw(SYN, 40)
        out, m = self.pack()
        with open(os.path.join(out, m["chunks"][0]["file"]), "rb") as f:
            gz = f.read()
        self.assertEqual(gz[4:8], b"\0\0\0\0")
        self.assertEqual(gzip.decompress(gz), stream(SYN[:10]))


FAKE_AWS = r"""#!/bin/sh
# s3 ls URI | s3 cp --only-show-errors SRC URI, against $FAKE_S3 (s3://b/k -> $FAKE_S3/b/k); log in $FAKE_S3.log
[ "$1" = s3 ] || exit 9
case "$2" in
  ls) p="$FAKE_S3/${3#s3://}"; [ -e "$p" ] ;;
  cp) dst="$FAKE_S3/${5#s3://}"; mkdir -p "$(dirname "$dst")"; cp "$4" "$dst" && echo "$(basename "$dst")" >> "$FAKE_S3.log" ;;
  *) exit 9 ;;
esac
"""


class PublishS3(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d)
        raw, self.out = os.path.join(self.d, "raw"), os.path.join(self.d, "out")
        os.makedirs(raw)
        blocks = real_blocks()
        with open(os.path.join(raw, H.chunk_name(0, 20, gz=False, net=H.MAINNET)), "wb") as f:
            f.write(stream(blocks))
        ts = {"hash": H.display(H.parse_block(blocks[20])[0]), "height": 20, "time": H.block_time(blocks[20]),
              "sprout": {}, "sapling": {}}
        H.pack(raw, self.out, 20, log=QUIET, net=H.MAINNET, treestate=ts)
        self.aws = os.path.join(self.d, "aws")
        with open(self.aws, "w") as f:
            f.write(FAKE_AWS)
        os.chmod(self.aws, 0o700)
        self.s3 = os.path.join(self.d, "s3")
        self.env = dict(os.environ, AWS=self.aws, FAKE_S3=self.s3)

    def publish(self, dest="s3://bucket-x/prefixes/mainnet-prefix-v1"):
        return subprocess.run(["bash", os.path.join(ROOT, "publish-s3.sh"), self.out, dest], env=self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def test_publish_once_index_last(self):
        r = self.publish()
        self.assertEqual(r.returncode, 0, r.stdout)
        with open(self.s3 + ".log") as f:
            order = f.read().split()
        self.assertEqual(order[-2:], ["manifest.json", "SHA256SUMS"])
        self.assertEqual(sorted(order), sorted(os.listdir(self.out)))
        H.verify_dir(os.path.join(self.s3, "bucket-x", "prefixes", "mainnet-prefix-v1"), log=QUIET)
        r = self.publish()
        self.assertEqual(r.returncode, 1)
        self.assertIn("never overwritten", r.stdout)

    def test_refuses_bad_uri_and_bad_bundle(self):
        self.assertEqual(self.publish("https://example.org/x").returncode, 2)
        with open(os.path.join(self.out, "treestate.json"), "a") as f:
            f.write(" ")
        r = self.publish()
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(self.s3))


class Pins(unittest.TestCase):
    def test_mainnet_pins_shape(self):
        self.assertRegex(H.YCASHD_IMAGE, r"^ghcr\.io/boyfromcave/ycashd:ycash6-[0-9a-f]{12}@sha256:[0-9a-f]{64}$")
        self.assertTrue(H.YCASH_CHECKPOINTS_COMMIT.startswith(H.YCASHD_IMAGE.split(":ycash6-")[1][:12]))
        self.assertRegex(H.YCASH_CHECKPOINTS_COMMIT, r"^[0-9a-f]{40}$")

    def test_import_side_agrees(self):
        """frame.py and import.sh carry the same mainnet facts as harvest.py."""
        sys.path.insert(0, os.path.join(ROOT, "import"))
        import frame
        n = frame.NETWORKS["ycash-mainnet"]
        self.assertEqual((n["genesis"], n["magic"], n["chunk_span"], n["file_prefix"]),
                         (H.MAINNET_GENESIS_HASH, H.MAINNET_MAGIC, H.MAINNET.chunk_blocks, H.MAINNET.file_prefix))
        t = frame.NETWORKS["zcash-testnet"]
        self.assertEqual((t["genesis"], t["chunk_span"]), (H.GENESIS_HASH, H.CHUNK_BLOCKS))
        with open(os.path.join(ROOT, "import", "import.sh")) as f:
            text = f.read()
        acts = dict((int(h), x) for h, x in re.findall(r"^\s+(\d+):([0-9a-f]{64})$", text.split("COMPILED_MAIN=(")[1].split(")")[0], re.M))
        self.assertEqual(acts, H.YCASH_MAIN_ACTIVATIONS)

    def test_workflow_and_docs_digests(self):
        repo = os.path.dirname(os.path.dirname(ROOT))
        for p in (os.path.join(ROOT, "run-local-mainnet.sh"), os.path.join(repo, ".github", "workflows", "mainnet-prefix.yml"),
                  os.path.join(repo, ".github", "workflows", "mainnet-prefix-import.yml")):
            if os.path.exists(p):
                with open(p) as f:
                    text = f.read()
                for d in re.findall(r"sha256:[0-9a-f]{64}", text):
                    self.assertIn(d, H.YCASHD_IMAGE + H.PACK_IMAGE + H.ZEBRA_IMAGE, "%s pins %s" % (p, d))


if __name__ == "__main__":
    unittest.main()
