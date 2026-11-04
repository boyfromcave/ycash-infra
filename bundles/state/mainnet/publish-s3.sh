#!/usr/bin/env bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# In plain words: copies one finished, verified mainnet snapshot (a `ycash-state/2` or `kogany-state/1`/`2`
# bundle directory) to the object store the snapshotter and the restore read, once. It refuses to
# overwrite a published height, uploads the tarball first and the manifest and its sums last (a reader
# never sees a manifest that names a file not yet there), and moves `latest/manifest.json` only forward.
# The bucket and the credentials come from the caller; nothing account-specific is here.
#
# Usage:  publish-s3.sh DIR s3://bucket/prefix
#   ycash-state/2:   <prefix>/<network>/<H>/<file>         and <prefix>/<network>/latest/manifest.json
#   kogany-state/1, kogany-state/2 archive:
#                    <prefix>/kogany-<network>/<H>/<file>  and <prefix>/kogany-<network>/latest-<state_format>/manifest.json
#   kogany-state/2 pruned:
#                    <prefix>/kogany-<network>-pruned/<H>/<file>  and  .../kogany-<network>-pruned/latest-<state_format>/manifest.json
# The same <prefix>/<network>/<H>/ layout as the testnet snapshotter (bundles/state/FORMAT.md
# "Where it is published", charts/ycash-testnet/files/snapshot.sh publish-s3).
# Env:    AWS_REGION and credentials as the AWS CLI reads them; AWS=<cli> (default aws); DRY=1 prints only.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AWS=${AWS:-aws}
[ $# -eq 2 ] || { echo "usage: $0 DIR s3://bucket/prefix" >&2; exit 2; }
DIR=$1; BASE=${2%/}
[[ $BASE =~ ^s3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9](/[A-Za-z0-9._/-]+)?$ ]] || { echo "not an s3:// URI: $BASE" >&2; exit 2; }
python3 -I "$HERE/../verify.py" "$DIR" > /dev/null

field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$DIR/manifest.json" "$1"; }
format=$(field format); network=$(field network); height=$(field height); tarball=$(field tarball)
case "$format" in
  ycash-state/2) root="$BASE/$network"; latest="$root/latest/manifest.json" ;;
  kogany-state/1) root="$BASE/kogany-$network"; latest="$root/latest-$(field state_format)/manifest.json" ;;
  kogany-state/2)
    case "$(field storage_mode)" in
      pruned) root="$BASE/kogany-$network-pruned" ;;
      *) root="$BASE/kogany-$network" ;;
    esac
    latest="$root/latest-$(field state_format)/manifest.json" ;;
  *) echo "$DIR: format $format is not a mainnet snapshot (ycash-state/2, kogany-state/1, kogany-state/2)" >&2; exit 2 ;;
esac
dest="$root/$height"
run() { if [ "${DRY:-0}" = 1 ]; then echo "+ $*"; else "$@"; fi; }

if "$AWS" s3 ls "$dest/manifest.json" > /dev/null 2>&1; then
  echo "$dest/manifest.json exists; a published snapshot is never overwritten" >&2; exit 1
fi
run "$AWS" s3 cp --only-show-errors "$DIR/$tarball" "$dest/$tarball"
for f in "$DIR"/*; do
  f=$(basename "$f")
  case "$f" in "$tarball"|manifest.json|SHA256SUMS) continue ;; esac
  run "$AWS" s3 cp --only-show-errors "$DIR/$f" "$dest/$f"
done
run "$AWS" s3 cp --only-show-errors "$DIR/manifest.json" "$dest/manifest.json"
run "$AWS" s3 cp --only-show-errors "$DIR/SHA256SUMS" "$dest/SHA256SUMS"

# latest/ only moves forward: a checkpoint height published after the tip leaves it alone
cur=$("$AWS" s3 cp --only-show-errors "$latest" - 2>/dev/null |
      python3 -I -c 'import json,sys; print(json.load(sys.stdin)["height"])' 2>/dev/null || echo -1)
if [ "$height" -gt "$cur" ]; then
  run "$AWS" s3 cp --only-show-errors "$DIR/manifest.json" "$latest"
  echo "latest -> $height"
fi
echo "published $DIR to $dest/"
