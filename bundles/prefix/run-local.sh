#!/usr/bin/env bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# In plain words: this makes the Zcash-testnet prefix files on any machine with Docker. It runs
# a Zcash node (Zebra) until it has the blocks up to the prefix's last height, copies those blocks
# out, checks every one, and packs them. Run it twice, or on two machines, and the SHA256SUMS
# files come out identical: that is the audit (README.md).
#
# Usage:  bundles/prefix/run-local.sh [LAST_HEIGHT]      (default 510247; 4799 is the smoke range)
# Env:    WORK=<dir>           work directory (default ./prefix-work): state/, raw/, out/
#         WORKERS=<n>          concurrent RPC requests during export (default 4)
#         SYNC_TIMEOUT_MIN=<n> give up the sync after n minutes, keeping state/ to resume (0 = never)
#         PROGRESS_MIN=<n>     log the sync height every n minutes (default 5)
#
# Phases (each logs its duration to $WORK/timings.txt):
#   1 sync    zebrad (harvest.ZEBRA_IMAGE) on Testnet with ZEBRA_STATE__DEBUG_STOP_AT_HEIGHT=LAST:
#             it syncs from peers and exits once it has committed LAST. state/ can be cached.
#   2 export  zebrad restarted on the same state with --network none (no peers, so its chain
#             cannot move), RPC on its loopback; the harvest client joins its network namespace
#             and fetches getblockhash / getblock <hash> 0 for 0..LAST into raw/.
#   3 pack    in the pinned pack image, with no network: verify raw/, gzip -n -9, manifest.json,
#             SHA256SUMS into out/; then `verify out/` from the .gz files alone.
#
# Needs: docker, bash. state/ ends up owned by uid 10001 (Zebra's user); remove it with
# `docker run --rm -v "$WORK:/w" busybox rm -rf /w/state` or sudo.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LAST=${1:-${LAST_HEIGHT:-510247}}
WORK=${WORK:-$PWD/prefix-work}
WORKERS=${WORKERS:-4}
SYNC_TIMEOUT_MIN=${SYNC_TIMEOUT_MIN:-0}
PROGRESS_MIN=${PROGRESS_MIN:-5}
PACK=ycash-prefix:local
SYNC=prefix-zebrad-sync
SERVE=prefix-zebrad-serve
COOKIE=/home/zebra/rpc-cookie/.cookie

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
if ! [[ $LAST =~ ^[0-9]+$ ]] || (( LAST > 510247 )); then die "LAST_HEIGHT must be an integer in 0..510247 (got '$LAST')"; fi
if ! [[ $WORKERS =~ ^[1-9][0-9]*$ && $SYNC_TIMEOUT_MIN =~ ^[0-9]+$ && $PROGRESS_MIN =~ ^[1-9][0-9]*$ ]]; then
  die "WORKERS and PROGRESS_MIN are positive integers, SYNC_TIMEOUT_MIN an integer"
fi

mkdir -p "$WORK/state"
WORK=$(cd "$WORK" && pwd)
rm -rf "$WORK/raw" "$WORK/out" "$WORK/rpc.cookie"
mkdir -p "$WORK/raw" "$WORK/out"
: > "$WORK/timings.txt"

cleanup() { docker rm -f "$SYNC" "$SERVE" >/dev/null 2>&1 || true; rm -f "$WORK/rpc.cookie"; }
trap cleanup EXIT
cleanup

log "building the pack image from $HERE"
docker build -q -t "$PACK" "$HERE" >/dev/null
ZEBRA_IMAGE=$(docker run --rm --network none "$PACK" constants | sed -n 's/^ZEBRA_IMAGE=//p')
[[ $ZEBRA_IMAGE == *@sha256:* ]] || die "no pinned ZEBRA_IMAGE from harvest.py"
log "zebrad image $ZEBRA_IMAGE; last height $LAST"

