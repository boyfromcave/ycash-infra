#!/usr/bin/env bash
# Plan K1: the node's RPC ceiling per method, measured through the gateway with ghz
# (brew install ghz; --skipTLS: the kind cert is self-signed). Writes load/results/<method>.json; read "Requests/sec" and the p99 while
# watching the node's RPC queue (lightwalletd's yed_* in-flight gauge and ycashd's log).
set -euo pipefail
# Two limiters sit in front of the node: the gateway's per-IP limit (gateway.rateLimit, 500/s on
# kind) and lightwalletd-dd's per-peer Yellowback bucket (20 calls, +1/s). From one client IP they
# are the ceiling, not the node. To measure the node: `helm upgrade ... --set gateway.rateLimit.enabled=false`
# for the stock methods, and SPREAD_PEERS=1 for the Yellowback methods (a distinct x-real-ip per
# request, which the gateway forwards and lightwalletd believes from a trusted proxy: one bucket
# per request, so the node sees every call). Restore the rate limit afterwards.
HOSTPORT=${1:-localhost:443}; N=${N:-2000}; C=${C:-50}
PROTO=${PROTO_DIR:-../lightwalletd-dd/walletrpc}
# the regtest coinbase address on kind unless ADDR= is given
ADDR=${ADDR:-$(kubectl --context kind-ycash -n ycash exec ycash-ycashd-0 -- ycash-cli -datadir=/var/lib/ycash listunspent 1 9999999 2>/dev/null | jq -r ".[0].address // empty")}
mkdir -p load/results
run() { # name method data   (ghz takes one --proto: the file that declares the service)
  md='{}'
  case "$2" in *YellowbackStreamer*) proto=yellowback.proto; [ "${SPREAD_PEERS:-0}" = 1 ] && md='{"x-real-ip":"load-{{.RequestNumber}}"}' ;; *) proto=service.proto ;; esac
  echo "== $1"; ghz --skipTLS --import-paths "$PROTO" --proto "$proto" -m "$md" \
    --call "$2" -d "$3" -n "$N" -c "$C" -O json -o "load/results/$1.json" "$HOSTPORT"
  jq -r '"rps \(.rps|floor)  p50 \((.latencyDistribution // [])[2].latency // 0|./1e6|floor)ms  p95 \((.latencyDistribution // [])[4].latency // 0|./1e6|floor)ms  p99 \((.latencyDistribution // [])[5].latency // 0|./1e6|floor)ms  errors \([.errorDistribution[]?] | add // 0)"' "load/results/$1.json"
}
run GetLatestBlock     cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLatestBlock   '{}'
run GetAddressUtxos    cash.z.wallet.sdk.rpc.CompactTxStreamer/GetAddressUtxos  "{\"addresses\":[\"$ADDR\"],\"startHeight\":1}"
run GetTaddressBalance cash.z.wallet.sdk.rpc.CompactTxStreamer/GetTaddressBalance "{\"addresses\":[\"$ADDR\"]}"
run GetPrice           cash.z.wallet.sdk.rpc.YellowbackStreamer/GetPrice         '{}'
run GetAddressTokens   cash.z.wallet.sdk.rpc.YellowbackStreamer/GetAddressTokens "{\"addresses\":[\"$ADDR\"]}"
run GetVaultInfo       cash.z.wallet.sdk.rpc.YellowbackStreamer/GetVaultInfo     '{}'
