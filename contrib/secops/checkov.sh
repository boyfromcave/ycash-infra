#!/usr/bin/env bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# Checkov over everything this repository deploys: infra/eks and infra/testnet-seeds (Terraform); the lightwallet chart rendered
# for kind, for EKS and for the testnet (values-testnet.yaml over EKS); charts/ycash-testnet rendered for
# kind and EKS; images/*/Dockerfile and bundles/*/Dockerfile. Policy: .checkov.yaml. Report only (exit 0
# unless checkov itself fails); contrib/secops/checkov-gate.py decides what fails a PR.
# The testnet value sets leave the release image digests to the deploy, so they render here with a
# placeholder digest, as scripts/lint-images.sh does. A render whose chart or values file is absent
# (the PR gate runs this script on the base too) is skipped.
# Usage: contrib/secops/checkov.sh OUTDIR    (needs checkov and helm on PATH; run from anywhere)
#   -> OUTDIR/results_json.json, OUTDIR/results_sarif.sarif,
#      OUTDIR/rendered/{kind,eks,lightwallet-testnet,testnet-kind,testnet-eks}.yaml
set -euo pipefail
out=$(realpath -m "${1:?usage: checkov.sh OUTDIR}")
cd "$(dirname "$0")/../.."
CHART=charts/ycash-lightwallet
TESTNET=charts/ycash-testnet
PLACEHOLDER=sha256:0000000000000000000000000000000000000000000000000000000000000000
mkdir -p "$out/rendered"
# The EKS render with the values make eks-deploy sets (as scripts/lint-images.sh).
EKS_SET=(--set gateway.host=lite.example.org)
for c in ycashd lightwalletd yindex web; do
  EKS_SET+=(--set "images.$c.repository=0.dkr.ecr.us-east-1.amazonaws.com/ycash/$c" --set "images.$c.tag=rev")
done
helm template t $CHART -f $CHART/values-kind.yaml > "$out/rendered/kind.yaml"
helm template t $CHART -f $CHART/values-eks.yaml "${EKS_SET[@]}" > "$out/rendered/eks.yaml"
if [ -f $CHART/values-testnet.yaml ]; then
  LITE_SET=()
  for c in ycashd lightwalletd yindex web; do LITE_SET+=(--set "images.$c.digest=$PLACEHOLDER"); done
  helm template t $CHART -f $CHART/values-eks.yaml -f $CHART/values-testnet.yaml "${LITE_SET[@]}" \
    > "$out/rendered/lightwallet-testnet.yaml"
fi
if [ -d $TESTNET ]; then
  helm template t $TESTNET -f $TESTNET/values-kind.yaml > "$out/rendered/testnet-kind.yaml"
  # EKS with the prefix restore on (as the testnet will deploy it, plan §4.0), so its init containers
  # are scanned too; the URL, the pin and the framer image are placeholders.
  helm template t $TESTNET -f $TESTNET/values-eks.yaml \
    --set "images.ycashd.digest=$PLACEHOLDER" --set "images.ycashdLegacy.digest=$PLACEHOLDER" \
    --set prefixRestore.enabled=true --set prefixRestore.baseUrl=https://prefix.example.org/v1 \
    --set "prefixRestore.sha256sums=${PLACEHOLDER#sha256:}" \
    --set images.prefixFrame.repository=ghcr.io/example/prefix-frame --set "images.prefixFrame.digest=$PLACEHOLDER" \
    > "$out/rendered/testnet-eks.yaml"
fi
# images/ and bundles/ (the prefix pack image); checkov ignores -f beside -d, so whole directories
dockerfiles=(-d images)
if [ -d bundles ]; then dockerfiles+=(-d bundles); fi
terraform_dirs=(-d infra/eks)
if [ -d infra/testnet-seeds ]; then terraform_dirs+=(-d infra/testnet-seeds); fi
export BC_SKIP_MAPPING=TRUE   # no call to the Bridgecrew/Prisma API for guideline links
checkov --config-file .checkov.yaml "${terraform_dirs[@]}" -d "$out/rendered" "${dockerfiles[@]}" \
  --soft-fail -o cli -o json -o sarif --output-file-path "$out" > "$out/checkov.txt"
grep -E "scan results|Passed checks" "$out/results_cli.txt" || true
