#!/bin/bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# The mainnet harvest instance: the whole job, from first boot to its own termination (cloud-init
# runcmd, once). Written by infra/mainnet-harvest; its settings are /opt/ycash-harvest/harvest.env.
#
# In plain words: this turns a fresh Ubuntu machine into a one-shot harvest job. It installs Docker,
# formats its own empty data disk, downloads ycash-infra at one fixed commit, reads the current
# mainnet peer list from the explorer, runs bundles/prefix/run-local-mainnet.sh (sync, export,
# verify, pack), uploads the finished bundle to the results bucket with publish-s3.sh and reads it
# back to check every byte. While it works it copies its log and a small status file to the bucket
# every few minutes. Then it shuts down, which terminates the instance and deletes its disks: the
# only thing that outlives it is what it put in the bucket. A timer set at boot ends it after
# MAX_HOURS whatever happens, so a stuck run cannot bill for ever.
#
# Bucket layout (the bucket comes from harvest.env; nothing account-specific is in this file):
#   runs/<run>/status.json   {"run","state":RUNNING|DONE|FAILED,"exit_code","stage","release_tag",...}
#   runs/<run>/harvest.log   this script's log (peer addresses are never printed)
#   runs/<run>/result.json   on DONE: release_tag, last_height, sums_sha256, files, bytes
#   runs/<run>/timings.txt, harvest-report.json   run-local-mainnet.sh's own records
#   prefix/<release_tag>/    the bundle (publish-s3.sh: never overwritten, index files last)
#
# Per run, the launching workflow may override these with instance tags (read through the instance
# metadata, validated here): HarvestRun (the run id), HarvestSplitHeight, HarvestReleaseTag,
# HarvestCrosscheck.
#
# Exit codes in status.json: 0 done; 3 the sync did not finish within the lifetime; 4 no usable
# mainnet peer; 5 no peer list from the explorer; 6 the uploaded bundle did not read back equal;
# 7 the instance is being reclaimed (spot interruption); anything else: the failing command's code.
set -uo pipefail
# The paths are fixed on the instance; the offline test (../tests/harvest-run.sh) moves them.
# shellcheck source=/dev/null
. "${HARVEST_ENV:-/opt/ycash-harvest/harvest.env}"
D=${HARVEST_DATA:-/data}                  # the data volume's mount point
LOG=${HARVEST_LOG:-/var/log/ycash-harvest.log}
R=${HARVEST_RUNDIR:-/run}
WORK=$D/work
SRC=$D/ycash-infra
HARVEST_USER=harvest
PUSH_POLL_SEC=${PUSH_POLL_SEC:-20}       # how often the pusher looks for a spot notice
STAGE_FILE=$R/ycash-harvest.stage    # the current stage, read by the status pusher too
STOP_FILE=$R/ycash-harvest.stop      # tells the status pusher to stop
STATE=RUNNING
RC=''
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
export PATH=${HARVEST_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin}
exec > >(tee -a "$LOG") 2>&1

