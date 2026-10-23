#!/usr/bin/env python3
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
"""Fail when HEAD adds a failing Checkov check that BASE does not have (the PR gate, SECURITY-CI.md).

  contrib/secops/checkov-gate.py BASE_results_json.json HEAD_results_json.json

Checkov without a Prisma Cloud key has no severities, so the gate is "no new failing check" rather than
"no new HIGH". A failure is keyed by check id, resource and file (rendered files keyed by name), so a
line move is not new. Output: a Markdown list of the new failures on stdout (for the step summary).
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
            if "/rendered/" in c.get("file_abs_path", "") or "rendered" in fpath:
                fpath = "rendered/" + os.path.basename(fpath)
            key = (c["check_id"], c.get("resource", ""), fpath.lstrip("/"))
            keys[key] = c.get("check_name", "")
    return keys


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    base, head = failures(sys.argv[1]), failures(sys.argv[2])
    new = sorted(set(head) - set(base))
    print("Checkov: %d failing checks on the base, %d on this PR, %d new." % (len(base), len(head), len(new)))
    for cid, res, path in new:
        print("- `%s` %s: `%s` in `%s`" % (cid, head[(cid, res, path)], res, path))
    return 1 if new else 0


if __name__ == "__main__":
    sys.exit(main())
