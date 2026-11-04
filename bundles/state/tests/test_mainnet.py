# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Offline tests of the mainnet snapshot tool (bundles/state/mainnet/snapshot.py: pack, finalize, kogany)
and of verify.py's `ycash-state/2` and `kogany-state/1`/`2` rules, on stand-in datadirs (no node)."""

import argparse
import contextlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.dirname(HERE)
sys.path.insert(0, STATE)
sys.path.insert(0, os.path.join(STATE, "mainnet"))

import snapshot  # noqa: E402
import verify  # noqa: E402

H = 570000
BH = verify.MAINNET_PINS[H]


def write(path, data=b"x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def quiet(fn, *args):
    with contextlib.redirect_stdout(io.StringIO()):
        return fn(*args)


class Mainnet(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cap = os.path.join(self.tmp.name, str(H))
        main = os.path.join(self.cap, "datadir", "main")
        write(os.path.join(main, "blocks", "blk00000.dat"), b"blocks" * 1000)
        write(os.path.join(main, "blocks", "rev00000.dat"), b"undo")
        write(os.path.join(main, "blocks", "index", "000003.ldb"), b"index")
        write(os.path.join(main, "blocks", "index", "LOCK"), b"")
        write(os.path.join(main, "blocks", "index", "LOG"), b"wall clock")
        write(os.path.join(main, "chainstate", "000005.ldb"), b"coins")
        write(os.path.join(main, "chainstate", "LOG.old"), b"wall clock")
        write(os.path.join(main, "vaults", "CURRENT"), b"MANIFEST-000001\n")
        with open(os.path.join(self.cap, "capture.json"), "w") as f:
            json.dump({"height": H}, f)
        self.out = os.path.join(self.cap, "bundle")
        os.makedirs(self.out)
        st = {"network": "main", "height": H, "blockhash": BH, "chainwork": "00" * 32,
              "utxo_hash_serialized": "11" * 32, "vault_statehash": "22" * 32, "yed_statehash": None,
              "finalsaplingroot": "33" * 32, "chainsupply_zat": 123}
        snapshot.dump(os.path.join(self.out, "statement-ycash6.json"), st)
        snapshot.dump(os.path.join(self.out, "treestate.json"), {"height": H})
        pins = {str(h): x for h, x in verify.MAINNET_PINS.items() if h <= H}
        snapshot.dump(os.path.join(self.cap, "meta.json"), {"time": 1568000000, "version": "6.22.0-rc1",
                                                             "commit": "65cb4ae0f", "pins": pins})

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, purpose=None):
        a = argparse.Namespace(capture=self.cap, version=None, purpose=purpose)
        quiet(snapshot.pack, a)
        quiet(snapshot.finalize, a)

    def manifest(self):
        with open(os.path.join(self.out, "manifest.json")) as f:
            return json.load(f)

    def rewrite_manifest(self, **kw):
        m = self.manifest()
        m.update(kw)
        snapshot.dump(os.path.join(self.out, "manifest.json"), m)
        snapshot.write_sums(self.out)

    def test_bundle_verifies(self):
        self.build(purpose="the Ycash fork block")
        self.assertEqual(verify.verify(self.out, tree=True), [])
        m = self.manifest()
        self.assertEqual(m["format"], "ycash-state/2")
        self.assertEqual(m["tarball"], "ycash6-main-570000-full.tar.gz")
        self.assertEqual(m["created"], "2019-09-09T03:33:20Z")
        self.assertEqual(m["purpose"], "the Ycash fork block")

    def test_tar_entries_and_headers(self):
        self.build()
        with tarfile.open(os.path.join(self.out, self.manifest()["tarball"])) as t:
            names = t.getnames()
            for e in t.getmembers():
                self.assertEqual((e.mtime, e.uid, e.gid, e.uname, e.gname), (0, 0, 0, "", ""))
                self.assertEqual(e.mode, 0o755 if e.isdir() else 0o644)
        self.assertIn("main/blocks/blk00000.dat", names)
        self.assertNotIn("main/blocks/index/LOCK", names)
        self.assertNotIn("main/blocks/index/LOG", names)
        self.assertNotIn("main/chainstate/LOG.old", names)
        self.assertEqual(names, sorted(names, key=lambda s: s.rstrip("/").encode()))

    def test_pack_is_reproducible(self):
        self.build()
        first = self.manifest()["sha256"]
        os.remove(os.path.join(self.out, self.manifest()["tarball"]))
        self.build()
        self.assertEqual(self.manifest()["sha256"], first)

    def test_wrong_pin_fails(self):
        self.build()
        pins = dict(self.manifest()["pins"])
        pins["570000"] = "ff" * 32
        self.rewrite_manifest(pins=pins)
        self.assertTrue(any("pins" in e for e in verify.verify(self.out)))

    def test_tree_mismatch_fails(self):
        self.build()
        self.rewrite_manifest(tree_sha256="44" * 32)
        self.assertEqual(verify.verify(self.out), [])          # headers only
        self.assertTrue(any("tree_sha256" in e for e in verify.verify(self.out, tree=True)))

    def test_statement_required(self):
        self.build()
        os.rename(os.path.join(self.out, "statement-ycash6.json"), os.path.join(self.out, "statement-other.json"))
        self.rewrite_manifest(verifiers=["other"])
        self.assertTrue(any("statement-ycash6.json is required" in e for e in verify.verify(self.out)))

    def test_publish_order(self):
        self.build()
        log = os.path.join(self.tmp.name, "aws.log")
        fake = os.path.join(self.tmp.name, "aws")
        with open(fake, "w") as f:
            f.write("#!/bin/sh\necho \"$*\" >> %s\n"
                    "case \"$2\" in ls) exit 1 ;; esac\n"
                    "[ \"$4\" = - ] && exit 1\nexit 0\n" % log)
        os.chmod(fake, 0o700)
        r = subprocess.run(["bash", os.path.join(STATE, "mainnet", "publish-s3.sh"), self.out, "s3://bucket-x/snap"],
                           env=dict(os.environ, AWS=fake), capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(log) as f:
            dests = [l.split()[-1] for l in f.read().splitlines() if l.startswith("s3 cp") and not l.endswith(" -")]
        base = "s3://bucket-x/snap/main/570000/"
        self.assertEqual(dests[0], base + "ycash6-main-570000-full.tar.gz")
        self.assertEqual(dests[-3:], [base + "manifest.json", base + "SHA256SUMS",
                                      "s3://bucket-x/snap/main/latest/manifest.json"])

    def test_unexpected_file_fails(self):
        self.build()
        write(os.path.join(self.out, "notes.txt"), b"?")
        snapshot.write_sums(self.out)
        self.assertTrue(any("unexpected" in e for e in verify.verify(self.out)))


def kogany_cache(tmp):
    v = os.path.join(tmp, "cache", "state", "v30", "mainnet")
    write(os.path.join(v, "version"), b"30.2.0")
    write(os.path.join(v, "000012.sst"), b"sst")
    write(os.path.join(v, "003143.log"), b"wal")      # RocksDB's write-ahead log: kept
    write(os.path.join(v, "LOCK"), b"")
    write(os.path.join(v, "LOG"), b"x")
    write(os.path.join(v, "LOG.old.1762000000"), b"x")
    write(os.path.join(tmp, "cache", "non_finalized_state", "mainnet", "00" * 32), b"block")
    return os.path.join(tmp, "cache")


def kogany_args(tmp, out, **kw):
    return argparse.Namespace(cache=kogany_cache(tmp), height=H, blockhash=BH, out=out, version="kogany test",
                              ycash_statement=None, check_stopped=False, **kw)


def rewrite(out, m):
    snapshot.dump(os.path.join(out, "manifest.json"), m)
    snapshot.write_sums(out)


class Kogany(unittest.TestCase):
    def test_kogany_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out")
            a = kogany_args(tmp, out)
            quiet(snapshot.kogany, a)
            self.assertEqual(verify.verify(out, tree=True), [])
            with open(os.path.join(out, "manifest.json")) as f:
                m = json.load(f)
            self.assertEqual(m["format"], "kogany-state/2")
            self.assertEqual((m["storage_mode"], m["lowest_retained_height"]), ("archive", None))
            self.assertEqual(m["state_format"], "30.2.0")
            self.assertEqual(m["tarball"], "kogany-main-570000-state-30.2.0.tar.gz")
            with tarfile.open(os.path.join(out, m["tarball"])) as t:
                names = t.getnames()
            self.assertIn("state/v30/mainnet/003143.log", names)
            self.assertNotIn("state/v30/mainnet/LOCK", names)
            self.assertNotIn("state/v30/mainnet/LOG.old.1762000000", names)
            self.assertIn("non_finalized_state/mainnet/" + "00" * 32, names)   # the tip's last blocks
            self.assertEqual(m["non_finalized_blocks"], 1)
            # a manifest that miscounts the non-finalized blocks is refused
            m["non_finalized_blocks"] = 0
            snapshot.dump(os.path.join(out, "manifest.json"), m)
            snapshot.write_sums(out)
            self.assertTrue(any("non-finalized" in e for e in verify.verify(out)))
            m["non_finalized_blocks"] = 1
            # a wrong block hash at a pinned height is refused
            m["blockhash"] = "ee" * 32
            snapshot.dump(os.path.join(out, "manifest.json"), m)
            snapshot.write_sums(out)
            self.assertTrue(any("pin" in e for e in verify.verify(out)))

    def test_kogany_pruned_bundle(self):
        """KP-4: a pruned cache as `kogany-state/2` with `storage_mode` and `lowest_retained_height`."""
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out")
            low = (H - 1) - 34_560 + 1                  # the infra retention below the finalized tip H - 1
            quiet(snapshot.kogany, kogany_args(tmp, out, storage_mode="pruned", lowest_retained_height=low))
            self.assertEqual(verify.verify(out, tree=True), [])
            with open(os.path.join(out, "manifest.json")) as f:
                m = json.load(f)
            self.assertEqual((m["format"], m["storage_mode"], m["lowest_retained_height"]),
                             ("kogany-state/2", "pruned", low))
            self.assertEqual(m["tarball"], "kogany-main-570000-state-30.2.0-pruned.tar.gz")
            # Zakura's floor: fewer than 10,000 blocks kept below the finalized tip is refused
            bad = dict(m, lowest_retained_height=H - 1 - 9_999 + 1)
            rewrite(out, bad)
            self.assertTrue(any("floor" in e for e in verify.verify(out)))
            rewrite(out, dict(m, lowest_retained_height=H + 1))
            self.assertTrue(any("lowest_retained_height" in e for e in verify.verify(out)))
            rewrite(out, dict(m, storage_mode="archive"))   # an archive bundle names no retained height
            errs = verify.verify(out)
            self.assertTrue(any("archive bundle" in e for e in errs), errs)
            self.assertTrue(any("tarball" in e for e in errs), errs)    # and has no -pruned suffix
            rewrite(out, dict(m, storage_mode="thin"))
            self.assertTrue(any("storage_mode" in e for e in verify.verify(out)))
            rewrite(out, dict(m, lowest_retained_height=0))  # pruned mode, nothing deleted yet
            self.assertEqual(verify.verify(out), [])
            nofield = {k: v for k, v in m.items() if k != "storage_mode"}
            rewrite(out, nofield)
            self.assertTrue(any("missing storage_mode" in e for e in verify.verify(out)))

    def test_kogany_pruned_needs_its_height(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out")
            with self.assertRaises(SystemExit):
                with contextlib.redirect_stderr(io.StringIO()):
                    quiet(snapshot.kogany, kogany_args(tmp, out, storage_mode="pruned", lowest_retained_height=None))
            with self.assertRaises(SystemExit):                 # below the floor: refused before packing
                with contextlib.redirect_stderr(io.StringIO()):
                    quiet(snapshot.kogany, kogany_args(tmp, out, storage_mode="pruned",
                                                       lowest_retained_height=H - 100))
            self.assertFalse(any(n.endswith(".tar.gz") for n in os.listdir(out)))

    def test_kogany_v1_still_verifies(self):
        """The recorded `kogany-state/1` bundles (archive by construction) stay valid; v1 carries no v2 field."""
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out")
            quiet(snapshot.kogany, kogany_args(tmp, out))
            with open(os.path.join(out, "manifest.json")) as f:
                m = json.load(f)
            v1 = {k: v for k, v in m.items() if k not in ("storage_mode", "lowest_retained_height")}
            v1["format"] = "kogany-state/1"
            rewrite(out, v1)
            self.assertEqual(verify.verify(out, tree=True), [])
            rewrite(out, dict(v1, storage_mode="archive"))
            self.assertTrue(any("kogany-state/2 fields" in e for e in verify.verify(out)))


if __name__ == "__main__":
    unittest.main()
