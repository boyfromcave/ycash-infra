#!/usr/bin/env bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# In plain words: copies one finished, verified mainnet snapshot (a `ycash-state/2`, `ycash-state/3` or
# `kogany-state/1`/`2` bundle directory) to the object store the snapshotter and the restore read, once. It
# refuses to overwrite a published height, uploads the tarball (a `ycash-state/3` bundle: its parts, in
# order) first and the manifest and its sums last (a reader never sees a manifest that names a file not
# yet there), and moves `latest/manifest.json` only forward. It refuses any object over 49 GiB (the CDN
# serves none over 50 GB). Each `ycash-state/3` part is uploaded with its SHA-256 in the object's
# metadata (`sha256`); a re-run after an interrupted upload skips a part only when `head-object` reports
# its size and that hash, and after the parts every one is checked again by `head-object` before
# `manifest.json`, `SHA256SUMS` and `latest/` are written. `DRY=1` prints the uploads and calls nothing.
# The bucket and the credentials come from the caller; nothing account-specific is here.
#
# Usage:  publish-s3.sh DIR s3://bucket/prefix
#   ycash-state/2, ycash-state/3:
#                    <prefix>/<network>/<H>/<file>         and <prefix>/<network>/latest/manifest.json
#   ycash-state/2, ycash-state/3 full-insight:
#                    <prefix>/<network>-insight/<H>/<file> and <prefix>/<network>-insight/latest/manifest.json
#                    (its own latest: a full-insight datadir needs -insightexplorer -txindex to start)
#   kogany-state/1, kogany-state/2 archive:
#                    <prefix>/kogany-<network>/<H>/<file>  and <prefix>/kogany-<network>/latest-<state_format>/manifest.json
#   kogany-state/2 pruned:
#                    <prefix>/kogany-<network>-pruned/<H>/<file>  and  .../kogany-<network>-pruned/latest-<state_format>/manifest.json
# The same <prefix>/<network>/<H>/ layout as the testnet snapshotter (bundles/state/FORMAT.md
# "Where it is published", charts/ycash-testnet/files/snapshot.sh publish-s3).
# Env:    AWS_REGION and credentials as the AWS CLI reads them; AWS=<cli> (default aws); DRY=1 prints the
#         uploads and makes no call at all (no existence, head-object or latest/ read);
#         MAX_OBJECT_BYTES lowers the 49 GiB object guard (tests), never raises it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AWS=${AWS:-aws}
[ $# -eq 2 ] || { echo "usage: $0 DIR s3://bucket/prefix" >&2; exit 2; }
DIR=$1; BASE=${2%/}
[[ $BASE =~ ^s3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9](/[A-Za-z0-9._/-]+)?$ ]] || { echo "not an s3:// URI: $BASE" >&2; exit 2; }
python3 -I "$HERE/../verify.py" "$DIR" > /dev/null

# The CDN guard, in every format: no object over 49 GiB (verify.py checks it too; this is the second guard).
LIMIT=$((49 * 1024 * 1024 * 1024))
if [ -n "${MAX_OBJECT_BYTES:-}" ] && [ "$MAX_OBJECT_BYTES" -lt "$LIMIT" ]; then LIMIT=$MAX_OBJECT_BYTES; fi
big=$(find "$DIR" -maxdepth 1 -type f -size +"$LIMIT"c)
if [ -n "$big" ]; then
  echo "refusing: over the $LIMIT-byte object limit: $big" >&2; exit 1
fi

field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$DIR/manifest.json" "$1"; }
format=$(field format); network=$(field network); height=$(field height); tarball=$(field tarball)
# what is uploaded first, in stream order: the tarball, or a ycash-state/3 bundle's parts
# (for ycash-state/3, "<name> <sha256>" per part, from the manifest verify.py has just checked)
if [ "$format" = ycash-state/3 ]; then
  parts=$(python3 -I -c 'import json,sys; print("\n".join(p["name"] + " " + p["sha256"] for p in json.load(open(sys.argv[1]))["parts"]))' "$DIR/manifest.json")
  stored=$(cut -d' ' -f1 <<< "$parts")
