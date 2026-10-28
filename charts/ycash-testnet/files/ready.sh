#!/bin/sh
# Ready = RPC answers and this node's height is within READINESS_LAG blocks of the best chain tip it
# knows that is not invalid (getchaintips, as charts/ycash-lightwallet's ready.sh, K3). No initial-
# block-download gate: a seed of a young or reset testnet stays in IBD while it is the network's
# only source of blocks. With a prefix import running (PREFIX_LAST_HEIGHT set), reaching that
# height marks the import done, so the next start does not pass -loadblock again (run.sh).
set -eu
D="${DATADIR:-/var/lib/ycash}"
CLI="ycash-cli -datadir=$D"
blocks=$($CLI getblockcount) || exit 1
best=$($CLI getchaintips | jq -r '[.[] | select(.status != "invalid") | .height] | max // 0')
if [ -n "${PREFIX_LAST_HEIGHT:-}" ] && [ -e "$D/prefix/FRAMED" ] && [ ! -e "$D/prefix/IMPORTED" ] \
   && [ "$blocks" -ge "$PREFIX_LAST_HEIGHT" ]; then
  touch "$D/prefix/IMPORTED"
fi
lag=$((best - blocks))
[ "$lag" -le "${READINESS_LAG:-1}" ] || { echo "lag $lag"; exit 1; }
echo "ready at $blocks"
