#!/usr/bin/env bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# In plain words: this makes the Ycash mainnet history bundle (blocks 0..H_S) on any machine with
# Docker, typically a large EC2 instance. It runs the Ycash node (ycashd, pinned image) until it
# has synced Ycash mainnet from Ycash peers, picks the split height H_S, copies blocks 0..H_S out,
# checks every one against the checkpoints compiled into Ycash, has a second, independently synced
# node confirm the blocks newer than those checkpoints, and packs the files. Run it twice, or on
# two machines, and the SHA256SUMS files come out identical (README.md, "Mainnet history").
#
# Usage:  bundles/prefix/run-local-mainnet.sh [H_S|auto]     (default auto)
#   auto: H_S is the most recent multiple of SPLIT_STEP (10,000) at least MIN_DEPTH (1,000) blocks
#         below the synced tip. A number: that height, once the node is MIN_DEPTH blocks above it.
# Env:    WORK=<dir>             work directory (default ./mainnet-work): state/ and state-b/ (the two
#                                node datadirs, kept between runs so a rerun syncs only the delta),
#                                raw/, out/, timings.txt, harvest-report.json
#         CROSSCHECK=sync|rpc|none  how blocks above the newest compiled checkpoint (2,250,000) are
#                                confirmed (default sync):
#                                  sync  a second ycashd syncs alongside, its own datadir and peers
#                                  rpc   an already synced node you run elsewhere: CROSSCHECK_RPC_URL
#                                        (http://host:port), CROSSCHECK_RPC_USER, CROSSCHECK_RPC_PASSWORD
#                                  none  only for H_S <= 2,250,000 (pack refuses above it)
#         ADDNODES="h[:p] ..."   extra peers for the main node (-addnode); the DNS seed is used too
#         CROSSCHECK_CONNECT="h[:p] ..."  the second node's ONLY peers (-connect): a disjoint peer
#                                set makes it independent of the first; empty = the DNS seed
#         DBCACHE=<MB>           ycashd -dbcache (default 4096)
#         WORKERS=<n>            concurrent RPC requests during export (default 4)
#         JOBS=<n>               chunks gzipped at once (default: the CPU count; bytes do not change)
#         KEEP_RAW=1             keep raw/ after packing (default: each raw chunk is removed once packed)
#         SYNC_TIMEOUT_MIN=<n>   stop the sync cleanly after n minutes, exit 3, keep state (0 = never)
#         PROGRESS_MIN=<n>       log the sync every n minutes (default 5)
#         POLL_SEC=<n>           seconds between polls (default 30)
#         MIN_DEPTH, SPLIT_STEP  the split-height rule (1000, 10000); change only for trials
#
# Phases (each logs its duration to $WORK/timings.txt):
#   1 sync    ycashd (harvest.YCASHD_IMAGE) on mainnet with the network, RPC on its loopback with
#             cookie auth; with CROSSCHECK=sync a second one beside it. Polls getblockchaininfo until
#             the split height is MIN_DEPTH blocks deep (auto: until the initial block download is
#             complete and blocks = headers, then H_S from the tip).
#   2 export  the main node is restarted with no network (--network none, -connect=0), so the chain
#             cannot move under the export; getblockhash / getblock <hash> 0 for 0..H_S into raw/,
#             checked as they arrive; z_gettreestate at H_S; then the cross-check node's hashes at
#             the cross-check heights and its z_gettreestate, which must equal the main node's.
#   3 pack    in the pinned pack image, with no network: verify raw/, gzip -n -9, manifest.json,
#             treestate.json, SHA256SUMS into out/; then `verify out/` from the files alone.
#
# Disk: the node datadir (about the size of the history plus indexes), the same again for the
# second node, plus raw/ (the history), plus out/ (a little less); see README.md for sizes.
# Needs: docker, bash, nproc. Both nodes run as the calling user, so state/ stays yours.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HS_IN=${1:-${SPLIT_HEIGHT:-auto}}
WORK=${WORK:-$PWD/mainnet-work}
CROSSCHECK=${CROSSCHECK:-sync}
ADDNODES=${ADDNODES:-}
CROSSCHECK_CONNECT=${CROSSCHECK_CONNECT:-}
DBCACHE=${DBCACHE:-4096}
WORKERS=${WORKERS:-4}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 2)}
KEEP_RAW=${KEEP_RAW:-0}
SYNC_TIMEOUT_MIN=${SYNC_TIMEOUT_MIN:-0}
PROGRESS_MIN=${PROGRESS_MIN:-5}
POLL_SEC=${POLL_SEC:-30}
MIN_DEPTH=${MIN_DEPTH:-1000}
SPLIT_STEP=${SPLIT_STEP:-10000}
PACK=ycash-prefix:local
NODE_A=mainnet-ycashd
NODE_B=mainnet-ycashd-crosscheck
LAST_CHECKPOINT=2250000   # the newest compiled mainnet checkpoint (data/ycash-main-checkpoints.txt)

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
isnum() { [[ $1 =~ ^[0-9]+$ ]]; }
for v in DBCACHE WORKERS JOBS PROGRESS_MIN POLL_SEC SPLIT_STEP; do
  isnum "${!v}" && (( ${!v} > 0 )) || die "$v must be a positive integer (got '${!v}')"
