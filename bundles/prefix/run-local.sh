#!/usr/bin/env bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# In plain words: this makes the Zcash-testnet prefix files on any machine with Docker. It runs
# a Zcash node (Zebra) until it has the blocks up to the prefix's last height, copies those blocks
# out while the node keeps running, checks every one, and packs them. Run it twice, or on two
# machines, and the SHA256SUMS files come out identical: that is the audit (README.md).
#
# Usage:  bundles/prefix/run-local.sh [LAST_HEIGHT]      (default 510247; 4799 is the smoke range)
# Env:    WORK=<dir>           work directory (default ./prefix-work): state/, raw/, out/
#         WORKERS=<n>          concurrent RPC requests during export (default 4)
#         SYNC_TIMEOUT_MIN=<n> give up the sync after n minutes, keeping state/ to resume (0 = never)
#         PROGRESS_MIN=<n>     log the sync height every n minutes (default 5)
#         TIP_MARGIN=<n>       start the export once Zebra's tip is LAST+n (default 10)
#         POLL_SEC=<n>         seconds between tip polls (default 30)
#
# Phases (each logs its duration to $WORK/timings.txt):
#   1 sync    zebrad (harvest.ZEBRA_IMAGE) on Testnet, with the network, RPC on its loopback; the
#             script polls getblockchaininfo until the tip is LAST+TIP_MARGIN, so every exported
#             block is buried under at least TIP_MARGIN more. state/ can be cached.
#   2 export  zebrad keeps running (and syncing); the harvest client joins its network namespace
#             and fetches getblockhash / getblock <hash> 0 for 0..LAST into raw/, checking the hash
#             chain and the checkpoints as it goes; then zebrad is stopped cleanly (SIGINT).
#   3 pack    in the pinned pack image, with no network: verify raw/, gzip -n -9, manifest.json,
#             SHA256SUMS into out/; then `verify out/` from the .gz files alone.
#
# Why one zebrad run and no restart without the network (Zebra v7.0.0, e8db87eb69): the RPC
# server starts only after network init (zebrad/src/commands/start.rs:388-395 before :512-514),
# network init waits for the initial peers (zebra-network/src/peer_set/initialize.rs:320-336),
# and those wait for at least one DNS seeder to resolve, retrying forever
# (zebra-network/src/config.rs:307-343). With --network none Zebra never answers RPC. The RPCs
# used here do not wait for the sync (zebra-rpc/src/methods.rs:1351 getblockchaininfo, :1572
# getblock, :2692 getblockhash read the state directly). Blocks this deep are below Zebra's
# testnet checkpoints, so they are final; the export re-checks the hash chain anyway.
#
# Needs: docker, bash. state/ ends up owned by uid 10001 (Zebra's user); remove it with
# `docker run --rm -v "$WORK:/w" busybox rm -rf /w/state` or sudo. It may extend past LAST.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LAST=${1:-${LAST_HEIGHT:-510247}}
WORK=${WORK:-$PWD/prefix-work}
WORKERS=${WORKERS:-4}
SYNC_TIMEOUT_MIN=${SYNC_TIMEOUT_MIN:-0}
PROGRESS_MIN=${PROGRESS_MIN:-5}
TIP_MARGIN=${TIP_MARGIN:-10}
POLL_SEC=${POLL_SEC:-30}
PACK=ycash-prefix:local
ZEBRA=prefix-zebrad
COOKIE=/home/zebra/rpc-cookie/.cookie

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
if ! [[ $LAST =~ ^[0-9]+$ ]] || (( LAST > 510247 )); then die "LAST_HEIGHT must be an integer in 0..510247 (got '$LAST')"; fi
if ! [[ $WORKERS =~ ^[1-9][0-9]*$ && $PROGRESS_MIN =~ ^[1-9][0-9]*$ && $POLL_SEC =~ ^[1-9][0-9]*$
        && $SYNC_TIMEOUT_MIN =~ ^[0-9]+$ && $TIP_MARGIN =~ ^[0-9]+$ ]]; then
  die "WORKERS, PROGRESS_MIN and POLL_SEC are positive integers, SYNC_TIMEOUT_MIN and TIP_MARGIN integers"
