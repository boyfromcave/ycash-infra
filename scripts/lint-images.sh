#!/usr/bin/env bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# Every image the chart renders is pinned: a tag that is not `latest`, or a digest (audit 06/I-1).
# Fails on `tag: latest` in any values file and on any rendered `image:` with no tag/digest or :latest,
# for the kind values and for the EKS values with the tags make eks-deploy sets; for the lightwallet
# chart's testnet values (over the EKS values) and for charts/ycash-testnet's kind and EKS values. The
# testnet value sets leave the release digests to the deploy (plan §6.1: release images by digest),
# so they render here with a placeholder digest: what this checks for them is that every OTHER image
# in the render is pinned and that no values file says latest. charts/ycash-testnet itself refuses
# to render an image with neither tag nor digest (templates/_helpers.tpl yt.image).
# Usage: scripts/lint-images.sh   (run from the repository root; CI and `make lint` call it)
set -euo pipefail
cd "$(dirname "$0")/.."
CHART=charts/ycash-lightwallet
TESTNET=charts/ycash-testnet
fail=0
# a syntactically valid digest that pins nothing: stands in for the release digests set at deploy
PLACEHOLDER=sha256:0000000000000000000000000000000000000000000000000000000000000000

if grep -nE '^[^#]*tag:[[:space:]]*"?latest"?' $CHART/values*.yaml $TESTNET/values*.yaml; then
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

TESTNET_LITE_SET=()
for c in ycashd lightwalletd yindex web; do TESTNET_LITE_SET+=(--set "images.$c.digest=$PLACEHOLDER"); done
TESTNET_EKS_SET=(--set "images.ycashd.digest=$PLACEHOLDER" --set "images.ycashdLegacy.digest=$PLACEHOLDER")

helm template t $CHART -f $CHART/values-kind.yaml | check kind || fail=1
helm template t $CHART -f $CHART/values-eks.yaml "${EKS_SET[@]}" | check eks || fail=1
helm template t $CHART -f $CHART/values-eks.yaml -f $CHART/values-testnet.yaml "${TESTNET_LITE_SET[@]}" | check lightwallet-testnet || fail=1
helm template t $TESTNET -f $TESTNET/values-kind.yaml | check testnet-kind || fail=1
helm template t $TESTNET -f $TESTNET/values-eks.yaml "${TESTNET_EKS_SET[@]}" | check testnet-eks || fail=1
exit $fail
