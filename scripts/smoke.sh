#!/usr/bin/env bash
# Through the gateway: the stock service, the Yellowback service, the vault primitive's reads.
# Plaintext on :9067 needs no certificate; :443 is the kind self-signed cert (-insecure).
set -euo pipefail
URL=${1:-https://localhost:443}
HOSTPORT=${URL#https://}; HOSTPORT=${HOSTPORT#http://}
PROTO=${PROTO_DIR:-../lightwalletd-dd/walletrpc}
G="grpcurl -insecure -import-path $PROTO -proto service.proto -proto yellowback.proto"
H=$HOSTPORT
# the cluster the A-3 check reads the lightwalletd replica count from; the lightwalletd-dd tree for its burst
CONTEXT=${CONTEXT:-kind-ycash}; NS=${NAMESPACE:-ycash}; RELEASE=${RELEASE:-ycash}
LWD_DIR=${LWD_DIR:-${PROTO%/walletrpc}}
echo "-- GetLightdInfo";       $G $H cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLightdInfo
echo "-- GetLatestBlock";      $G -d '{}' $H cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLatestBlock
# The Yellowback service: present once the arming Job (regtest.armYellowback, K0b) has run; required.
echo "-- GetYellowbackInfo";   $G $H cash.z.wallet.sdk.rpc.YellowbackStreamer/GetYellowbackInfo
echo "-- GetVaultInfo";        $G $H cash.z.wallet.sdk.rpc.YellowbackStreamer/GetVaultInfo
echo "-- GetChainInfo";        $G $H cash.z.wallet.sdk.rpc.YellowbackStreamer/GetChainInfo
echo "-- ListSets";            $G $H cash.z.wallet.sdk.rpc.YellowbackStreamer/ListSets
ADDR=${ADDR:-$(kubectl --context "$CONTEXT" -n "$NS" exec "$RELEASE-ycashd-0" -- ycash-cli -datadir=/var/lib/ycash listunspent 1 9999999 2>/dev/null | jq -r '.[0].address // empty')}
echo "-- GetAddressUtxos for ${ADDR:-?} (routed to yindex)"; [ -n "$ADDR" ] && $G -d "{\"addresses\":[\"$ADDR\"],\"startHeight\":1,\"maxEntries\":2}" $H cash.z.wallet.sdk.rpc.CompactTxStreamer/GetAddressUtxos || echo "(no funded address found; set ADDR=)"
echo "-- gRPC-web (what the browser does)"
curl -sk -o /dev/null -w "HTTP %{http_code} content-type %{content_type}\n" -H 'content-type: application/grpc-web+proto' -H 'x-grpc-web: 1' --data-binary $'\x00\x00\x00\x00\x00' "$URL/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLightdInfo"
# A-3 (plan §5): a client naming a fresh x-real-ip / x-forwarded-for per request must NOT get a
# fresh Yellowback bucket per request. The gateway drops both headers, so every call of the burst
# shares this host's bucket on whichever lightwalletd replica serves it: BURST heavy calls per replica
# (lightwalletd-dd frontend/yellowback_ratelimit.go yedRateBurst, a constant of the image, not a chart
# value; GetAddressTokens is a heavy call), refilled one per second. The replica count is the
# Deployment's live readyReplicas (the HPA may have scaled it past the chart's 2), so the burst is
# 2 x replicas x BURST calls sent in parallel: at most replicas x (BURST + seconds elapsed + 1) can be
# answered, the rest must be ResourceExhausted. Were every spoofed header its own bucket, all would
# be answered. Last, because it drains the buckets.
# The spoofed addresses are distinct valid IPs (198.18.0.0/15, outside trustedProxyCidrs), one per call.
# REPLICAS= and LWD_BURST= override what is read; A3_PARALLEL= the calls in flight (default 32).
if [ -n "$ADDR" ]; then
  REPLICAS=${REPLICAS:-$(kubectl --context "$CONTEXT" -n "$NS" get deployment "$RELEASE-lightwalletd" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)}
  LWD_BURST=${LWD_BURST:-$(sed -n 's/^[[:space:]]*yedRateBurst[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$LWD_DIR/frontend/yellowback_ratelimit.go" 2>/dev/null || true)}
  [ -n "$REPLICAS" ] && [ "$REPLICAS" -gt 0 ] || { echo "A-3: no ready lightwalletd replicas read from $CONTEXT/$NS/$RELEASE-lightwalletd; set REPLICAS="; exit 1; }
  [ -n "$LWD_BURST" ] || { echo "A-3: yedRateBurst not found in $LWD_DIR/frontend/yellowback_ratelimit.go; set LWD_BURST= (or LWD_DIR=)"; exit 1; }
  N=$((2 * REPLICAS * LWD_BURST)); PAR=${A3_PARALLEL:-32}
  echo "-- A-3: $N GetAddressTokens in parallel ($PAR in flight), a spoofed x-real-ip/x-forwarded-for each ($REPLICAS replicas x $LWD_BURST tokens; expected: limited)"
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  one() {
    local out
    if out=$($G -H "x-real-ip: 198.18.$(( $1 / 256 % 256 )).$(( $1 % 256 ))" -H "x-forwarded-for: 198.19.$(( $1 / 256 % 256 )).$(( $1 % 256 ))" -d "{\"addresses\":[\"$ADDR\"]}" "$H" cash.z.wallet.sdk.rpc.YellowbackStreamer/GetAddressTokens 2>&1); then echo ok
    else case "$out" in *ResourceExhausted*) echo limited;; *) echo "other: $(echo "$out" | head -1)";; esac; fi > "$TMP/$1"
  }
  start=$(date +%s)
  for i in $(seq 1 "$N"); do one "$i" & [ $((i % PAR)) -ne 0 ] || wait; done; wait
  elapsed=$(( $(date +%s) - start ))
  ok=$(cat "$TMP"/* | grep -c '^ok$' || true); lim=$(cat "$TMP"/* | grep -c '^limited$' || true); other=$((N - ok - lim))
  most=$((REPLICAS * (LWD_BURST + elapsed + 1)))
  want=$((N - other - most)); [ "$want" -ge 1 ] || want=1
  echo "answered=$ok limited=$lim other=$other in ${elapsed}s (at most $most answerable, so limited >= $want)"
  [ "$other" -eq 0 ] || { echo "   other errors, first:"; grep -h '^other' "$TMP"/* | sort | uniq -c | head -3; }
  [ "$lim" -ge "$want" ] || { echo "A-3 regression: spoofed x-real-ip/x-forwarded-for bought their own buckets ($ok answered > $most)"; exit 1; }
else echo "-- A-3: (no funded address found; set ADDR=)"; fi