log() { printf '%s harvest: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
retry() { local n=0; until "$@"; do n=$((n + 1)); [ "$n" -ge 20 ] && return 1; sleep 15; done; }

# 0. The lifetime cap, first of all: however the rest goes, the machine powers off (and, with
#    instance_initiated_shutdown_behavior = terminate, is deleted) MAX_HOURS after boot.
shutdown -h "+$((MAX_HOURS * 60))" "ycash-harvest: lifetime cap of $MAX_HOURS h" || true
log "lifetime cap: $MAX_HOURS h"

imds_token() { curl -fsS -m 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' http://169.254.169.254/latest/api/token; }
imds() {  # path -> value, or fails (404 for an absent tag or notice)
  local t; t=$(imds_token) || return 1
  curl -fsS -m 5 -H "X-aws-ec2-metadata-token: $t" "http://169.254.169.254/latest/meta-data/$1"
}
tag() { imds "tags/instance/$1" 2>/dev/null || true; }

REGION=$(retry imds placement/region) || { log "no region from the instance metadata"; shutdown -h now; exit 1; }
export AWS_DEFAULT_REGION=$REGION AWS_REGION=$REGION
INSTANCE=$(imds instance-id || echo unknown)
RUN=$(tag HarvestRun); [ -n "$RUN" ] || RUN="$INSTANCE"
t=$(tag HarvestSplitHeight); [ -z "$t" ] || SPLIT_HEIGHT=$t
t=$(tag HarvestReleaseTag); [ -z "$t" ] || RELEASE_TAG=$t
t=$(tag HarvestCrosscheck); [ -z "$t" ] || CROSSCHECK=$t
bad=''
[[ $RUN =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || bad="HarvestRun '$RUN'"
[[ $SPLIT_HEIGHT == auto || $SPLIT_HEIGHT =~ ^[0-9]{1,8}$ ]] || bad="HarvestSplitHeight '$SPLIT_HEIGHT'"
[[ $RELEASE_TAG =~ ^[a-z0-9][a-z0-9.-]{0,62}$ ]] || bad="HarvestReleaseTag '$RELEASE_TAG'"
[[ $CROSSCHECK == sync || $CROSSCHECK == none ]] || bad="HarvestCrosscheck '$CROSSCHECK'"
[ -z "$bad" ] || RUN=invalid-$INSTANCE
RUNS="s3://$BUCKET/runs/$RUN"
DEST="s3://$BUCKET/prefix/$RELEASE_TAG"

write_status() {  # FILE: the status document, from STATE, RC and the stage file
  printf '{"run": "%s", "state": "%s", "exit_code": %s, "stage": "%s", "release_tag": "%s", "split_height_input": "%s", "crosscheck": "%s", "started": "%s", "updated": "%s", "max_hours": %d, "infra_commit": "%s"}\n' \
    "$RUN" "$STATE" "${RC:-null}" "$(cat "$STAGE_FILE" 2>/dev/null || echo boot)" "$RELEASE_TAG" "$SPLIT_HEIGHT" \
    "$CROSSCHECK" "$STARTED" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MAX_HOURS" "$INFRA_COMMIT" > "$1"
}
upload() {  # copy the status, the log and run-local-mainnet.sh's records to runs/<run>/
  command -v aws >/dev/null 2>&1 || return 0
  local f; f=$(mktemp)
  write_status "$f"
  aws s3 cp --only-show-errors "$f" "$RUNS/status.json" || true
  rm -f "$f"
  aws s3 cp --only-show-errors "$LOG" "$RUNS/harvest.log" || true
  for f in timings.txt harvest-report.json; do
    [ ! -f "$WORK/$f" ] || aws s3 cp --only-show-errors "$WORK/$f" "$RUNS/$f" || true
  done
}
finish() {  # the one way out: final status, then power off (= terminate)
  local rc=$1
  trap - EXIT
  RC=$rc
  if [ "$rc" = 0 ]; then STATE=DONE; echo "done" > "$STAGE_FILE"; else STATE=FAILED; fi
  log "finished: $STATE (exit $rc, stage $(cat "$STAGE_FILE" 2>/dev/null))"
  # stop the pusher and wait for it, so its last upload can never land after this final one
  if [ -n "${PUSHER:-}" ]; then touch "$STOP_FILE"; wait "$PUSHER" 2>/dev/null || true; fi
  upload
  sync
  if [ "${HARVEST_NO_SHUTDOWN:-0}" != 1 ]; then shutdown -h now "ycash-harvest: $STATE"; fi
  exit "$rc"
}
trap 'finish $?' EXIT
step() { echo "$1" > "$STAGE_FILE"; log "stage: $1"; }
step boot
[ -z "$bad" ] || { log "invalid instance tag: $bad"; finish 2; }
log "run $RUN: release $RELEASE_TAG, split height $SPLIT_HEIGHT, cross-check $CROSSCHECK, ycash-infra $INFRA_COMMIT"

# 1. Packages: Docker, git, jq; the AWS CLI from its snap (Ubuntu 24.04 has no awscli package).
step install
export DEBIAN_FRONTEND=noninteractive
retry apt-get update -q || finish 1
retry apt-get install -y -q --no-install-recommends docker.io git jq curl python3 ca-certificates || finish 1
systemctl enable --now docker || finish 1
command -v aws >/dev/null 2>&1 || retry snap install aws-cli --classic || finish 1
upload

# 2. The data volume: the instance's one EBS disk without partitions besides the root disk.
#    Brand new on every launch (delete on termination), so it is always formatted.
step disk
root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1)
dev=''
for _ in $(seq 1 60); do
  while read -r name type model; do
    if [ "$type" != disk ] || [ "$(basename "$name")" = "$root_disk" ]; then continue; fi
    [[ $model == *Elastic\ Block\ Store* || $name == /dev/xvd* ]] || continue
    [ -z "$(lsblk -no PARTTYPE "$name" | tr -d '[:space:]')" ] || continue
    dev=$name; break 2
  done < <(lsblk -dpno NAME,TYPE,MODEL)
  sleep 5
done
[ -n "$dev" ] || { log "no data volume found"; finish 1; }
blkid -p "$dev" >/dev/null 2>&1 || mkfs.ext4 -q -L harvest-data "$dev" || finish 1
{ mkdir -p "$D" && mount -o noatime "$dev" "$D"; } || finish 1
id "$HARVEST_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G docker "$HARVEST_USER" || finish 1
install -d -o "$HARVEST_USER" -g "$HARVEST_USER" "$WORK" "$SRC" "$D/peers"
df -h "$D"

# 3. Status pusher: the status and the log to the bucket every STATUS_INTERVAL_SEC, and the spot
#    interruption notice (two minutes ahead) turned into a clean FAILED (exit 7) before the end.
rm -f "$STOP_FILE"
(
  next=0
  while [ ! -e "$STOP_FILE" ]; do
    if imds spot/instance-action >/dev/null 2>&1; then
      STATE=FAILED; RC=7
      echo "$(cat "$STAGE_FILE") (spot interruption)" > "$STAGE_FILE"
      log "spot interruption notice: the instance is being reclaimed; dispatch start again"
      upload; exit 0
    fi
    now=$(date +%s)
    if (( now >= next )); then upload; next=$(( now + STATUS_INTERVAL_SEC )); fi
    sleep "$PUSH_POLL_SEC"
  done
) &
PUSHER=$!

# 4. ycash-infra at the pinned commit (the scripts the harvest runs), checked out by its full id.
step checkout
sudo -u "$HARVEST_USER" -H bash -c 'set -e; cd "$1"; git init -q; git remote add origin "$2"
  git fetch -q --depth 1 origin "$3"; git -c advice.detachedHead=false checkout -q FETCH_HEAD
  [ "$(git rev-parse HEAD)" = "$3" ]' _ "$SRC" "$INFRA_REPO" "$INFRA_COMMIT" || { log "could not check out $INFRA_COMMIT"; finish 1; }

# 5. Peers, read from the explorer now (fetch_addnodes.py prints a count, never an address).
step peers
url_args=(); [ -z "$ADDNODES_URL" ] || url_args=(--url "$ADDNODES_URL")
sudo -u "$HARVEST_USER" -H python3 -I "$SRC/bundles/prefix/fetch_addnodes.py" "${url_args[@]}" --out "$D/peers/addnodes.txt" \
  || { log "no mainnet peers from the explorer"; finish 5; }

# 6. The harvest. The sync stops cleanly (exit 3) early enough to leave export, pack and upload
#    their time inside the lifetime cap.
step harvest
sync_min=$(( MAX_HOURS * 60 - RESERVE_MIN )); (( sync_min >= 60 )) || sync_min=60
rc=0
sudo -u "$HARVEST_USER" -H env PATH="$PATH" WORK="$WORK" CROSSCHECK="$CROSSCHECK" ADDNODES_FILE="$D/peers/addnodes.txt" \
  SYNC_TIMEOUT_MIN="$sync_min" PROGRESS_MIN=10 DBCACHE="$DBCACHE" \
  "$SRC/bundles/prefix/run-local-mainnet.sh" "$SPLIT_HEIGHT" || rc=$?
[ "$rc" = 0 ] || { log "run-local-mainnet.sh exited $rc"; finish "$rc"; }

# 7. Publish to prefix/<release_tag>/ (refuses an existing bundle; index files last), then read every
#    file back from the bucket and compare it with SHA256SUMS.
step publish
sudo -u "$HARVEST_USER" -H env PATH="$PATH" AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" \
  "$SRC/bundles/prefix/publish-s3.sh" "$WORK/out" "$DEST" || finish $?
step verify-upload
n=0; bytes=0
while read -r sum name; do
  got=$(aws s3 cp --only-show-errors "$DEST/$name" - | sha256sum | cut -d' ' -f1)
  [ "$got" = "$sum" ] || { log "read-back mismatch: $name"; finish 6; }
  n=$((n + 1)); bytes=$(( bytes + $(stat -c %s "$WORK/out/$name") ))
done < "$WORK/out/SHA256SUMS"
got=$(aws s3 cp --only-show-errors "$DEST/SHA256SUMS" - | sha256sum | cut -d' ' -f1)
sums=$(sha256sum "$WORK/out/SHA256SUMS" | cut -d' ' -f1)
[ "$got" = "$sums" ] || { log "read-back mismatch: SHA256SUMS"; finish 6; }
last=$(cat "$WORK/split-height")
printf '{"run": "%s", "release_tag": "%s", "last_height": %d, "sums_sha256": "%s", "files": %d, "bytes": %d, "prefix": "prefix/%s/", "infra_commit": "%s"}\n' \
  "$RUN" "$RELEASE_TAG" "$last" "$sums" "$((n + 1))" "$bytes" "$RELEASE_TAG" "$INFRA_COMMIT" > "$WORK/result.json"
aws s3 cp --only-show-errors "$WORK/result.json" "$RUNS/result.json" || finish 1
log "published and read back: $((n + 1)) files, $bytes bytes, split height $last, SHA256SUMS $sums"
finish 0
