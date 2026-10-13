#!/usr/bin/env bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# Every image the chart renders is pinned: a tag that is not `latest`, or a digest (audit 06/I-1).
# Fails on `tag: latest` in any values file and on any rendered `image:` with no tag/digest or :latest,
# for the kind values and for the EKS values with the tags make eks-deploy sets.
# Usage: scripts/lint-images.sh   (run from the repository root; CI and `make lint` call it)
set -euo pipefail
cd "$(dirname "$0")/.."
CHART=charts/ycash-lightwallet
fail=0

if grep -nE '^[^#]*tag:[[:space:]]*"?latest"?' $CHART/values*.yaml; then
  echo "lint-images: a values file uses tag latest; pin a version tag or a digest" >&2; fail=1
fi

EKS_SET=(--set gateway.host=lite.example.org)
for c in ycashd lightwalletd yindex web; do
  EKS_SET+=(--set "images.$c.repository=0.dkr.ecr.us-east-1.amazonaws.com/ycash/$c" --set "images.$c.tag=rev")
done

check() {  # $1 = label, stdin = rendered manifests
  local label=$1 bad
  bad=$(grep -E '^[[:space:]]*(-[[:space:]]*)?image:' | sed -E 's/^[^:]*image:[[:space:]]*//; s/^"//; s/"$//' | sort -u |
        awk '{ ref=$0; last=ref; sub(/.*\//, "", last);
               if (ref ~ /@sha256:[0-9a-f]{64}$/) next;
               if (last !~ /:/ || last ~ /:latest$/ || last ~ /:$/) print }')
  if [ -n "$bad" ]; then
    echo "lint-images ($label): unpinned image(s):" >&2; echo "$bad" | sed 's/^/  /' >&2; return 1
  fi
  echo "lint-images ($label): every rendered image is pinned"
}

helm template t $CHART -f $CHART/values-kind.yaml | check kind || fail=1
helm template t $CHART -f $CHART/values-eks.yaml "${EKS_SET[@]}" | check eks || fail=1
exit $fail