zebrad() {  # name network [docker run args...]
  local name=$1 net=$2; shift 2
  docker run -d --name "$name" --network "$net" --stop-signal SIGINT --stop-timeout 300 \
    -v "$WORK/state:/home/zebra/.cache/zebra" \
    -v "$HERE/zebrad.toml:/etc/zebrad/zebrad.toml:ro" \
    -e CONFIG_FILE_PATH=/etc/zebrad/zebrad.toml \
    -e ZEBRA_STATE__CACHE_DIR=/home/zebra/.cache/zebra \
    -e ZEBRA_RPC__COOKIE_DIR=/home/zebra/rpc-cookie \
    "$@" "$ZEBRA_IMAGE" >/dev/null
}
client() {  # name harvest-args...: the pack image inside zebrad's network namespace
  local name=$1; shift
  docker run --rm --network "container:$name" --user "$(id -u):$(id -g)" -v "$WORK:/work" "$PACK" "$@"
}
running() { [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }
tip() {  # name -> prints the height, or fails
  (umask 077; docker exec "$1" cat "$COOKIE" > "$WORK/rpc.cookie.tmp" 2>/dev/null) || return 1
  mv "$WORK/rpc.cookie.tmp" "$WORK/rpc.cookie"
  client "$1" tip --cookie-file /work/rpc.cookie 2>/dev/null
}
phase() { local s=$(( $(date +%s) - $2 )); printf '%-7s %6d s\n' "$1" "$s" >> "$WORK/timings.txt"; log "$1 took ${s} s"; }

# --- 1 sync ---------------------------------------------------------------------------------
t0=$(date +%s)
log "phase 1: sync Zcash testnet to $LAST (state in $WORK/state)"
zebrad "$SYNC" bridge -e "ZEBRA_STATE__DEBUG_STOP_AT_HEIGHT=$LAST"
next_log=0
while running "$SYNC"; do
  h=$(tip "$SYNC" || echo "?")
  now=$(date +%s); el=$(( (now - t0) / 60 ))
  if (( now >= next_log )); then log "sync: tip $h / $LAST after ${el} min"; next_log=$(( now + PROGRESS_MIN * 60 )); fi
  if [[ $h =~ ^[0-9]+$ ]] && (( h >= LAST )); then log "sync: tip $h reached $LAST"; docker stop "$SYNC" >/dev/null; break; fi
  if (( SYNC_TIMEOUT_MIN > 0 && el >= SYNC_TIMEOUT_MIN )); then
    log "sync: not at $LAST after $el min; stopping zebrad cleanly so state/ can resume"
    docker stop "$SYNC" >/dev/null
    phase sync "$t0"
    exit 3
  fi
  sleep 30
done
log "sync: zebrad exited ($(docker inspect -f '{{.State.ExitCode}}' "$SYNC")); last log lines:"
docker logs --tail 5 "$SYNC" 2>&1 | sed 's/^/  /'
docker rm "$SYNC" >/dev/null
phase sync "$t0"

# --- 2 export -------------------------------------------------------------------------------
t0=$(date +%s)
log "phase 2: export 0..$LAST from zebrad with no network"
zebrad "$SERVE" none
h="?"
for _ in $(seq 1 60); do
  running "$SERVE" || { docker logs --tail 30 "$SERVE" >&2; die "zebrad (export) exited"; }
  h=$(tip "$SERVE" || echo "?")
  [[ $h =~ ^[0-9]+$ ]] && break
  sleep 10
done
[[ $h =~ ^[0-9]+$ ]] || { docker logs --tail 30 "$SERVE" >&2; die "zebrad RPC did not answer"; }
(( h >= LAST )) || die "zebrad's state ends at $h, below $LAST: the sync did not finish"
log "export: zebrad tip $h"
client "$SERVE" export --cookie-file /work/rpc.cookie --last-height "$LAST" --raw-dir /work/raw --workers "$WORKERS"
docker stop "$SERVE" >/dev/null
phase export "$t0"

# --- 3 pack + verify ------------------------------------------------------------------------
t0=$(date +%s)
log "phase 3: pack in $PACK (no network)"
docker run --rm --network none --user "$(id -u):$(id -g)" -v "$WORK:/work" "$PACK" \
  pack --last-height "$LAST" --raw-dir /work/raw --out-dir /work/out
docker run --rm --network none --user "$(id -u):$(id -g)" -v "$WORK/out:/out:ro" "$PACK" verify /out
phase pack "$t0"

log "done: $WORK/out"
cat "$WORK/out/SHA256SUMS"
