#!/bin/sh
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# zcash-params: put the three Zcash parameter files ycash-dd needs at start (sapling-spend.params,
# sapling-output.params, sprout-groth16.params; ycash-dd src/init.cpp ZC_LoadParams) into the
# params volume, each checked against the SHA256SUMS this chart carries
# (files/zcash-params.SHA256SUMS, a copy of bundles/zcash-params/SHA256SUMS, which copies the sums
# ycash-dd's zcutil/fetch-params.sh pins).
#
# In plain words: the ycash-dd node will not start without three large public files that Zcash
# published years ago. This downloads them once, from the mirror the deployment names, and checks
# each against a fingerprint written into the chart. Where they come from does not matter for
# safety: a file that does not match its fingerprint is thrown away and the node does not start.
#
# A present file that checks is kept (no download). A present file that does not check is removed
# and fetched again. A downloaded file that does not check is removed and the script refuses
# (exit 1); the pod's restart tries again. With the three files in place, the image's entrypoint
# skips its own zcutil/fetch-params.sh run.
#
# Environment: ZCASH_PARAMS_URL (the base URL; each file is fetched whole from <url>/<name>),
# ZCASH_PARAMS_SUMS (the SHA256SUMS file, default /opt/ycash/zcash-params.SHA256SUMS),
# PARAMS_DIR (default $HOME/.zcash-params). Needs sh, curl and sha256sum (the ycashd images have them).
set -eu
say() { echo "zcash-params: $*"; }
die() { echo "zcash-params: REFUSED: $*" >&2; exit 1; }

: "${ZCASH_PARAMS_URL:?ZCASH_PARAMS_URL is required}"
SUMS="${ZCASH_PARAMS_SUMS:-/opt/ycash/zcash-params.SHA256SUMS}"
DIR="${PARAMS_DIR:-${HOME:?HOME is required}/.zcash-params}"
base="${ZCASH_PARAMS_URL%/}"
case "$base" in https://*) ;; *) die "ZCASH_PARAMS_URL must be https:// ($base)" ;; esac

# The sums file must be exactly the three files, each a sha256 and a plain name.
[ -r "$SUMS" ] || die "no SHA256SUMS at $SUMS"
names=$(awk '{ print $2 }' "$SUMS" | sort | tr '\n' ' ')
[ "$names" = "sapling-output.params sapling-spend.params sprout-groth16.params " ] \
  || die "$SUMS does not list exactly the three parameter files (it lists: $names)"
grep -qvxE '[0-9a-f]{64}  (sapling-output|sapling-spend|sprout-groth16)\.params' "$SUMS" \
  && die "$SUMS has a line that is not '<sha256>  <name>'"

mkdir -p "$DIR"
cd "$DIR"
while read -r want name; do
  if [ -f "$name" ]; then
    if echo "$want  $name" | sha256sum -c --status -; then
      say "$name present and checks"; continue
    fi
    say "$name present but does not check; fetching it again"; rm -f "$name"
  fi
  say "fetching $base/$name"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 5 --retry-delay 5 -C - -o "$name.dl" "$base/$name" \
    || { rm -f "$name.dl"; die "download of $name failed"; }
  if ! echo "$want  $name.dl" | sha256sum -c --status -; then
    got=$(sha256sum "$name.dl" | cut -d' ' -f1); rm -f "$name.dl"
    die "$name hashes to $got, SHA256SUMS pins $want"
  fi
  mv "$name.dl" "$name"
  say "$name verified ($(wc -c < "$name") bytes)"
done < "$SUMS"
say "all three parameter files verified in $DIR"
