#!/bin/sh
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# prefix.sh fetch   download + verify the prefix into $DATADIR/prefix: prefix-restore.sh (SHA256SUMS
#                   against PREFIX_SUMS_SHA256, every file, the manifest), then SHA256SUMS.minisig
#                   against the Ycash release key. A bad signature removes VERIFIED and refuses.
# prefix.sh frame ARGS...   python3 -I frame.py ARGS... (the verified chunks to -loadblock files)
#
# Environment (fetch): as prefix-restore.sh, plus PREFIX_MINISIGN_PUB (default the baked key
# /opt/prefix/ycash-release.pub). PREFIX_CURL_PROTO (default =https) exists for local tests only.
set -eu
here=/opt/prefix
cmd="${1:-help}"; [ $# -gt 0 ] && shift
case "$cmd" in
  fetch)
    D="${DATADIR:-/var/lib/ycash}"; P="$D/prefix"
    already=0; [ -e "$P/VERIFIED" ] && [ -e "$P/SIGNED" ] && already=1
    [ "$already" = 1 ] && { echo "prefix: already verified and signed ($P)"; exit 0; }
    sh "$here/prefix-restore.sh"
    [ -e "$P/VERIFIED" ] || exit 0    # prefix-restore skipped a non-empty datadir
    base="${PREFIX_BASE_URL%/}"
    rm -f "$P/SHA256SUMS.minisig"
    curl -fsSL --proto "${PREFIX_CURL_PROTO:-=https}" --retry 5 --retry-delay 5 \
      -o "$P/SHA256SUMS.minisig" "$base/SHA256SUMS.minisig" \
      || { rm -f "$P/VERIFIED"; echo "prefix: REFUSED: download of SHA256SUMS.minisig failed" >&2; exit 1; }
    if ! minisign -Vq -m "$P/SHA256SUMS" -x "$P/SHA256SUMS.minisig" -p "${PREFIX_MINISIGN_PUB:-$here/ycash-release.pub}"; then
      rm -f "$P/VERIFIED" "$P/SHA256SUMS.minisig"
      echo "prefix: REFUSED: SHA256SUMS.minisig is not a signature by the Ycash release key" >&2; exit 1
    fi
    touch "$P/SIGNED"
    echo "prefix: SHA256SUMS signed by $(head -1 "${PREFIX_MINISIGN_PUB:-$here/ycash-release.pub}" | sed 's/.* //')"
    ;;
  frame) exec python3 -I "$here/frame.py" "$@" ;;
  *) sed -n '5,13p' "$0"; [ "$cmd" = help ] ;;
esac
