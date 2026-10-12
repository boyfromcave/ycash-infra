#!/usr/bin/env bash
# Plan K3 parity: for EVERY transparent address the chain has touched, yindex's answers through
# the gateway (GetAddressUtxos / GetTaddressBalance / GetTaddressTxids) must equal lightwalletd's
# node-proxied answers (the lightwalletd Service, port-forwarded: it still implements the three
# methods against the node's address index) — byte-for-byte on the UTXO rows and the txid sets.
#
#   scripts/parity.sh [gateway host:port]      default localhost:443 (TLS, -insecure); a
#                                              host:port on 9067 is taken as plaintext
#   CONTEXT / NAMESPACE / RELEASE              the cluster (defaults: kind-ycash / ycash / ycash)
#   RETRIES (3)                                a mismatch is re-checked: the chain moves (a block
#                                              every 5 s on kind) and the ingester polls every 2 s
#
# The address set is collected by walking the blocks from height 1 with `getblock <h> 2` on the
# node's RPC (port-forwarded), scriptPubKey.addresses of every output. The txid comparison is
# bounded to the tip at start so both sides answer the same range; the UTXO and balance
# comparisons are unbounded and re-tried when a block lands between the two calls.
set -euo pipefail
GW=${1:-localhost:443}
CTX=${CONTEXT:-kind-ycash}; NS=${NAMESPACE:-ycash}; RELEASE=${RELEASE:-ycash}
RETRIES=${RETRIES:-3}
PROTO=${PROTO_DIR:-$(cd "$(dirname "$0")/.." && pwd)/../lightwalletd-dd/walletrpc}
RPC_USER=${RPC_USER:-ycash}; RPC_PASSWORD=${RPC_PASSWORD:-ycash-regtest}
RPC_LPORT=${RPC_LPORT:-28832}; LWD_LPORT=${LWD_LPORT:-29067}
case "$GW" in *:9067) GWFLAGS=-plaintext ;; *) GWFLAGS=-insecure ;; esac
k() { kubectl --context "$CTX" -n "$NS" "$@"; }

# Port-forwards: the node's RPC and the lightwalletd Service (plaintext h2c inside the cluster).
pids=()
cleanup() { for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
k port-forward "svc/$RELEASE-ycashd" "$RPC_LPORT:18832" >/dev/null 2>&1 & pids+=($!)
k port-forward "svc/$RELEASE-lightwalletd" "$LWD_LPORT:9067" >/dev/null 2>&1 & pids+=($!)
for i in $(seq 1 30); do nc -z localhost "$RPC_LPORT" 2>/dev/null && nc -z localhost "$LWD_LPORT" 2>/dev/null && break; sleep 1; done

rpc() { # method params-json
  curl -s -u "$RPC_USER:$RPC_PASSWORD" -H 'content-type: application/json' "http://localhost:$RPC_LPORT" \
    --data "{\"jsonrpc\":\"1.0\",\"id\":\"parity\",\"method\":\"$1\",\"params\":${2:-[]}}" | jq -c '.result'
}
# g <side> <data> <method>: side = lwd (the Service, plaintext) or yx (the gateway, routed to yindex)
g() {
  case "$1" in lwd) set -- -plaintext "localhost:$LWD_LPORT" "$2" "$3" ;; yx) set -- $GWFLAGS "$GW" "$2" "$3" ;; esac
  grpcurl "$1" -import-path "$PROTO" -proto service.proto -d "$3" "$2" "cash.z.wallet.sdk.rpc.CompactTxStreamer/$4"
}

TIP=$(rpc getblockcount)
echo "== parity at tip $TIP: collecting addresses (getblock <h> 2, heights 1..$TIP)"
ADDRS=$(for h in $(seq 1 "$TIP"); do rpc getblock "[\"$h\",2]" | jq -r '.tx[].vout[].scriptPubKey.addresses[]?'; done | sort -u)
N=$(echo "$ADDRS" | grep -c . || true)
echo "== $N addresses touched"

