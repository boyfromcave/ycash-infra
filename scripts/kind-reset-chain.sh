#!/usr/bin/env bash
# A new regtest chain: the node's and Postgres's volumes go (yindex indexes the old chain), so do the
# attestor-set ConfigMap/Secret (the set id is a txid on the old chain) and the one-shot Jobs; then
# the chart is applied again and the bootstrap + arming Jobs rebuild the chain.
set -euo pipefail
CLUSTER=${1:-ycash}; NS=${2:-ycash}; RELEASE=${3:-ycash}; CTX="kind-$CLUSTER"
k() { kubectl --context "$CTX" -n "$NS" "$@"; }
k delete job -l app.kubernetes.io/instance="$RELEASE" --ignore-not-found
k delete job "$RELEASE-bootstrap" "$RELEASE-arm-yellowback" --ignore-not-found
k scale statefulset "$RELEASE-ycashd" "$RELEASE-postgres" --replicas=0
k scale deployment "$RELEASE-lightwalletd" "$RELEASE-yindex" "$RELEASE-yindex-ingest" "$RELEASE-miner" --replicas=0
k wait --for=delete pod -l app.kubernetes.io/component=ycashd --timeout=180s || true
k wait --for=delete pod -l app.kubernetes.io/component=postgres --timeout=180s || true
k delete pvc -l app.kubernetes.io/instance="$RELEASE" --ignore-not-found
k delete configmap "$RELEASE-yellowback-set" --ignore-not-found
k delete secret "$RELEASE-yellowback-attestor" --ignore-not-found
helm upgrade "$RELEASE" charts/ycash-lightwallet --kube-context "$CTX" -n "$NS" -f charts/ycash-lightwallet/values-kind.yaml
k scale statefulset "$RELEASE-ycashd" "$RELEASE-postgres" --replicas=1
k scale deployment "$RELEASE-lightwalletd" --replicas=2
k scale deployment "$RELEASE-yindex" "$RELEASE-yindex-ingest" "$RELEASE-miner" --replicas=1
k rollout status statefulset/"$RELEASE-ycashd" --timeout=10m
k wait --for=condition=complete job/"$RELEASE-bootstrap" --timeout=10m
k wait --for=condition=complete job/"$RELEASE-arm-yellowback" --timeout=15m
k rollout status deployment/"$RELEASE-lightwalletd" --timeout=10m
echo "chain reset; try: make kind-smoke"
