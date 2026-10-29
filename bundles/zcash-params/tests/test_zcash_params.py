# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""The Zcash parameter mirror, offline.

- bundles/zcash-params/SHA256SUMS is the single source of the three sums: well-formed, sorted, and
  byte-identical to the testnet chart's copy (charts/ycash-testnet/files/zcash-params.SHA256SUMS).
- It equals what ycash-dd's zcutil/fetch-params.sh pins, when that script is at $YCASH_DD (default
  ../ycash-dd beside this repository, the workspace layout); skipped otherwise.
- The release tag and URL agree across the workflow, the chart default and the README.
- charts/ycash-testnet/files/zcash-params.sh, the chart's init container, against a fake curl:
  fetches and verifies, keeps a good file, refetches a bad one, refuses a mismatch, a non-https URL
  and a malformed sums file.
"""

import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLE = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(BUNDLE))
SUMS = os.path.join(BUNDLE, "SHA256SUMS")
CHART_SUMS = os.path.join(REPO, "charts/ycash-testnet/files/zcash-params.SHA256SUMS")
INIT = os.path.join(REPO, "charts/ycash-testnet/files/zcash-params.sh")
WORKFLOW = os.path.join(REPO, ".github/workflows/zcash-params.yml")
VALUES = os.path.join(REPO, "charts/ycash-testnet/values.yaml")
README = os.path.join(BUNDLE, "README.md")
NAMES = ["sapling-output.params", "sapling-spend.params", "sprout-groth16.params"]
TAG = "zcash-params-v1"
BASE = "https://github.com/boyfromcave/ycash-infra/releases/download/" + TAG


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def parse_sums(text):
    out = {}
    for line in text.splitlines():
        m = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
        if not m:
            raise ValueError(f"not a sha256sum line: {line!r}")
        out[m.group(2)] = m.group(1)
    return out


class Sums(unittest.TestCase):
    def test_format(self):
        text = read(SUMS)
        self.assertTrue(text.endswith("\n"))
        sums = parse_sums(text)
        self.assertEqual(list(sums), NAMES, "the three files, sorted by name")

    def test_chart_copy_is_identical(self):
        with open(SUMS, "rb") as a, open(CHART_SUMS, "rb") as b:
            self.assertEqual(a.read(), b.read(), "copy bundles/zcash-params/SHA256SUMS into the chart")

    def test_equals_fetch_params_sh(self):
        ycash_dd = os.environ.get("YCASH_DD") or os.path.join(os.path.dirname(REPO), "ycash-dd")
        script = os.path.join(ycash_dd, "zcutil/fetch-params.sh")
        if not os.path.isfile(script):
            self.skipTest(f"{script} not present (set YCASH_DD to a ycash-dd tree)")
        text = read(script)
        var = dict(re.findall(r"^([A-Z0-9_]+_NAME)='([^']+)'$", text, re.M))
        pinned = {}
        for v, h in re.findall(r'^\s*fetch_params "\$([A-Z0-9_]+)" "[^"]*" "([0-9a-f]{64})"$', text, re.M):
            pinned[var[v]] = h
        self.assertEqual(pinned, parse_sums(read(SUMS)))
        self.assertIn('DOWNLOAD_URL="https://download.z.cash/downloads"', text)


class Release(unittest.TestCase):
    def test_tag_and_url_agree(self):
        wf = read(WORKFLOW)
        self.assertIn(f"TAG: {TAG}", wf)
        self.assertIn(f"url: {BASE}\n", read(VALUES))
        readme = read(README)
        for n in NAMES:
            self.assertIn(f"{BASE}/{n}", readme)
        for n, h in parse_sums(read(SUMS)).items():
            self.assertIn(h, readme, f"README shows the sum of {n}")


FAKE_CURL = r"""#!/bin/sh
# fake curl: copies $FAKE_ROOT/<last path segment of the URL> to the -o file; logs each URL
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; --proto|--retry|--retry-delay|-C) shift ;; -*) ;; *) url="$1" ;; esac
  shift
