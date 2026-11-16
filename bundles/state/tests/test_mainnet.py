# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Offline tests of the mainnet snapshot tool (bundles/state/mainnet/snapshot.py: pack, finalize, kogany)
and of verify.py's `ycash-state/2`, `ycash-state/3` and `kogany-state/1`/`2` rules, on stand-in datadirs
(no node)."""

import argparse
import contextlib
import hashlib
import io
import json
import os
import shutil
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

    def build(self, purpose=None, part_bytes=None):
        a = argparse.Namespace(capture=self.cap, version=None, purpose=purpose, part_bytes=part_bytes)
        quiet(snapshot.pack, a)
        quiet(snapshot.finalize, a)

    def manifest(self):
        with open(os.path.join(self.out, "manifest.json")) as f:
            return json.load(f)

    def joined(self):
        """The bundle's parts joined in order: the tarball a ycash-state/2 producer writes."""
        data = b""
        for p in self.manifest()["parts"]:
            with open(os.path.join(self.out, p["name"]), "rb") as f:
                data += f.read()
        return data

    def tar(self):
        return tarfile.open(fileobj=io.BytesIO(self.joined()), mode="r:gz")

    def rewrite_manifest(self, **kw):
        m = self.manifest()
        m.update(kw)
        snapshot.dump(os.path.join(self.out, "manifest.json"), m)
        snapshot.write_sums(self.out)

    def test_bundle_verifies(self):
        self.build(purpose="the Ycash fork block")
        self.assertEqual(verify.verify(self.out, tree=True), [])
        m = self.manifest()
        self.assertEqual(m["format"], "ycash-state/3")
        self.assertEqual(m["tarball"], "ycash6-main-570000-full.tar.gz")
        self.assertEqual([p["name"] for p in m["parts"]], ["ycash6-main-570000-full.tar.gz.000"])  # one part
        self.assertEqual((m["part_bytes"], m["unpacked_bytes"]), (1 << 30, 6000 + 4 + 5 + 5 + len(b"MANIFEST-000001\n")))
        self.assertFalse(os.path.exists(os.path.join(self.out, m["tarball"])))
        self.assertEqual(m["created"], "2019-09-09T03:33:20Z")
        self.assertEqual(m["purpose"], "the Ycash fork block")

    def add_insight(self):
        idx = os.path.join(self.cap, "datadir", "main", "blocks", "insight-index")
        write(os.path.join(idx, "000007.ldb"), b"address index")
        write(os.path.join(idx, "LOCK"), b"")

    def test_full_insight_bundle(self):
        self.add_insight()
        self.build()
        m = self.manifest()
        self.assertEqual((m["flavour"], m["tarball"]), ("full-insight", "ycash6-main-570000-full-insight.tar.gz"))
        with self.tar() as t:
            names = t.getnames()
        self.assertIn("main/blocks/insight-index/000007.ldb", names)
        self.assertNotIn("main/blocks/insight-index/LOCK", names)
        self.assertEqual(verify.verify(self.out, tree=True), [])

    def test_flavour_must_match_the_capture(self):
        self.add_insight()
        a = argparse.Namespace(capture=self.cap, version=None, purpose=None, flavour="full")
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            quiet(snapshot.pack, a)
        shutil.rmtree(os.path.join(self.cap, "datadir", "main", "blocks", "insight-index"))
        a.flavour = "full-insight"
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            quiet(snapshot.pack, a)
        a.flavour = "full"
        quiet(snapshot.pack, a)
        self.assertEqual(self.manifest_flavour_after(a), "full")

    def manifest_flavour_after(self, a):
        quiet(snapshot.finalize, a)
        return self.manifest()["flavour"]

    def test_statement_and_tarball_flavours_agree(self):
        self.add_insight()
        meta = os.path.join(self.cap, "meta.json")
        with open(meta) as f:
            m = json.load(f)
        m["flavour"] = "full"                   # a statement taken without the insight flags
        snapshot.dump(meta, m)
        a = argparse.Namespace(capture=self.cap, version=None, purpose=None)
        quiet(snapshot.pack, a)
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            quiet(snapshot.finalize, a)

    def test_full_insight_needs_the_index(self):
        self.build()                            # a full tarball, relabelled
        old = self.manifest()["tarball"]
        new = old.replace("-full.", "-full-insight.")
        parts = self.manifest()["parts"]
        for p in parts:
            os.rename(os.path.join(self.out, p["name"]), os.path.join(self.out, p["name"].replace(old, new)))
            p["name"] = p["name"].replace(old, new)
        self.rewrite_manifest(flavour="full-insight", tarball=new, parts=parts)
        self.assertTrue(any("full-insight without a file" in e for e in verify.verify(self.out)))

    def test_tar_entries_and_headers(self):
        self.build()
        with self.tar() as t:
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

    def published(self, have=None, code=0, **env):
        """Run publish-s3.sh against a stand-in aws; `have` maps a key already in the bucket to its size
        (head-object answers it). Returns the `s3 cp` destinations, in order."""
        log = os.path.join(self.tmp.name, "aws.log")
        if os.path.exists(log):
            os.remove(log)
        fake = os.path.join(self.tmp.name, "aws")
        sizes = "".join("  *%s*) echo %d; exit 0 ;;\n" % (k, v) for k, v in (have or {}).items())
        with open(fake, "w") as f:
            f.write("#!/bin/sh\necho \"$*\" >> %s\n"
                    "case \"$2\" in ls) exit 1 ;; esac\n"
                    "if [ \"$2\" = head-object ]; then case \"$*\" in\n%s  esac; exit 255; fi\n"
                    "[ \"$4\" = - ] && exit 1\nexit 0\n" % (log, sizes))
        os.chmod(fake, 0o700)
        r = subprocess.run(["bash", os.path.join(STATE, "mainnet", "publish-s3.sh"), self.out, "s3://bucket-x/snap"],
                           env=dict(os.environ, AWS=fake, **env), capture_output=True, text=True)
        self.assertEqual(r.returncode, code, r.stderr)
        self.publish_stderr, self.publish_stdout = r.stderr, r.stdout
        if not os.path.exists(log):
            return []
        with open(log) as f:
            return [l.split()[-1] for l in f.read().splitlines() if l.startswith("s3 cp") and not l.endswith(" -")]

    def test_publish_order(self):
        self.build()
        dests = self.published()
        base = "s3://bucket-x/snap/main/570000/"
        self.assertEqual(dests[0], base + "ycash6-main-570000-full.tar.gz.000")
        self.assertEqual(dests[-3:], [base + "manifest.json", base + "SHA256SUMS",
                                      "s3://bucket-x/snap/main/latest/manifest.json"])

    def test_publish_full_insight_has_its_own_latest(self):
        self.add_insight()
        self.build()
        dests = self.published()
        base = "s3://bucket-x/snap/main-insight/570000/"
        self.assertEqual(dests[0], base + "ycash6-main-570000-full-insight.tar.gz.000")
        self.assertEqual(dests[-3:], [base + "manifest.json", base + "SHA256SUMS",
                                      "s3://bucket-x/snap/main-insight/latest/manifest.json"])
        self.assertFalse(any("/snap/main/" in d for d in dests))

    def test_unexpected_file_fails(self):
        self.build()
        write(os.path.join(self.out, "notes.txt"), b"?")
        snapshot.write_sums(self.out)
        self.assertTrue(any("unexpected" in e for e in verify.verify(self.out)))