else
  parts=
  stored=$tarball
fi
case "$format" in
  ycash-state/2|ycash-state/3)
    case "$(field flavour)" in
      full-insight) root="$BASE/$network-insight" ;;
      *) root="$BASE/$network" ;;
    esac
    latest="$root/latest/manifest.json" ;;
  kogany-state/1) root="$BASE/kogany-$network"; latest="$root/latest-$(field state_format)/manifest.json" ;;
  kogany-state/2)
    case "$(field storage_mode)" in
      pruned) root="$BASE/kogany-$network-pruned" ;;
      *) root="$BASE/kogany-$network" ;;
    esac
    latest="$root/latest-$(field state_format)/manifest.json" ;;
  *) echo "$DIR: format $format is not a mainnet snapshot (ycash-state/2, ycash-state/3, kogany-state/1, kogany-state/2)" >&2; exit 2 ;;
esac
dest="$root/$height"
dry() { [ "${DRY:-0}" = 1 ]; }
run() { if dry; then echo "+ $*"; else "$@"; fi; }

if ! dry && "$AWS" s3 ls "$dest/manifest.json" > /dev/null 2>&1; then
  echo "$dest/manifest.json exists; a published snapshot is never overwritten" >&2; exit 1
fi
# "<size> <sha256 metadata>" of an object already at the destination, empty when there is none
# (an object uploaded without the metadata reads "<size> None": never taken for a part)
remote_part() {
  local uri=${1#s3://}
  "$AWS" s3api head-object --bucket "${uri%%/*}" --key "${uri#*/}" \
    --query '[ContentLength, Metadata.sha256]' --output text 2>/dev/null | tr -s ' \t' '  ' || true
}
if [ -n "$parts" ]; then
  while read -r f sha; do
    size=$(wc -c < "$DIR/$f" | tr -d ' ')
    if ! dry && [ "$(remote_part "$dest/$f")" = "$size $sha" ]; then
      echo "$f: already uploaded ($size bytes, sha256 $sha)"; continue
    fi
    run "$AWS" s3 cp --only-show-errors --metadata "sha256=$sha" "$DIR/$f" "$dest/$f"
  done <<< "$parts"
  # every part is at the destination with its size and hash before anything names it
  if ! dry; then
    while read -r f sha; do
      size=$(wc -c < "$DIR/$f" | tr -d ' ')
      got=$(remote_part "$dest/$f")
      if [ "$got" != "$size $sha" ]; then
        echo "refusing to publish: $dest/$f reads '${got:-missing}', expected '$size $sha'; manifest.json, SHA256SUMS and latest/ are not written" >&2
        exit 1
      fi
    done <<< "$parts"
  fi
else
  run "$AWS" s3 cp --only-show-errors "$DIR/$stored" "$dest/$stored"
fi
for f in "$DIR"/*; do
  f=$(basename "$f")
  if [ "$f" = manifest.json ] || [ "$f" = SHA256SUMS ] || grep -qxF -- "$f" <<< "$stored"; then continue; fi
  run "$AWS" s3 cp --only-show-errors "$DIR/$f" "$dest/$f"
done
run "$AWS" s3 cp --only-show-errors "$DIR/manifest.json" "$dest/manifest.json"
run "$AWS" s3 cp --only-show-errors "$DIR/SHA256SUMS" "$dest/SHA256SUMS"

# latest/ only moves forward: a checkpoint height published after the tip leaves it alone
if dry; then
  echo "+ $AWS s3 cp --only-show-errors $DIR/manifest.json $latest   (only when $height is above the height there)"
  echo "dry run: nothing was read or written"; exit 0
fi
cur=$("$AWS" s3 cp --only-show-errors "$latest" - 2>/dev/null |
      python3 -I -c 'import json,sys; print(json.load(sys.stdin)["height"])' 2>/dev/null || echo -1)
if [ "$height" -gt "$cur" ]; then
  run "$AWS" s3 cp --only-show-errors "$DIR/manifest.json" "$latest"
  echo "latest -> $height"
fi
echo "published $DIR to $dest/"
