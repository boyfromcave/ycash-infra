#!/bin/bash
# Testnet seed: once the node holds the whole prefix, drop the -loadblock flags, recreate the
# container without them (one restart of the node) and delete the framed copies (about 1.1 GB).
#
# In plain words: the early testnet history is loaded from files only once; after that the files
# are deleted and the node keeps the history in its own database.
set -euo pipefail
# shellcheck source=/dev/null
. /opt/ycash-seed/seed.env
N=/srv/ycash-data/node
[ -d "$N/prefix/load" ] || exit 0
h=$(docker exec ycashd sh -c 'ycash-cli -datadir=/var/lib/ycash -conf=/var/lib/ycash/ycash.conf getblockcount' 2>/dev/null) || exit 0
[ "$h" -ge "$PREFIX_LAST_HEIGHT" ] || { echo "prefix import at $h of $PREFIX_LAST_HEIGHT"; exit 0; }
cp /opt/ycash-seed/node.env.base /opt/ycash-seed/node.env
touch "$N/prefix/IMPORTED"
docker compose -f /opt/ycash-seed/compose.yaml up -d
rm -rf "$N/prefix/load"
find "$N/prefix" -maxdepth 1 -name '*.blocks.gz' -delete
systemctl disable ycash-prefix-done.timer
echo "prefix imported (height $h); -loadblock retired"
