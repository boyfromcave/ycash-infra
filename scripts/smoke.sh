#!/usr/bin/env bash
# Through the gateway: the stock service, the Yellowback service, the vault primitive's reads.
# Plaintext on :9067 needs no certificate; :443 is the kind self-signed cert (-insecure).
set -euo pipefail
URL=${1:-https://localhost:443}
HOSTPORT=${URL#https://}; HOSTPORT=${HOSTPORT#http://}
PROTO=${PROTO_DIR:-../lightwalletd-dd/walletrpc}
G="grpcurl -insecure -import-path $PROTO -proto service.proto -proto yellowback.proto"
H=$HOSTPORT
echo "-- GetLightdInfo";       $G $H cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLightdInfo
echo "-- GetLatestBlock";      $G -d '{}' $H cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLatestBlock
# The Yellowback service: present once the arming Job (regtest.armYellowback, K0b) has run; required.
echo "-- GetYellowbackInfo";   $G $H cash.z.wallet.sdk.rpc.YellowbackStreamer/GetYellowbackInfo
echo "-- GetVaultInfo";        $G $H cash.z.wallet.sdk.rpc.YellowbackStreamer/GetVaultInfo
echo "-- GetChainInfo";        $G $H cash.z.wallet.sdk.rpc.YellowbackStreamer/GetChainInfo
echo "-- ListSets";            $G $H cash.z.wallet.sdk.rpc.YellowbackStreamer/ListSets
ADDR=${ADDR:-$(kubectl --context kind-ycash -n ycash exec ycash-ycashd-0 -- ycash-cli -datadir=/var/lib/ycash listunspent 1 9999999 2>/dev/null | jq -r '.[0].address // empty')}
echo "-- GetAddressUtxos for ${ADDR:-?} (routed to yindex)"; [ -n "$ADDR" ] && $G -d "{\"addresses\":[\"$ADDR\"],\"startHeight\":1,\"maxEntries\":2}" $H cash.z.wallet.sdk.rpc.CompactTxStreamer/GetAddressUtxos || echo "(no funded address found; set ADDR=)"
echo "-- gRPC-web (what the browser does)"
curl -sk -o /dev/null -w "HTTP %{http_code} content-type %{content_type}\n" -H 'content-type: application/grpc-web+proto' -H 'x-grpc-web: 1' --data-binary $'\x00\x00\x00\x00\x00' "$URL/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLightdInfo"
# A-3 (plan §5): a client naming a fresh x-real-ip per request must NOT get a fresh Yellowback
# bucket per request. The gateway drops the header, so the burst shares the peer's bucket of 20
# heavy calls per lightwalletd replica (GetAddressTokens is a heavy call): 60 calls across the
# kind cluster's two replicas must see ResourceExhausted. Last, because it drains the bucket.
echo "-- A-3: 60 GetAddressTokens with a spoofed x-real-ip per request (expected: limited)"
if [ -n "$ADDR" ]; then
  ok=0; lim=0
  for i in $(seq 1 60); do
    out=$($G -H "x-real-ip: spoof-$i" -d "{\"addresses\":[\"$ADDR\"]}" $H cash.z.wallet.sdk.rpc.YellowbackStreamer/GetAddressTokens 2>&1 || true)
    case "$out" in *ResourceExhausted*) lim=$((lim+1));; *) ok=$((ok+1));; esac
  done
  echo "answered=$ok limited=$lim"
  [ "$lim" -gt 0 ] || { echo "A-3 regression: every spoofed x-real-ip got its own bucket"; exit 1; }
else echo "(no funded address found; set ADDR=)"; fi
