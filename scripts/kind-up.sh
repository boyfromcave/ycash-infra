#!/usr/bin/env bash
# cluster add-ons (Envoy Gateway, cert-manager, metrics-server; kube-prometheus-stack with
# MONITORING=1) + the chart with values-kind.yaml. The mkcert TLS Secret (scripts/kind-cert.sh)
# is used when it exists; with MONITORING=1 the chart's ServiceMonitor, dashboard and the
# /grafana/ route are turned on.
set -euo pipefail
CLUSTER=${1:-ycash}; NS=${2:-ycash}; RELEASE=${3:-ycash}
CTX="kind-$CLUSTER"
EG_VERSION=${EG_VERSION:-v1.3.0}
CM_VERSION=${CM_VERSION:-v1.17.1}
KPS_VERSION=${KPS_VERSION:-92.3.0}
MONITORING=${MONITORING:-0}
k() { kubectl --context "$CTX" "$@"; }
SET=()

echo "== Gateway API CRDs + Envoy Gateway $EG_VERSION"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version "$EG_VERSION" \
  --set config.envoyGateway.extensionApis.enableEnvoyPatchPolicy=true \
  --kube-context "$CTX" -n envoy-gateway-system --create-namespace --wait
echo "== cert-manager $CM_VERSION"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm upgrade --install cert-manager jetstack/cert-manager --version "$CM_VERSION" \
  --kube-context "$CTX" -n cert-manager --create-namespace --set crds.enabled=true --wait
echo "== metrics-server (for the HPA)"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm upgrade --install metrics-server metrics-server/metrics-server --kube-context "$CTX" -n kube-system \
  --set args="{--kubelet-insecure-tls}" --wait
if [ "$MONITORING" = 1 ]; then
  echo "== kube-prometheus-stack $KPS_VERSION (Grafana at /grafana/ on the gateway)"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack --version "$KPS_VERSION" \
    --kube-context "$CTX" -n monitoring --create-namespace --wait --timeout 15m \
    --set alertmanager.enabled=false --set nodeExporter.enabled=false \
    --set prometheus.prometheusSpec.retention=2d --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set 'grafana.grafana\.ini.server.root_url=https://localhost/grafana/' --set 'grafana.grafana\.ini.server.serve_from_sub_path=true' \
    --set grafana.sidecar.dashboards.searchNamespace=ALL
  SET+=(--set monitoring.serviceMonitor=true --set monitoring.dashboards=true --set monitoring.grafana.route=true)
fi
if k -n "$NS" get secret "$RELEASE-tls-mkcert" >/dev/null 2>&1; then
  SET+=(--set gateway.tls.mode=existing --set "gateway.tls.secretName=$RELEASE-tls-mkcert")
fi
echo "== the chart"
# One-shot Jobs are immutable once run: a completed bootstrap/arming Job whose rendered spec changed
# makes the upgrade fail (the arming Job is idempotent; re-running it is harmless).
for j in $(k -n "$NS" get jobs -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{range .items[?(@.status.succeeded==1)]}{.metadata.name}{" "}{end}' 2>/dev/null); do
  k -n "$NS" delete job "$j" --ignore-not-found >/dev/null
done
helm upgrade --install "$RELEASE" charts/ycash-lightwallet --kube-context "$CTX" -n "$NS" --create-namespace \
  -f charts/ycash-lightwallet/values-kind.yaml ${SET[@]+"${SET[@]}"} --wait --timeout 15m
echo "== waiting for the node, the bootstrap job and lightwalletd"
k -n "$NS" rollout status statefulset/"$RELEASE"-ycashd --timeout=10m
k -n "$NS" wait --for=condition=complete job/"$RELEASE"-bootstrap --timeout=10m
k -n "$NS" rollout status deployment/"$RELEASE"-lightwalletd --timeout=10m
# K0c: the arming Job (regtest.armYellowback) records the node's payout address in the set ConfigMap;
# the chart renders -yellowbackpayoutaddress from it through `lookup`, so one more upgrade starts the
# node as the quoting pool (a no-op on a cluster that already has it).
if ARM=$(k -n "$NS" get job -l app.kubernetes.io/component=arm-yellowback -o name 2>/dev/null) && [ -n "$ARM" ]; then
  echo "== waiting for the arming Job, then the upgrade that makes the node the quoting pool"
  k -n "$NS" wait --for=condition=complete "$ARM" --timeout=20m
  helm upgrade --install "$RELEASE" charts/ycash-lightwallet --kube-context "$CTX" -n "$NS" \
    -f charts/ycash-lightwallet/values-kind.yaml --wait --timeout 15m
  k -n "$NS" rollout status statefulset/"$RELEASE"-ycashd --timeout=10m
fi
echo "== up. Try: make kind-smoke; make kind-personas-up (attestors, prices: YED mintable)"
