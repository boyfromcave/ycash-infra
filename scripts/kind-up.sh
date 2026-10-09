#!/usr/bin/env bash
# cluster add-ons (Envoy Gateway, cert-manager, metrics-server) + the chart with values-kind.yaml.
set -euo pipefail
CLUSTER=${1:-ycash}; NS=${2:-ycash}; RELEASE=${3:-ycash}
CTX="kind-$CLUSTER"
EG_VERSION=${EG_VERSION:-v1.3.0}
CM_VERSION=${CM_VERSION:-v1.17.1}
k() { kubectl --context "$CTX" "$@"; }

echo "== Gateway API CRDs + Envoy Gateway $EG_VERSION"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version "$EG_VERSION" \
  --kube-context "$CTX" -n envoy-gateway-system --create-namespace --wait
echo "== cert-manager $CM_VERSION"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm upgrade --install cert-manager jetstack/cert-manager --version "$CM_VERSION" \
  --kube-context "$CTX" -n cert-manager --create-namespace --set crds.enabled=true --wait
echo "== metrics-server (for the HPA)"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm upgrade --install metrics-server metrics-server/metrics-server --kube-context "$CTX" -n kube-system \
  --set args="{--kubelet-insecure-tls}" --wait
echo "== the chart"
helm upgrade --install "$RELEASE" charts/ycash-lightwallet --kube-context "$CTX" -n "$NS" --create-namespace \
  -f charts/ycash-lightwallet/values-kind.yaml --wait --timeout 15m
echo "== waiting for the node, the bootstrap job and lightwalletd"
k -n "$NS" rollout status statefulset/"$RELEASE"-ycashd --timeout=10m
k -n "$NS" wait --for=condition=complete job/"$RELEASE"-bootstrap --timeout=10m
k -n "$NS" rollout status deployment/"$RELEASE"-lightwalletd --timeout=10m
echo "== up. Try: make kind-smoke"
