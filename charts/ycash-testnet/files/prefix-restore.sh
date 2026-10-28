#!/bin/sh
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# prefix-restore: fetch and verify the testnet prefix bundle (format ycash-prefix/1, workspace
# docs/plans/yellowback-testnet-plan.md §4.0; bundles/prefix/FORMAT.md in this repository) into
# $DATADIR/prefix, for the framer and then the node's -loadblock.
#
# In plain words: before a new testnet node starts for the first time, this downloads the copy of
# Zcash testnet's early history that the testnet is built on, and checks every byte of it against a
# fingerprint written into the deployment. If anything does not match, it stops and the node does
# not start. It never touches a node that already has data.
#
# Refuses (exit 1) when: the pinned sha256 is missing, SHA256SUMS does not hash to it, a file it
# lists does not check, a name is not a plain file name, or the manifest is not format
# ycash-prefix/1 / network zcash-testnet / last_height $PREFIX_LAST_HEIGHT with every chunk listed.
# Skips (exit 0) when the prefix is already verified, or when the datadir holds anything else:
# a restore goes only into an empty datadir.
#
# Environment: PREFIX_BASE_URL, PREFIX_SUMS_SHA256, PREFIX_LAST_HEIGHT, DATADIR (default
# /var/lib/ycash). Needs sh, curl, sha256sum and jq (the ycashd images have all four).
set -eu
D="${DATADIR:-/var/lib/ycash}"
P="$D/prefix"
say() { echo "prefix-restore: $*"; }
die() { echo "prefix-restore: REFUSED: $*" >&2; exit 1; }

[ -e "$P/VERIFIED" ] && { say "already verified ($P)"; exit 0; }
other=""
for f in "$D"/* "$D"/.[!.]* "$D"/..?*; do
  [ -e "$f" ] || continue
  case "${f##*/}" in lost+found|prefix) ;; *) other="$other ${f##*/}" ;; esac
done
if [ -n "$other" ]; then
  say "datadir $D is not empty:$other; not restoring, the node starts from what it has"
  exit 0
fi

: "${PREFIX_BASE_URL:?PREFIX_BASE_URL is required}"
: "${PREFIX_LAST_HEIGHT:?PREFIX_LAST_HEIGHT is required}"
echo "${PREFIX_SUMS_SHA256:-}" | grep -qxE '[0-9a-f]{64}' || die "PREFIX_SUMS_SHA256 is not a sha256 (the pin is required)"
base="${PREFIX_BASE_URL%/}"
mkdir -p "$P"
cd "$P"

fetch() {  # $1 = file name; resumes a partial download, retries transient errors
  curl -fsSL --proto '=https' --tlsv1.2 --retry 5 --retry-delay 5 -C - -o "$1" "$base/$1" \
    || { rm -f "$1"; die "download of $1 failed"; }
}

rm -f SHA256SUMS
fetch SHA256SUMS
echo "$PREFIX_SUMS_SHA256  SHA256SUMS" | sha256sum -c --status - \
  || die "SHA256SUMS hashes to $(sha256sum SHA256SUMS | cut -d' ' -f1), the pin is $PREFIX_SUMS_SHA256"

names=$(awk '{ n=$2; sub(/^\*/, "", n); print n }' SHA256SUMS)
[ -n "$names" ] || die "SHA256SUMS lists no file"
for n in $names; do
  echo "$n" | grep -qxE '[A-Za-z0-9][A-Za-z0-9._-]*' || die "SHA256SUMS lists '$n', not a plain file name"
done
echo "$names" | grep -qx manifest.json || die "SHA256SUMS does not cover manifest.json"

for n in $names; do
  if [ -f "$n" ] && echo "$(grep -E "[ *]$n\$" SHA256SUMS | cut -d' ' -f1)  $n" | sha256sum -c --status -; then
    say "$n already here and checks"; continue
  fi
  say "fetching $n"; fetch "$n"
done
if ! sha256sum -c --strict SHA256SUMS; then
  # drop what does not match, so the next attempt (the pod's restart) fetches it whole
  sha256sum -c SHA256SUMS 2>/dev/null | sed -n 's/: FAILED.*$//p' | while read -r n; do rm -f "$n"; done
  die "a file does not match SHA256SUMS"
fi

jq -e --argjson last "$PREFIX_LAST_HEIGHT" '
  .format == "ycash-prefix/1" and .network == "zcash-testnet"
  and .first_height == 0 and .last_height == $last and (.chunks | length) > 0' manifest.json >/dev/null \
  || die "manifest.json is not ycash-prefix/1 zcash-testnet 0..$PREFIX_LAST_HEIGHT"
for c in $(jq -r '.chunks[] | "\(.file)=\(.gz_sha256)"' manifest.json); do
  f=${c%%=*}; h=${c#*=}
  grep -qxE "$h [ *]$f" SHA256SUMS || die "manifest chunk $f ($h) is not in SHA256SUMS with that hash"
done
for n in $names; do
  [ "$n" = manifest.json ] && continue
  jq -e --arg f "$n" 'any(.chunks[]; .file == $f)' manifest.json >/dev/null || die "SHA256SUMS lists $n, the manifest does not"
done

touch VERIFIED
say "verified $(jq '.chunks | length' manifest.json) chunks, heights 0..$PREFIX_LAST_HEIGHT, in $P"
