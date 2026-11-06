#!/usr/bin/env python3
"""The prefix files shipped in the seeds module match the testnet chart's prefixRestore.

Terraform downloads only infra/testnet-seeds/nodes, so the module cannot read
charts/ycash-testnet. The fields it uses are copied under nodes/prefix and checked here.
"""
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[4]
chart = root / "charts/ycash-testnet"
module = root / "infra/testnet-seeds/nodes/prefix"
keys = ("baseUrl", "sha256sums", "network", "lastHeight")
names = ("values.yaml", "values-yb-fast.yaml", "values-yb-slow.yaml", "values-legacy.yaml")


def fields(path):
    found = {}
    inside = False
    for line in path.read_text().splitlines():
        if line.startswith("prefixRestore:"):
            inside = True
            continue
        if not inside:
            continue
        if line and not line.startswith(" ") and not line.startswith("#"):
            break
        if not line.startswith("  ") or line.startswith("   ") or line.startswith("  #"):
            continue
        key, _, rest = line.strip().partition(":")
        if key not in keys:
            continue
        value = rest.split("#", 1)[0].strip().strip('"').strip("'")
        found[key] = int(value) if value.isdigit() else value
    return found


bad = False
for name in names:
    a, b = fields(chart / name), fields(module / name)
    for key in keys:
        if a.get(key) != b.get(key):
            bad = True
            print(f"{name} {key}: chart {a.get(key)!r} != module {b.get(key)!r}", file=sys.stderr)
if bad:
    sys.exit(1)
print("prefix files match the chart")