fi
TARGET=$(( LAST + TIP_MARGIN ))

mkdir -p "$WORK/state"
WORK=$(cd "$WORK" && pwd)
rm -rf "$WORK/raw" "$WORK/out" "$WORK/rpc.cookie"
mkdir -p "$WORK/raw" "$WORK/out"
: > "$WORK/timings.txt"

# a clean stop first (SIGINT, so Zebra flushes its state for the cache), then remove
cleanup() { docker stop "$ZEBRA" >/dev/null 2>&1 || true; docker rm -f "$ZEBRA" >/dev/null 2>&1 || true; rm -f "$WORK/rpc.cookie"; }
trap cleanup EXIT
cleanup

log "building the pack image from $HERE"
docker build -q -t "$PACK" "$HERE" >/dev/null
ZEBRA_IMAGE=$(docker run --rm --network none "$PACK" constants | sed -n 's/^ZEBRA_IMAGE=//p')
[[ $ZEBRA_IMAGE == *@sha256:* ]] || die "no pinned ZEBRA_IMAGE from harvest.py"
log "zebrad image $ZEBRA_IMAGE; last height $LAST"

zebrad() {  # name: Testnet with the network (bridge), RPC on the container's loopback
  docker run -d --name "$1" --network bridge --stop-signal SIGINT --stop-timeout 300 \
    -v "$WORK/state:/home/zebra/.cache/zebra" \
    -v "$HERE/zebrad.toml:/etc/zebrad/zebrad.toml:ro" \
    -e CONFIG_FILE_PATH=/etc/zebrad/zebrad.toml \
    -e ZEBRA_STATE__CACHE_DIR=/home/zebra/.cache/zebra \
    -e ZEBRA_RPC__COOKIE_DIR=/home/zebra/rpc-cookie \
    "$ZEBRA_IMAGE" >/dev/null
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
log "phase 1: sync Zcash testnet to $TARGET (= $LAST + $TIP_MARGIN; state in $WORK/state)"
zebrad "$ZEBRA"
next_log=0
while :; do
  if ! running "$ZEBRA"; then
    docker logs --tail 30 "$ZEBRA" >&2 || true
    die "zebrad exited during the sync (code $(docker inspect -f '{{.State.ExitCode}}' "$ZEBRA" 2>/dev/null || echo '?'))"
  fi
  h=$(tip "$ZEBRA" || echo "?")
  now=$(date +%s); el=$(( (now - t0) / 60 ))
  if (( now >= next_log )); then log "sync: tip $h / $TARGET after ${el} min"; next_log=$(( now + PROGRESS_MIN * 60 )); fi
  if [[ $h =~ ^[0-9]+$ ]] && (( h >= TARGET )); then log "sync: tip $h reached $TARGET"; break; fi
  if (( SYNC_TIMEOUT_MIN > 0 && el >= SYNC_TIMEOUT_MIN )); then
    log "sync: not at $TARGET after $el min; stopping zebrad cleanly so state/ can resume"
    docker stop "$ZEBRA" >/dev/null
    phase sync "$t0"
    exit 3
  fi
  sleep "$POLL_SEC"
done
phase sync "$t0"

# --- 2 export -------------------------------------------------------------------------------
# zebrad keeps running and syncing: heights 0..LAST stay where they are (checkpointed, final),
# and the export checks the hash chain from the genesis, so a moved block would fail loudly.
t0=$(date +%s)
log "phase 2: export 0..$LAST from the running zebrad"
client "$ZEBRA" export --cookie-file /work/rpc.cookie --last-height "$LAST" --raw-dir /work/raw --workers "$WORKERS"
log "export: done; zebrad tip now $(tip "$ZEBRA" || echo '?'); stopping it"
docker stop "$ZEBRA" >/dev/null
log "zebrad exited ($(docker inspect -f '{{.State.ExitCode}}' "$ZEBRA")); last log lines:"
docker logs --tail 5 "$ZEBRA" 2>&1 | sed 's/^/  /'
docker rm "$ZEBRA" >/dev/null
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