# normalisers: the UTXO rows sorted the way yindex orders them (height, txid, index), the txid
# stream as (height, raw tx) pairs. grpcurl prints a stream as concatenated JSON objects (-s).
# each prints one normalised line per row (or ERROR when the call failed, which never matches).
utxos()   { g "$1" "{\"addresses\":[\"$2\"],\"startHeight\":1}" GetAddressUtxos | jq -c '(.addressUtxos // []) | sort_by(.height, .txid, .index) | .[]' || echo "ERROR $1"; }
balance() { g "$1" "{\"addresses\":[\"$2\"]}" GetTaddressBalance | jq -c '.valueZat // "0"' || echo "ERROR $1"; }
txids()   { g "$1" "{\"address\":\"$2\",\"range\":{\"start\":{\"height\":1},\"end\":{\"height\":$TIP}}}" GetTaddressTxids | jq -c -s 'sort_by(.height, .data) | .[]' || echo "ERROR $1"; }

compare() { # what address fn
  local what=$1 a=$2 fn=$3 try
  for try in $(seq 1 "$RETRIES"); do
    l=$($fn lwd "$a"); y=$($fn yx "$a")
    [ "$l" == "$y" ] && [[ "$l" != ERROR* ]] && { echo "$(echo "$l" | grep -c . || true)"; return 0; }
    sleep 3
  done
  echo "MISMATCH $what $a" >&2
  diff <(echo "$l") <(echo "$y") | head -20 >&2
  return 1
}

# A post-quantum address (53 characters: sq…/tq…/rq…, a TX_PQPKH output, D-Q-20) is refused by
# lightwalletd-dd's own taddr methods (rpcversion 7+), so yindex is compared with the node's address
# index directly (getaddressbalance / getaddressutxos / getaddresstxids, -insightexplorer): the
# balance, and the UTXO and txid counts (the txid range bounded to the tip as above).
pq_compare() { # address
  local a=$1 try nb nu nt yb yu yt
  for try in $(seq 1 "$RETRIES"); do
    nb=$(rpc getaddressbalance "[{\"addresses\":[\"$a\"]}]" | jq -c '.balance | tostring')
    nu=$(rpc getaddressutxos "[{\"addresses\":[\"$a\"]}]" | jq 'length')
    nt=$(rpc getaddresstxids "[{\"addresses\":[\"$a\"],\"start\":1,\"end\":$TIP}]" | jq 'length')
    yb=$(balance yx "$a"); yu=$(utxos yx "$a" | grep -c . || true); yt=$(txids yx "$a" | grep -c . || true)
    [ "$nb" == "$yb" ] && [ "$nu" == "$yu" ] && [ "$nt" == "$yt" ] && { echo "$yu $yt"; return 0; }
    sleep 3
  done
  echo "MISMATCH pq $a: node balance=$nb utxos=$nu txids=$nt, yindex balance=$yb utxos=$yu txids=$yt" >&2
  return 1
}

bad=0; rows=0; txs=0
for a in $ADDRS; do
  if [ "${#a}" -eq 53 ]; then
    r=$(pq_compare "$a") || { bad=$((bad+1)); r="0 0"; }
    rows=$((rows+${r% *})); txs=$((txs+${r#* }))
    printf '  %s  utxos=%s  txids=%s  (vs the node)\n' "$a" "${r% *}" "${r#* }"
    continue
  fi
  u=$(compare utxos "$a" utxos) || { bad=$((bad+1)); u=0; }
  b=$(compare balance "$a" balance) || bad=$((bad+1))
  t=$(compare txids "$a" txids) || { bad=$((bad+1)); t=0; }
  rows=$((rows+u)); txs=$((txs+t))
  printf '  %s  utxos=%s  txids=%s\n' "$a" "$u" "$t"
done
echo "== $N addresses, $rows UTXO rows, $txs txids compared at tip $TIP: $bad mismatches"
[ "$bad" -eq 0 ]