def noise(n, seed=b"n"):
    """n bytes that gzip cannot shrink (a hash chain), so a small tree packs to several parts."""
    out, h = b"", seed
    while len(out) < n:
        h = hashlib.sha256(h).digest()
        out += h
    return out[:n]


class Parts(Mainnet):
    """beta3 item 9 (`ycash-state/3`): the tarball stored in three parts verifies, joins byte for byte to
    the one-file `/2` tarball of the same tree, and every broken part, file or manifest is refused."""

    def setUp(self):
        super().setUp()
        write(os.path.join(self.cap, "datadir", "main", "blocks", "blk00001.dat"), noise(30000))
        root = os.path.join(self.cap, "datadir")
        entries = snapshot.bundle_entries(root, "main")
        self.one_file = os.path.join(self.tmp.name, "one-file.tar.gz")
        self.one_tree = snapshot.pack_tree(root, "main", entries, self.one_file)
        with open(self.one_file, "rb") as f:
            self.one = f.read()
        self.pb = -(-len(self.one) // 3)                   # ceil: exactly three parts
        self.build(part_bytes=self.pb)

    def part(self, i):
        return os.path.join(self.out, self.manifest()["parts"][i]["name"])

    def test_three_parts_are_the_one_file_tarball(self):
        m = self.manifest()
        self.assertEqual(len(m["parts"]), 3)
        self.assertEqual([p["bytes"] for p in m["parts"]], [self.pb, self.pb, len(self.one) - 2 * self.pb])
        self.assertEqual(self.joined(), self.one)
        self.assertEqual((m["sha256"], m["bytes"]), (hashlib.sha256(self.one).hexdigest(), len(self.one)))
        self.assertEqual(m["tree_sha256"], self.one_tree)
        self.assertEqual(verify.verify(self.out, tree=True), [])
        with open(os.path.join(self.out, "SHA256SUMS")) as f:
            sums = dict(reversed(line.split("  ")) for line in f.read().splitlines())
        for p in m["parts"]:
            self.assertEqual(sums[p["name"]], p["sha256"])
        self.assertNotIn(m["tarball"], sums)              # the whole stream is never a file of the bundle

    def test_a_flipped_byte_in_part_2(self):
        with open(self.part(1), "r+b") as f:
            b = f.read(1)
            f.seek(0)
            f.write(bytes([b[0] ^ 1]))
        errs = verify.verify(self.out)
        self.assertTrue(any(".001 does not match" in e for e in errs), errs)
        snapshot.write_sums(self.out)                     # sums rewritten to match: the manifest still refuses
        errs = verify.verify(self.out)
        self.assertTrue(any("SHA256SUMS line is not the manifest's" in e for e in errs), errs)
        self.assertTrue(any("joined in order" in e for e in errs), errs)

    def test_a_missing_part(self):
        os.remove(self.part(2))
        errs = verify.verify(self.out)
        self.assertTrue(any(".002 is missing" in e for e in errs), errs)
        snapshot.write_sums(self.out)
        self.assertTrue(any(".002 is missing" in e for e in verify.verify(self.out)))

    def test_a_short_middle_part(self):
        with open(self.part(1), "r+b") as f:
            f.truncate(self.pb - 1)
        snapshot.write_sums(self.out)
        errs = verify.verify(self.out)
        self.assertTrue(any(".001: %d bytes, the manifest says %d" % (self.pb - 1, self.pb) in e for e in errs), errs)

    def test_an_extra_file(self):
        write(os.path.join(self.out, "notes.txt"), b"?")
        snapshot.write_sums(self.out)
        self.assertTrue(any("unexpected" in e for e in verify.verify(self.out)))

    def test_parts_out_of_sequence(self):
        parts = self.manifest()["parts"]
        parts[1], parts[2] = parts[2], parts[1]
        self.rewrite_manifest(parts=parts)
        errs = verify.verify(self.out)
        self.assertTrue(any("part 1 is named" in e for e in errs), errs)

    def test_parts_size_rules(self):
        m = self.manifest()
        self.rewrite_manifest(part_bytes=self.pb + 1)    # a part shorter than part_bytes before the last
        self.assertTrue(any("every part but the last" in e for e in verify.verify(self.out)))
        self.rewrite_manifest(part_bytes=m["part_bytes"], bytes=m["bytes"] + 1)
        self.assertTrue(any("the parts hold" in e for e in verify.verify(self.out)))
        self.rewrite_manifest(bytes=m["bytes"], unpacked_bytes=m["unpacked_bytes"] + 1)
        self.assertTrue(any("unpacked_bytes" in e for e in verify.verify(self.out)))

    def test_a_v3_bundle_that_also_holds_the_whole_tarball(self):
        shutil.copyfile(self.one_file, os.path.join(self.out, self.manifest()["tarball"]))
        snapshot.write_sums(self.out)
        errs = verify.verify(self.out)                    # larger than a part: the size guard refuses it first
        self.assertTrue(any("tar.gz: %d bytes, over part_bytes" % len(self.one) in e for e in errs), errs)
        self.build()                                      # one part of 1 GiB: the whole tarball fits the guard
        shutil.copyfile(self.one_file, os.path.join(self.out, self.manifest()["tarball"]))
        snapshot.write_sums(self.out)
        errs = verify.verify(self.out)
        self.assertTrue(any("never holds the whole tarball" in e for e in errs), errs)

    def test_the_object_guards(self):
        write(os.path.join(self.out, "notes.txt"), noise(self.pb + 1))
        snapshot.write_sums(self.out)
        errs = verify.verify(self.out)
        self.assertTrue(any("notes.txt: %d bytes, over part_bytes" % (self.pb + 1) in e for e in errs), errs)
        os.remove(os.path.join(self.out, "notes.txt"))
        snapshot.write_sums(self.out)
        saved = verify.MAX_OBJECT_BYTES
        verify.MAX_OBJECT_BYTES = self.pb - 1             # stands in for 49 GiB: every format is held to it
        try:
            self.assertTrue(any("limit for any bundle object" in e for e in verify.verify(self.out)))
        finally:
            verify.MAX_OBJECT_BYTES = saved

    def test_a_one_file_v2_bundle_still_verifies(self):
        m = self.manifest()
        for p in m["parts"]:
            os.remove(os.path.join(self.out, p["name"]))
        shutil.copyfile(self.one_file, os.path.join(self.out, m["tarball"]))
        v2 = {k: v for k, v in m.items() if k not in ("parts", "part_bytes", "unpacked_bytes")}
        v2["format"] = "ycash-state/2"
        self.rewrite_manifest_to(v2)
        self.assertEqual(verify.verify(self.out, tree=True), [])
        self.rewrite_manifest_to(dict(v2, parts=m["parts"]))
        self.assertTrue(any("ycash-state/3 fields" in e for e in verify.verify(self.out)))

    def rewrite_manifest_to(self, m):
        snapshot.dump(os.path.join(self.out, "manifest.json"), m)
        snapshot.write_sums(self.out)

    def test_an_old_verifier_refuses_v3(self):
        """The reader of a format it does not know refuses it by `format` (bundle-parts.md §5)."""
        saved = verify.FORMATS
        verify.FORMATS = (verify.FORMAT, verify.FORMAT_V2)
        try:
            errs = verify.verify(self.out)
        finally:
            verify.FORMATS = saved
        self.assertTrue(any("format 'ycash-state/3', expected one of" in e for e in errs), errs)

    def test_pack_again_replaces_the_parts(self):
        first = self.manifest()["sha256"]
        write(os.path.join(self.out, self.manifest()["tarball"] + ".007.part"), b"left by a killed pack")
        self.build(part_bytes=self.pb * 2)                # two parts now; the third and the leftover go
        self.assertEqual(len(self.manifest()["parts"]), 2)
        self.assertEqual(self.manifest()["sha256"], first)
        self.assertEqual(verify.verify(self.out, tree=True), [])

    def test_publish_uploads_the_parts_first_and_skips_one_already_there(self):
        base = "s3://bucket-x/snap/main/570000/"
        names = [p["name"] for p in self.manifest()["parts"]]
        dests = self.published()
        self.assertEqual(dests[:3], [base + n for n in names])
        self.assertEqual(dests[-3:], [base + "manifest.json", base + "SHA256SUMS", "s3://bucket-x/snap/main/latest/manifest.json"])
        self.assertEqual(sorted(dests[3:-3]), [base + "statement-ycash6.json", base + "treestate.json"])
        dests = self.published(have={names[0]: self.pb, names[1]: 1})   # a re-run: part 0 is there, part 1 is short
        self.assertNotIn(base + names[0], dests)
        self.assertEqual(dests[:2], [base + names[1], base + names[2]])
        self.assertIn(names[0] + ": already uploaded", self.publish_stdout)

    def test_publish_refuses_an_object_over_the_guard(self):
        self.assertEqual(self.published(code=1, MAX_OBJECT_BYTES=str(self.pb - 1)), [])
        self.assertIn("object limit", self.publish_stderr)



# Parts reuses Mainnet's capture and helpers, not its tests (those run once, in Mainnet).
for _name in [n for n in vars(Mainnet) if n.startswith("test_")]:
    setattr(Parts, _name, None)

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
