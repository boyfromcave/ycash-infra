#!/usr/bin/env bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# Checkov over everything this repository deploys: infra/eks (Terraform), the chart rendered for kind
# and for EKS (Kubernetes), and images/*/Dockerfile. Policy: .checkov.yaml. Report only (exit 0 unless
# checkov itself fails); contrib/secops/checkov-gate.py decides what fails a PR.
# Usage: contrib/secops/checkov.sh OUTDIR    (needs checkov and helm on PATH; run from anywhere)
#   -> OUTDIR/results_json.json, OUTDIR/results_sarif.sarif, OUTDIR/rendered/{kind,eks}.yaml
set -euo pipefail
out=$(realpath -m "${1:?usage: checkov.sh OUTDIR}")
cd "$(dirname "$0")/../.."
CHART=charts/ycash-lightwallet
mkdir -p "$out/rendered"
# The EKS render with the values make eks-deploy sets (as scripts/lint-images.sh).
EKS_SET=(--set gateway.host=lite.example.org)
for c in ycashd lightwalletd yindex web; do
  EKS_SET+=(--set "images.$c.repository=0.dkr.ecr.us-east-1.amazonaws.com/ycash/$c" --set "images.$c.tag=rev")
done
helm template t $CHART -f $CHART/values-kind.yaml > "$out/rendered/kind.yaml"
helm template t $CHART -f $CHART/values-eks.yaml "${EKS_SET[@]}" > "$out/rendered/eks.yaml"
export BC_SKIP_MAPPING=TRUE   # no call to the Bridgecrew/Prisma API for guideline links
checkov --config-file .checkov.yaml -d infra/eks -d "$out/rendered" -d images \
  --soft-fail -o cli -o json -o sarif --output-file-path "$out" > "$out/checkov.txt"
grep -E "scan results|Passed checks" "$out/results_cli.txt" || true
