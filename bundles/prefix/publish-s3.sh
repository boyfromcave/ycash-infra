#!/usr/bin/env bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# In plain words: copies a finished, verified history bundle (the chunk files, treestate.json,
# manifest.json, SHA256SUMS) to an S3 location, once. It refuses to overwrite a bundle that is
# already there, and it uploads the two index files last, so a reader never sees a SHA256SUMS that
# names a file not yet uploaded. The bucket and the credentials come from the caller (the
# workflow's environment secrets, or the EC2 instance's role); nothing account-specific is here.
#
# Usage:  publish-s3.sh DIR s3://bucket/prefix/NAME
#   DIR must already pass `harvest.py verify` (this script runs it again first).
# Env:    AWS_REGION and credentials as the AWS CLI reads them; AWS=<cli> (default aws).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AWS=${AWS:-aws}
[ $# -eq 2 ] || { echo "usage: $0 DIR s3://bucket/prefix/NAME" >&2; exit 2; }
DIR=$1; DEST=${2%/}
[[ $DEST =~ ^s3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9](/[A-Za-z0-9._/-]+)?$ ]] || { echo "not an s3:// URI: $DEST" >&2; exit 2; }
[ -f "$DIR/SHA256SUMS" ] && [ -f "$DIR/manifest.json" ] || { echo "$DIR lacks SHA256SUMS or manifest.json" >&2; exit 2; }

python3 -I "$HERE/harvest.py" verify "$DIR" > /dev/null
if "$AWS" s3 ls "$DEST/manifest.json" > /dev/null 2>&1; then
  echo "$DEST/manifest.json exists; a published bundle is never overwritten" >&2; exit 1
fi
mapfile -t files < <(cut -d' ' -f3 "$DIR/SHA256SUMS")
n=0
for f in "${files[@]}"; do
  case "$f" in manifest.json) continue ;; esac
  "$AWS" s3 cp --only-show-errors "$DIR/$f" "$DEST/$f"
  n=$((n + 1))
done
"$AWS" s3 cp --only-show-errors "$DIR/manifest.json" "$DEST/manifest.json"
"$AWS" s3 cp --only-show-errors "$DIR/SHA256SUMS" "$DEST/SHA256SUMS"
echo "published $((n + 2)) files to $DEST"
