#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Fail when HEAD adds a failing Checkov check that BASE does not have (the PR gate, SECURITY-CI.md).

  contrib/secops/checkov-gate.py BASE_results_json.json HEAD_results_json.json

Checkov without a Prisma Cloud key has no severities, so the gate is "no new failing check" rather than
"no new HIGH". A failure is keyed by check id, resource and file, so a line move is not new. In the
rendered charts (contrib/secops/checkov.sh OUTDIR/rendered/) the file is left out of the key: one
chart rendered with one more value set (kind, EKS, the testnet) repeats the same resources, so adding
a render is not new by itself; a failing check on a resource no render failed before is.
Output: a Markdown list of the new failures on stdout (for the step summary).
"""
import json
import os
import sys


def failures(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, dict):
        data = [data]
    keys = {}
    for report in data:
        for c in report.get("results", {}).get("failed_checks", []):
            fpath = c.get("file_path", "")
            shown = fpath.lstrip("/")
            if "/rendered/" in c.get("file_abs_path", "") or "rendered" in fpath:
                shown = "rendered/" + os.path.basename(fpath)
                fpath = "rendered/"
            key = (c["check_id"], c.get("resource", ""), fpath.lstrip("/"))
            name, files = keys.setdefault(key, (c.get("check_name", ""), set()))
            files.add(shown)
    return keys


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    base, head = failures(sys.argv[1]), failures(sys.argv[2])
    new = sorted(set(head) - set(base))
    print("Checkov: %d failing checks on the base, %d on this PR (a rendered resource counted once), %d new."
          % (len(base), len(head), len(new)))
    for key in new:
        name, files = head[key]
        print("- `%s` %s: `%s` in %s" % (key[0], name, key[1], ", ".join("`%s`" % f for f in sorted(files))))
    return 1 if new else 0


if __name__ == "__main__":
    sys.exit(main())