done
echo "$url" >> "$FAKE_LOG"
src="$FAKE_ROOT/${url##*/}"
[ -f "$src" ] || exit 22
cp "$src" "$out"
"""


class InitContainer(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.t)
        self.bin = os.path.join(self.t, "bin")
        self.origin = os.path.join(self.t, "origin")
        self.dir = os.path.join(self.t, "params")
        self.log = os.path.join(self.t, "curl.log")
        os.makedirs(self.bin)
        os.makedirs(self.origin)
        with open(os.path.join(self.bin, "curl"), "w") as f:
            f.write(FAKE_CURL)
        os.chmod(os.path.join(self.bin, "curl"), 0o700)
        self.content = {n: (n * 1000).encode() for n in NAMES}
        for n, b in self.content.items():
            with open(os.path.join(self.origin, n), "wb") as f:
                f.write(b)
        self.sums = os.path.join(self.t, "SHA256SUMS")
        self.write_sums({n: hashlib.sha256(b).hexdigest() for n, b in self.content.items()})

    def write_sums(self, sums, extra=""):
        with open(self.sums, "w") as f:
            f.write("".join(f"{h}  {n}\n" for n, h in sorted(sums.items())) + extra)

    def run_init(self, url="https://mirror.example/zcash-params-v1"):
        env = {
            "PATH": self.bin + os.pathsep + os.environ["PATH"],
            "HOME": self.t,
            "ZCASH_PARAMS_URL": url,
            "ZCASH_PARAMS_SUMS": self.sums,
            "PARAMS_DIR": self.dir,
            "FAKE_ROOT": self.origin,
            "FAKE_LOG": self.log,
        }
        return subprocess.run(["sh", INIT], env=env, capture_output=True, text=True)

    def fetched(self):
        if not os.path.exists(self.log):
            return []
        return read(self.log).split()

    def test_fetches_and_verifies(self):
        r = self.run_init()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(sorted(os.listdir(self.dir)), NAMES)
        for n in NAMES:
            with open(os.path.join(self.dir, n), "rb") as f:
                self.assertEqual(f.read(), self.content[n])
        self.assertEqual(self.fetched(), [f"https://mirror.example/zcash-params-v1/{n}" for n in NAMES])

    def test_keeps_good_files(self):
        self.assertEqual(self.run_init().returncode, 0)
        os.remove(self.log)
        r = self.run_init()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.fetched(), [])

    def test_refetches_a_bad_file(self):
        self.assertEqual(self.run_init().returncode, 0)
        with open(os.path.join(self.dir, "sapling-spend.params"), "wb") as f:
            f.write(b"truncated")
        os.remove(self.log)
        r = self.run_init()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.fetched(), ["https://mirror.example/zcash-params-v1/sapling-spend.params"])

    def test_refuses_a_mismatch(self):
        with open(os.path.join(self.origin, "sprout-groth16.params"), "wb") as f:
            f.write(b"not the real file")
        r = self.run_init()
        self.assertEqual(r.returncode, 1)
        self.assertIn("REFUSED: sprout-groth16.params hashes to", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "sprout-groth16.params")))
        self.assertFalse(os.path.exists(os.path.join(self.dir, "sprout-groth16.params.dl")))

    def test_refuses_a_failed_download(self):
        os.remove(os.path.join(self.origin, "sapling-output.params"))
        r = self.run_init()
        self.assertEqual(r.returncode, 1)
        self.assertIn("download of sapling-output.params failed", r.stderr)

    def test_refuses_http(self):
        r = self.run_init(url="http://mirror.example/zcash-params-v1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("must be https://", r.stderr)
        self.assertEqual(self.fetched(), [])

    def test_refuses_a_malformed_sums_file(self):
        good = {n: hashlib.sha256(b).hexdigest() for n, b in self.content.items()}
        for sums, extra in [
            ({k: v for k, v in good.items() if k != "sprout-groth16.params"}, ""),
            (good, "0" * 64 + "  ../evil\n"),
            ({**good, "sapling-spend.params": "XYZ"}, ""),
        ]:
            with self.subTest(extra=extra, names=sorted(sums)):
                self.write_sums(sums, extra)
                r = self.run_init()
                self.assertEqual(r.returncode, 1, r.stdout)
                self.assertIn("REFUSED", r.stderr)
                self.assertEqual(self.fetched(), [])

    def test_the_chart_sums_pass_the_format_check(self):
        shutil.copy(CHART_SUMS, self.sums)
        # the real sums do not match the fake content: the run must get past the sums check and
        # refuse on the first file's hash, not on the file's format
        r = self.run_init()
        self.assertEqual(r.returncode, 1)
        self.assertIn("REFUSED: sapling-output.params hashes to", r.stderr)


if __name__ == "__main__":
    unittest.main()
