#!/usr/bin/env bash
# Plan K1: the node's RPC ceiling per method, measured through the gateway with ghz
# (brew install ghz). Writes load/results/<method>.json; read "Requests/sec" and the p99 while
# watching the node's RPC queue (lightwalletd's yed_* in-flight gauge and ycashd's log).
set -euo pipefail
HOSTPORT=${1:-localhost:443}; N=${N:-2000}; C=${C:-50}
PROTO=${PROTO_DIR:-../../lightwalletd-dd/walletrpc}
ADDR=${ADDR:-smMVX5ESn5ZJGjxr3Lp8ZxDAhdN5bJBcHa}
mkdir -p load/results
run() { # name method data
  echo "== $1"; ghz --insecure --import-paths "$PROTO" --proto service.proto --proto yellowback.proto \
    --call "$2" -d "$3" -n "$N" -c "$C" -O json -o "load/results/$1.json" "$HOSTPORT"
  jq -r '"rps \(.rps|floor)  p50 \(.latencyDistribution[2].latency/1e6|floor)ms  p99 \(.latencyDistribution[5].latency/1e6|floor)ms  errors \(.errorDistribution|length)"' "load/results/$1.json"
}
run GetLatestBlock     cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLatestBlock   '{}'
run GetAddressUtxos    cash.z.wallet.sdk.rpc.CompactTxStreamer/GetAddressUtxos  "{\"addresses\":[\"$ADDR\"],\"startHeight\":1}"
run GetTaddressBalance cash.z.wallet.sdk.rpc.CompactTxStreamer/GetTaddressBalance "{\"addresses\":[\"$ADDR\"]}"
run GetPrice           cash.z.wallet.sdk.rpc.YellowbackStreamer/GetPrice         '{}'
run GetAddressTokens   cash.z.wallet.sdk.rpc.YellowbackStreamer/GetAddressTokens "{\"addresses\":[\"$ADDR\"]}"
run GetVaultInfo       cash.z.wallet.sdk.rpc.YellowbackStreamer/GetVaultInfo     '{}'
