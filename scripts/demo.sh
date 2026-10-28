#!/usr/bin/env bash
# `make demo`: the kind cluster as a thing a person tests in a browser (docs/try-it.md). Idempotent:
# every step is skipped when already done. Never resets the chain, never scales the node.
#   1. images (the node/lightwalletd/yindex images must exist: `make images` once, 1–2 h for the node;
#      the web bundle is rebuilt from $YEW when its dist is missing; faucet + yindex built here)
#   2. the cluster (make kind-create) and the images loaded
#   3. the mkcert certificate (scripts/kind-cert.sh) → gateway.tls.mode=existing when the Secret exists
#   4. kube-prometheus-stack when MONITORING=1 (default from the Makefile)
#   5. the chart (scripts/kind-up.sh: add-ons + helm upgrade with the demo values), the waits
#   6. the URLs and the three rules
set -euo pipefail
CLUSTER=${1:-ycash}; NS=${2:-ycash}; RELEASE=${3:-ycash}; YEW=${4:-../yew}
CTX="kind-$CLUSTER"; REGISTRY=${REGISTRY:-ycash}
cd "$(dirname "$0")/.."
k() { kubectl --context "$CTX" -n "$NS" "$@"; }
have_image() { docker image inspect "$REGISTRY/$1:local" >/dev/null 2>&1; }

echo "== images"
for i in ycashd lightwalletd yindex; do have_image $i || { echo "demo: $REGISTRY/$i:local missing: run 'make images' first (the node build takes 1–2 h)"; exit 1; }; done
if [ ! -d "$YEW/web/dist" ]; then
  echo "demo: $YEW/web/dist missing: building the wallet bundle"
  (cd "$YEW/web" && { [ -d src/wasm ] || scripts/build-core-wasm.sh; } && npm run build)
fi
have_image web || make image-web YEW="$YEW"
have_image faucet || make image-faucet

echo "== the cluster"
make kind-create
make kind-load 2>&1 | { grep -v "already present" || true; }   # fails on a stale image (make image-check)

echo "== the certificate"
scripts/kind-cert.sh "$CLUSTER" "$NS" "$RELEASE"

echo "== the chart (+ monitoring: MONITORING=${MONITORING:-0})"
MONITORING=${MONITORING:-0} scripts/kind-up.sh "$CLUSTER" "$NS" "$RELEASE"
k rollout status deployment/"$RELEASE"-web --timeout=5m
k rollout status deployment/"$RELEASE"-faucet --timeout=10m   # the init container downloads 52 MB once
for _ in $(seq 60); do curl -skf https://localhost/faucet/info >/dev/null && break; sleep 2; done

cat <<MSG

== demo up (docs/try-it.md is the tester's guide)

  wallet   https://localhost/
  faucet   https://localhost/faucet/          (regtest only: Send 2 YEC, Mine 1 block, the node's address, the proving files at /faucet/params/)
$( [ "${MONITORING:-0}" = 1 ] && echo "  grafana  https://localhost/grafana/         (admin / $(kubectl --context "$CTX" -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo prom-operator); dashboard 'Ycash light-wallet backend')" )
  rpc      localhost:18832                    (ycash-cli -regtest -rpcuser=ycash -rpcpassword=ycash-regtest …)

  Three rules:
  1. One browser session per wallet at a time (the wallet store is one OPFS directory per origin:
     a second tab or window on the same profile sees "busy"). A second wallet = a second Chrome
     profile or an incognito window.
  2. Chrome (or Edge). Safari and Firefox lack what the wallet's worker needs today.
  3. Keep the Mac awake: a sleeping Mac pauses Docker (the chain) and looks like a stalled wallet.
     The wallet's scripts run under caffeinate; a human tester just has to know.
$( security find-certificate -c mkcert /Library/Keychains/System.keychain >/dev/null 2>&1 || echo "
  The certificate is not yet trusted by this Mac: run 'mkcert -install' once (a password prompt),
  or click through Chrome's warning (Advanced → Proceed to localhost)." )
MSG
