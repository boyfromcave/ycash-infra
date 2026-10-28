#!/usr/bin/env python3
"""Summarise import.sh results as Markdown and compare them.

    python3 -I summarize.py RESULT.json [RESULT.json ...]

Prints a table (for the job summary) and exits 1 when a result failed or two results disagree:
  * every result must be ok;
  * all results must end on the same tip hash (the prefix is one chain);
  * within one node line, the checkpoints and full results must have the same gettxoutsetinfo
    hash_serialized and total_amount (the same blocks give the same coin set; the two lines'
    serialisations need not agree, so lines are not compared with each other).
Only validated fields are printed (hex, integers, known words), so node output cannot inject
Markdown into the summary.
"""
import json
import re
import sys


def clean(v, pattern=r"[0-9A-Za-z._:-]{1,80}"):
    s = "" if v is None else str(v)
    return s if re.fullmatch(pattern, s) else ("-" if not s else "(invalid)")


def main(paths):
    rows, problems = [], []
    for p in paths:
        with open(p, encoding="utf-8") as f:
            rows.append(json.load(f))
    rows.sort(key=lambda r: (str(r.get("line")), str(r.get("mode"))))
    out = ["| line | mode | result | tip | hashes checked | hash_serialized | total_amount | txouts | import s | datadir MiB |",
           "|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        u = r.get("utxo") or {}
        hc = r.get("hash_checks") or {}
        size = r.get("datadir_bytes")
        out.append("| %s | %s | %s | `%s` | %s (%s bad) | `%s` | %s | %s | %s | %s |" % (
            clean(r.get("line")), clean(r.get("mode")), "ok" if r.get("ok") else "**FAILED**",
            clean((r.get("prefix") or {}).get("tip_hash"), r"[0-9a-f]{64}")[:16],
            clean(hc.get("checked"), r"\d+"), len(hc.get("mismatches") or []),
            clean(u.get("hash_serialized"), r"[0-9a-f]{64}")[:16], clean(u.get("total_amount"), r"[0-9.]+"),
            clean(u.get("txouts"), r"\d+"), clean((r.get("seconds") or {}).get("import"), r"\d+"),
            clean(size // (1 << 20) if isinstance(size, int) else None, r"\d+")))
        if not r.get("ok"):
            problems.append("%s %s failed: %s" % (clean(r.get("line")), clean(r.get("mode")),
                                                   re.sub(r"[^ -~]", "?", str(r.get("failure")))[:300]))
    tips = {(r.get("prefix") or {}).get("tip_hash") for r in rows if r.get("ok")}
    if len(tips) > 1:
        problems.append("results end on different tips: %s" % sorted(clean(t) for t in tips))
    lines = {}
    for r in rows:
        if r.get("ok"):
            u = r.get("utxo") or {}
            lines.setdefault(r.get("line"), {})[r.get("mode")] = (u.get("hash_serialized"), u.get("total_amount"))
    for line, modes in sorted(lines.items(), key=lambda x: str(x[0])):
        if len(set(modes.values())) > 1:
            problems.append("%s: checkpoints and full disagree on the coin set: %s" % (clean(line), modes))
    out.append("")
    out.extend("- " + p for p in problems) if problems else out.append("All results ok and consistent.")
    print("\n".join(out))
    return 1 if problems else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1:]))