done
for v in SYNC_TIMEOUT_MIN MIN_DEPTH; do isnum "${!v}" || die "$v must be an integer (got '${!v}')"; done
[[ $HS_IN == auto ]] || isnum "$HS_IN" || die "H_S must be 'auto' or an integer (got '$HS_IN')"
[[ $HS_IN == auto ]] || HS_IN=$((10#$HS_IN))
case "$CROSSCHECK" in
  sync|none) ;;
  rpc) [[ ${CROSSCHECK_RPC_URL:-} =~ ^http://[A-Za-z0-9.-]+:[0-9]+/?$ ]] || die "CROSSCHECK=rpc needs CROSSCHECK_RPC_URL=http://host:port"
       [ -n "${CROSSCHECK_RPC_USER:-}" ] || die "CROSSCHECK=rpc needs CROSSCHECK_RPC_USER (and CROSSCHECK_RPC_PASSWORD)" ;;
  *) die "CROSSCHECK is sync, rpc or none" ;;
esac
peer_re='^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:[0-9]+)?$'
for p in $ADDNODES $CROSSCHECK_CONNECT; do [[ $p =~ $peer_re ]] || die "not a host[:port]: '$p'"; done
if [[ $HS_IN != auto && $CROSSCHECK == none ]] && (( HS_IN > LAST_CHECKPOINT )); then
  die "H_S $HS_IN is above the newest compiled checkpoint $LAST_CHECKPOINT: CROSSCHECK=sync or rpc is required"
fi

mkdir -p "$WORK/state"
[ "$CROSSCHECK" != sync ] || mkdir -p "$WORK/state-b"
WORK=$(cd "$WORK" && pwd)
rm -rf "$WORK/raw" "$WORK/out" "$WORK/treestate.json" "$WORK/crosscheck.json" "$WORK/harvest-report.json"
mkdir -p "$WORK/raw" "$WORK/out"
: > "$WORK/timings.txt"
# cookie auth only (no rpcpassword): ycashd writes <datadir>/.cookie; RPC on the container's loopback
cat > "$WORK/ycash.conf" <<EOF
server=1
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
printtoconsole=1
dbcache=$DBCACHE
EOF

cleanup() {
  for n in "$NODE_A" "$NODE_B"; do docker stop "$n" >/dev/null 2>&1 || true; docker rm -f "$n" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT
cleanup

log "building the pack image from $HERE"
docker build -q -t "$PACK" "$HERE" >/dev/null
YCASHD_IMAGE=$(docker run --rm --network none "$PACK" constants --network ycash-mainnet | sed -n 's/^YCASHD_IMAGE=//p')
[[ $YCASHD_IMAGE == *@sha256:* ]] || die "no pinned YCASHD_IMAGE from harvest.py"
log "ycashd image $YCASHD_IMAGE; split height $HS_IN; cross-check $CROSSCHECK"

node() {  # name state-subdir network ycashd-args...
  local name=$1 sub=$2 net=$3; shift 3
  docker run -d --name "$name" --network "$net" --user "$(id -u):$(id -g)" --stop-timeout 600 \
    -v "$WORK/$sub:/var/lib/ycash" -v "$WORK/ycash.conf:/etc/ycash/ycash.conf:ro" \
    -e YCASHD_CONF=/etc/ycash/ycash.conf "$YCASHD_IMAGE" "$@" >/dev/null
}
client() {  # name harvest-args...: the pack image inside the node's network namespace
  local name=$1; shift
  docker run --rm --network "container:$name" --user "$(id -u):$(id -g)" -v "$WORK:/work" "$PACK" "$@"
}
running() { [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }
info() {  # name sub -> "<blocks> <headers> <ibd-complete>", or fails
  client "$1" chaininfo --network ycash-mainnet --cookie-file "/work/$2/.cookie" 2>/dev/null
}
alive_or_die() {
  running "$1" && return 0
  docker logs --tail 30 "$1" >&2 || true
  die "$1 exited (code $(docker inspect -f '{{.State.ExitCode}}' "$1" 2>/dev/null || echo '?'))"
}
phase() { local s=$(( $(date +%s) - $2 )); printf '%-7s %6d s\n' "$1" "$s" >> "$WORK/timings.txt"; log "$1 took ${s} s"; }

# --- 1 sync ---------------------------------------------------------------------------------
t0=$(date +%s)
args_a=(-listen=0)
for p in $ADDNODES; do args_a+=("-addnode=$p"); done
log "phase 1: sync Ycash mainnet (state in $WORK/state)"
node "$NODE_A" state bridge "${args_a[@]}"
if [ "$CROSSCHECK" = sync ]; then
  args_b=(-listen=0)
  for p in $CROSSCHECK_CONNECT; do args_b+=("-connect=$p"); done
  log "cross-check node: its own datadir ($WORK/state-b), peers: ${CROSSCHECK_CONNECT:-the DNS seed}"
  node "$NODE_B" state-b bridge "${args_b[@]}"
fi
HS=''; TIP_A=''; TIP_B=''; next_log=0
while :; do
  alive_or_die "$NODE_A"
  read -r a_blocks a_headers a_ibd < <(info "$NODE_A" state || echo "? ? 0")
  b_blocks='-'
  if [ "$CROSSCHECK" = sync ]; then
    alive_or_die "$NODE_B"
    read -r b_blocks _ _ < <(info "$NODE_B" state-b || echo "? ? 0")
  fi
  now=$(date +%s); el=$(( (now - t0) / 60 ))
  if (( now >= next_log )); then
    log "sync: node blocks $a_blocks headers $a_headers ibd-complete $a_ibd; cross-check node $b_blocks; ${el} min"
    next_log=$(( now + PROGRESS_MIN * 60 ))
  fi
  if [ -z "$HS" ] && isnum "$a_blocks"; then
    if [[ $HS_IN != auto ]]; then
      (( a_blocks >= HS_IN + MIN_DEPTH )) && HS=$HS_IN
    elif [ "$a_ibd" = 1 ] && [ "$a_blocks" = "$a_headers" ]; then
      HS=$(docker run --rm --network none "$PACK" split-height --tip "$a_blocks" --min-depth "$MIN_DEPTH" --step "$SPLIT_STEP")
      if [ "$CROSSCHECK" = none ] && (( HS > LAST_CHECKPOINT )); then
        die "the default split height $HS is above the newest compiled checkpoint $LAST_CHECKPOINT: CROSSCHECK=sync or rpc is required"
      fi
    fi
    [ -z "$HS" ] || { TIP_A=$a_blocks; log "sync: split height $HS (node tip $a_blocks)"; }
  fi
  if [ -n "$HS" ]; then
    if [ "$CROSSCHECK" != sync ]; then break; fi
    if isnum "$b_blocks" && (( b_blocks >= HS + MIN_DEPTH )); then TIP_B=$b_blocks; break; fi
  fi
  if (( SYNC_TIMEOUT_MIN > 0 && el >= SYNC_TIMEOUT_MIN )); then
    log "sync: not done after $el min; stopping the nodes cleanly so state/ can resume"
    cleanup
    phase sync "$t0"
    exit 3
  fi
  sleep "$POLL_SEC"
done
phase sync "$t0"

# --- 2 export -------------------------------------------------------------------------------
t0=$(date +%s)
log "phase 2: restart the node with no network, export 0..$HS"
docker stop "$NODE_A" >/dev/null; docker rm "$NODE_A" >/dev/null
node "$NODE_A" state none -connect=0 -listen=0 -dnsseed=0 -discover=0
until read -r a_blocks _ _ < <(info "$NODE_A" state) && isnum "$a_blocks" && (( a_blocks >= HS )); do
  alive_or_die "$NODE_A"; sleep "$POLL_SEC"
done
log "offline node at $a_blocks"
client "$NODE_A" export --network ycash-mainnet --cookie-file /work/state/.cookie --last-height "$HS" \
  --raw-dir /work/raw --workers "$WORKERS"
client "$NODE_A" treestate --network ycash-mainnet --cookie-file /work/state/.cookie --last-height "$HS" \
  --out /work/treestate.json
pack_xc=()
case "$CROSSCHECK" in
  sync)
    client "$NODE_B" crosscheck --network ycash-mainnet --cookie-file /work/state-b/.cookie --last-height "$HS" \
      --out /work/crosscheck.json --compare-treestate /work/treestate.json
    pack_xc=(--crosscheck /work/crosscheck.json) ;;
  rpc)
    docker run --rm --network host --user "$(id -u):$(id -g)" -v "$WORK:/work" -e RPC_PASSWORD="${CROSSCHECK_RPC_PASSWORD:-}" "$PACK" \
      crosscheck --network ycash-mainnet --rpc-url "$CROSSCHECK_RPC_URL" --rpc-user "$CROSSCHECK_RPC_USER" \
      --last-height "$HS" --out /work/crosscheck.json --compare-treestate /work/treestate.json
    pack_xc=(--crosscheck /work/crosscheck.json) ;;
esac
log "export: done; stopping the nodes"
cleanup
phase export "$t0"

# --- 3 pack + verify ------------------------------------------------------------------------
t0=$(date +%s)
log "phase 3: pack in $PACK (no network)"
rm_raw=(--remove-raw); [ "$KEEP_RAW" = 1 ] && rm_raw=()
docker run --rm --network none --user "$(id -u):$(id -g)" -v "$WORK:/work" "$PACK" \
  pack --network ycash-mainnet --last-height "$HS" --raw-dir /work/raw --out-dir /work/out --jobs "$JOBS" \
  --treestate /work/treestate.json "${pack_xc[@]}" "${rm_raw[@]}"
docker run --rm --network none --user "$(id -u):$(id -g)" -v "$WORK/out:/out:ro" "$PACK" verify /out
phase pack "$t0"

# what ran, outside the bundle (runner-dependent, so never in manifest.json)
cat > "$WORK/harvest-report.json" <<EOF
{"split_height": $HS, "split_height_input": "$HS_IN", "node_tip_at_split": ${TIP_A:-null},
 "crosscheck": "$CROSSCHECK", "crosscheck_node_tip": ${TIP_B:-null}, "ycashd_image": "$YCASHD_IMAGE"}
EOF
echo "$HS" > "$WORK/split-height"
log "done: $WORK/out (split height $HS)"
cat "$WORK/out/SHA256SUMS"
