# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Offline tests for the state bundle (bundles/state/FORMAT.md): the snapshotter's steps
(charts/ycash-testnet/files/snapshot.sh) against a stand-in node (tests/mocknode), and verify.py.

Needs sh, GNU tar, gzip, jq, curl and sha256sum on PATH (as the node image has).
Run: python3 -I -m unittest discover -s bundles/state/tests -v
"""

import hashlib
import http.server
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(STATE))
SNAPSHOT = os.path.join(ROOT, "charts", "ycash-testnet", "files", "snapshot.sh")
VERIFY = os.path.join(STATE, "verify.py")
MOCK = os.path.join(HERE, "mocknode")
NET = "testnet-yb-fast"
H = 512640

sys.path.insert(0, STATE)
import verify as V  # noqa: E402


class RefNode:
    """The reference node pick asks for its tip (JSON-RPC, basic auth checked)."""

    def __init__(self, tip):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                ok = self.headers.get("Authorization") == "Basic dTpw"      # u:p
                body = json.dumps({"result": tip if req["method"] == "getblockcount" else None, "error": None}).encode()
                self.send_response(200 if ok else 401)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}/"


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.work = os.path.join(self.tmp, "work")
        self.src = os.path.join(self.tmp, "src")
        self.dd = os.path.join(self.tmp, "dd")
        for d in (self.work, self.src, self.dd):
            os.makedirs(d)

    def run_step(self, step, datadir=None, ok=True, **env):
        e = {"PATH": MOCK + os.pathsep + os.environ["PATH"], "WORK": self.work, "DATADIR": datadir or self.src,
             "STATE": self.src, "NETDIR": NET, "LINE": "ycash6", "YCASHD_RPC_USER": "u", "YCASHD_RPC_PASSWORD": "p",
             "NODE_TIMEOUT": "60", "POLL": "0.2", "MOCK_AWS_LOG": os.path.join(self.tmp, "aws.log")}
        e.update({k: str(v) for k, v in env.items()})
        r = subprocess.run(["sh", SNAPSHOT, step], env=e, capture_output=True, text=True, timeout=120)
        if ok and r.returncode != 0:
            self.fail(f"snapshot.sh {step} failed ({r.returncode}):\n{r.stdout}\n{r.stderr}")
        if not ok and r.returncode == 0:
            self.fail(f"snapshot.sh {step} succeeded, expected a refusal:\n{r.stdout}")
        return r

    def bundle(self, dd_env=None, **env):
        self.run_step("pick", SNAP_HEIGHT=H, **env)
        self.run_step("produce", **env)
        self.run_step("restore-check", **env)
        self.run_step("verify", datadir=self.dd, LINE="ycash-dd", **{**env, **(dd_env or {})})
        return self.run_step("finalize", ok=not dd_env, **env)

    def out(self, name=""):
        return os.path.join(self.work, "out", name)


class Pick(Base):
    def test_height_from_the_reference_tip(self):
        ref = RefNode(513700)
        self.addCleanup(ref.srv.shutdown)
        self.run_step("pick", REF_RPC_URL=ref.url)
        self.assertEqual(open(os.path.join(self.work, "HEIGHT")).read().strip(), "512640")   # (513700-1000)//1440*1440

    def test_nothing_new_or_below_the_fork(self):
        ref = RefNode(513700)
        self.addCleanup(ref.srv.shutdown)
        os.makedirs(os.path.join(self.src, ".snapshotter"))
        with open(os.path.join(self.src, ".snapshotter", "last-height"), "w") as f:
            f.write("512640\n")
        self.run_step("pick", REF_RPC_URL=ref.url)
        self.assertTrue(os.path.exists(os.path.join(self.work, "SKIP")))
        self.run_step("pick", REF_RPC_URL=ref.url, SNAP_FORCE=1)
        self.assertFalse(os.path.exists(os.path.join(self.work, "SKIP")))
        self.run_step("pick", SNAP_HEIGHT=500000)
        self.assertTrue(os.path.exists(os.path.join(self.work, "SKIP")))
        # a skipped run does nothing in the later steps
        for step in ("produce", "restore-check", "finalize", "publish-s3"):
            self.assertIn("skipped", self.run_step(step).stdout)

    def test_refuses_a_bad_height_or_an_unanswering_reference(self):
        self.run_step("pick", ok=False, SNAP_HEIGHT="12a")
        self.run_step("pick", ok=False, REF_RPC_URL="http://127.0.0.1:1/")


class Bundle(Base):
    def test_full_run_and_verify(self):
        self.bundle()
        m = json.load(open(self.out("manifest.json")))
        tb = f"ycash6-{NET}-{H}-full.tar.gz"
        self.assertEqual((m["format"], m["network"], m["height"], m["tarball"], m["version"], m["line"]),
                         ("ycash-state/1", NET, H, tb, "6.22.0-rc1", "ycash6"))
        self.assertEqual(m["verifiers"], ["ycash-dd", "ycash6"])
        self.assertEqual(m["created"], "2028-04-04T08:00:00Z")       # block H's time: 1_800_000_000 + 75 * H
        self.assertEqual(m["blockhash"], hashlib.sha256(f"block|{H}|".encode()).hexdigest())
        self.assertEqual(open(self.out("statement-ycash6.json")).read(), open(self.out("statement-ycash-dd.json")).read())
        self.assertEqual(V.verify(self.out()), [])
        r = subprocess.run([sys.executable, "-I", VERIFY, self.out()], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(open(os.path.join(self.src, ".snapshotter", "last-height")).read().strip(), str(H))
        with tarfile.open(self.out(tb)) as t:
            names = [e.name.rstrip("/") for e in t]
        for left_out in ("wallet.dat", "peers.dat", "debug.log", ".lock", "database", "yellowback/carriers.dat",
                         "blocks/index/LOCK", "blocks/index/LOG", "chainstate/LOCK", "blocks/insight-index", "mock-state.json"):
            self.assertNotIn(f"{NET}/{left_out}", names)
        for kept in ("blocks", "blocks/index/000003.ldb", "blocks/rev00000.dat", "chainstate/000005.ldb",
                     "vaults/000002.ldb", "yellowback/000002.ldb"):
            self.assertIn(f"{NET}/{kept}", names)

    def test_full_insight_keeps_the_insight_index(self):
        self.bundle(FLAVOUR="full-insight")
        with tarfile.open(self.out(f"ycash6-{NET}-{H}-full-insight.tar.gz")) as t:
            self.assertIn(f"{NET}/blocks/insight-index/000001.ldb", [e.name for e in t])
        self.assertEqual(V.verify(self.out()), [])

    def test_statements_without_yed(self):
        self.bundle(MOCK_NO_YED=1)
        s = json.load(open(self.out("statement-ycash6.json")))
        self.assertIsNone(s["yed_statehash"])
        self.assertIsNotNone(s["vault_statehash"])

    def test_disagreeing_verifier_stops_the_run(self):
        r = self.bundle(dd_env={"MOCK_SALT": "another chain"})
        self.assertIn("disagree", r.stderr)
        self.assertFalse(os.path.exists(self.out("manifest.json")))
        self.assertFalse(os.path.exists(os.path.join(self.src, ".snapshotter", "last-height")))

    def test_statement_fields(self):
        self.bundle(STATEMENT_FIELDS="network height blockhash chainwork vault_statehash yed_statehash")
        self.assertNotIn("utxo_hash_serialized", json.load(open(self.out("statement-ycash-dd.json"))))
        self.assertEqual(V.verify(self.out()), [])

    def test_kept_verifier_datadir_has_no_failed_mark(self):
        self.bundle()
        st = json.load(open(os.path.join(self.dd, NET, "mock-state.json")))
        self.assertNotIn("invalid", st)                 # reconsiderblock after the statement
        self.assertEqual(st["active"], st["stored"])

    def test_pack_is_deterministic(self):
        self.run_step("pick", SNAP_HEIGHT=H)
        self.run_step("produce")
        tb = self.out(f"ycash6-{NET}-{H}-full.tar.gz")
        first = open(tb, "rb").read()
        # the same files with other times, owners' modes and creation order give the same bytes
        for dirpath, _, files in os.walk(os.path.join(self.src, NET)):
            for f in files:
                p = os.path.join(dirpath, f)
                os.utime(p, (1_234_567_890, 1_234_567_890))
                os.chmod(p, 0o600)
        os.remove(tb)
        self.run_step("pick", SNAP_HEIGHT=H, SNAP_FORCE=1)
        self.run_step("produce", SNAP_FORCE=1)
        self.assertEqual(open(tb, "rb").read(), first)

    def test_restore_check_refuses_unsafe_tarballs(self):
        self.run_step("pick", SNAP_HEIGHT=H)
        tb = self.out(f"ycash6-{NET}-{H}-full.tar.gz")
        for bad in ("../escape", f"{NET}/blocks/../../x", "/abs", "elsewhere/blocks/x"):
            with tarfile.open(tb, "w:gz") as t:
                info = tarfile.TarInfo(bad)
                info.size = 1
                t.addfile(info, io.BytesIO(b"x"))
            self.assertIn("path", self.run_step("restore-check", ok=False).stderr, bad)
        with tarfile.open(tb, "w:gz") as t:
            info = tarfile.TarInfo(f"{NET}/blocks/link")
            info.type = tarfile.SYMTYPE
            info.linkname = "/etc/passwd"
            t.addfile(info)
        self.assertIn("neither a file nor a directory", self.run_step("restore-check", ok=False).stderr)

    def test_publish_s3_order(self):
        self.bundle()
        self.run_step("publish-s3", S3_BUCKET="b", S3_PREFIX="state")
        calls = [line.split() for line in open(os.path.join(self.tmp, "aws.log"))]
        dests = [c[-1] for c in calls]
        base = f"s3://b/state/{NET}"
        self.assertEqual(dests, [f"{base}/{H}/ycash6-{NET}-{H}-full.tar.gz", f"{base}/{H}/statement-ycash-dd.json",
                                 f"{base}/{H}/statement-ycash6.json", f"{base}/{H}/SHA256SUMS",
                                 f"{base}/{H}/manifest.json", f"{base}/latest/manifest.json"])

    def test_publish_github(self):
        self.bundle()
        seen = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                seen.append((self.path, self.headers.get("Authorization"), body))
                out = json.dumps({"id": 7}).encode()
                self.send_response(201)
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

            def log_message(self, *a):
                pass

        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.shutdown)
        url = f"http://127.0.0.1:{srv.server_address[1]}"
        self.run_step("publish-github", GH_TOKEN="t0k", GITHUB_REPOSITORY="o/r", GITHUB_API=url, GITHUB_UPLOADS=url)
        self.assertEqual(seen[0][0], "/repos/o/r/releases")
        rel = json.loads(seen[0][2])
        self.assertEqual((rel["tag_name"], rel["draft"]), (f"state-{NET}-{H}", True))
        self.assertTrue(all(a == "Bearer t0k" for _, a, _ in seen))
        assets = sorted(p.split("name=")[1] for p, _, _ in seen[1:])
        self.assertEqual(assets, ["SHA256SUMS", "manifest.json", "statement-ycash-dd.json", "statement-ycash6.json"])


class Verify(Base):
    def setUp(self):
        super().setUp()
        self.bundle()

    def test_detects_tampering(self):
        with open(self.out("statement-ycash6.json"), "a") as f:
            f.write(" ")
        errs = V.verify(self.out())
        self.assertTrue(any("SHA256SUMS" in e for e in errs))
        self.assertTrue(any("not canonical" in e for e in errs))

    def test_detects_a_wrong_manifest(self):
        m = json.load(open(self.out("manifest.json")))
        m["height"] += 1
        with open(self.out("manifest.json"), "w") as f:
            f.write(V.canonical(m))
        errs = V.verify(self.out())
        self.assertTrue(any("disagrees with the manifest" in e for e in errs))
        self.assertTrue(any("tarball" in e for e in errs))

    def test_detects_unfixed_tar_headers(self):
        tb = self.out(f"ycash6-{NET}-{H}-full.tar.gz")
        with tarfile.open(tb, "w:gz") as t:
            info = tarfile.TarInfo(f"{NET}/blocks")
            info.type = tarfile.DIRTYPE
            info.mtime = 5
            t.addfile(info)
        errs = []
        V.check_tar(tb, NET, "full", errs)
        self.assertTrue(any("non-fixed header" in e for e in errs))
        self.assertTrue(any("chainstate" in e for e in errs))


if __name__ == "__main__":
    unittest.main()
