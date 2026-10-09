#!/usr/bin/env bash
# Through the gateway: the stock service, the Yellowback service, the vault primitive's reads.
# Plaintext on :9067 needs no certificate; :443 is the kind self-signed cert (-insecure).
set -euo pipefail
URL=${1:-https://localhost:443}
HOSTPORT=${URL#https://}; HOSTPORT=${HOSTPORT#http://}
PROTO=${PROTO_DIR:-../../lightwalletd-dd/walletrpc}
G="grpcurl -insecure -import-path $PROTO -proto service.proto -proto yellowback.proto"
H=$HOSTPORT
echo "-- GetLightdInfo";       $G $H cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLightdInfo
echo "-- GetLatestBlock";      $G -d '{}' $H cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLatestBlock
echo "-- GetYellowbackInfo";   $G $H cash.z.wallet.sdk.rpc.YellowbackStreamer/GetYellowbackInfo || echo "(Yellowback not armed: expected before K0b)"
echo "-- GetVaultInfo";        $G $H cash.z.wallet.sdk.rpc.YellowbackStreamer/GetVaultInfo || true
echo "-- GetChainInfo";        $G $H cash.z.wallet.sdk.rpc.YellowbackStreamer/GetChainInfo || true
echo "-- GetAddressUtxos (routed to yindex)"; $G -d '{"addresses":["smMVX5ESn5ZJGjxr3Lp8ZxDAhdN5bJBcHa"],"startHeight":1,"maxEntries":5}' $H cash.z.wallet.sdk.rpc.CompactTxStreamer/GetAddressUtxos || echo "(yindex Unimplemented until K3)"
echo "-- gRPC-web (what the browser does)"
curl -sk -o /dev/null -w "HTTP %{http_code} content-type %{content_type}\n" -H 'content-type: application/grpc-web+proto' -H 'x-grpc-web: 1' --data-binary $'\x00\x00\x00\x00\x00' "$URL/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLightdInfo"
