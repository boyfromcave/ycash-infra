#!/bin/sh
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# The node container's command: adds the per-pod arguments a template cannot know (this pod's
# -externalip by ordinal, the in-cluster peers other than itself, the prefix -loadblock files until
# the import is done), then execs the image's own entrypoint (contrib/docker/ycashd/entrypoint.sh in
# both node trees), which writes ycash.conf from the YCASHD_* environment and execs ycashd.
#
# Environment: POD_NAME (the pod's name, from the downward API), EXTERNAL_ADDRESSES (space-separated,
# one per ordinal), PEERS (host:port, space-separated), DATADIR (default /var/lib/ycash).
set -eu
D="${DATADIR:-/var/lib/ycash}"
P="$D/prefix"
host="${POD_NAME:?POD_NAME is required (the downward API)}"
ord="${host##*-}"
set --
i=0
for a in ${EXTERNAL_ADDRESSES:-}; do
  [ "$i" = "$ord" ] && set -- "$@" "-externalip=$a"
  i=$((i + 1))
done
for p in ${PEERS:-}; do
  case "$p" in "$host".*) ;; *) set -- "$@" "-addnode=$p" ;; esac
done
if [ -e "$P/IMPORTED" ]; then
  # imported: the framed copies are no longer needed (the verified chunks stay, for audit)
  rm -rf "$P/load"
elif [ -e "$P/FRAMED" ]; then
  for f in "$P"/load/*.dat; do
    [ -e "$f" ] && set -- "$@" "-loadblock=$f"
  done
  echo "run: importing the prefix with $# arguments (the readiness probe marks it done at height ${PREFIX_LAST_HEIGHT:-?})"
fi
exec ycashd-entrypoint "$@"
