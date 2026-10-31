#!/bin/bash
# shellcheck disable=SC2015  # `a && b || fail`: fail exits, so it is the if-then-else it reads as
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# Offline: files/harvest-run.sh (the instance's whole job) against fakes on PATH: the instance
# metadata (curl), the AWS CLI (a local directory stands in for the bucket), the disk tools, sudo
# and git (the "checkout" copies a fixture tree whose run-local-mainnet.sh is a stub; publish-s3.sh
# is the real one). No root, no network, no AWS. Checks the lifetime cap is set first, the status
# document at each end (DONE, the harvest's own exit code, a refused re-publish, a bad tag, a spot
# notice), the per-run tag overrides, the read-back check, and that it always powers off at the end.
# Run: infra/mainnet-harvest/tests/harvest-run.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MOD=$(cd "$HERE/.." && pwd)
PREFIX_DIR=$(cd "$MOD/../../bundles/prefix" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
COMMIT=0123456789abcdef0123456789abcdef01234567

# ---- the fixture tree the fake git "checks out" -------------------------------------------------
FX=$T/fixture/bundles/prefix
mkdir -p "$FX"
cp "$PREFIX_DIR/publish-s3.sh" "$FX/"
cat > "$FX/harvest.py" <<'EOF'
import sys
sys.exit(0)  # verify: accepted (the real checks are bundles/prefix/tests)
EOF
cat > "$FX/fetch_addnodes.py" <<'EOF'
import sys
out = sys.argv[sys.argv.index("--out") + 1]
open(out, "w").write("192.0.2.1:8833\n")
print("fetch_addnodes: 1 peers")
EOF
cat > "$FX/run-local-mainnet.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "run-local-mainnet $* CROSSCHECK=$CROSSCHECK SYNC_TIMEOUT_MIN=$SYNC_TIMEOUT_MIN DBCACHE=$DBCACHE ADDNODES_FILE=$(wc -l < "$ADDNODES_FILE")" >> "$FAKE_LOG"
sleep "${FAKE_HARVEST_SLEEP:-0}"
[ "${FAKE_HARVEST_RC:-0}" = 0 ] || exit "$FAKE_HARVEST_RC"
mkdir -p "$WORK/out"
printf 'chunk-a' > "$WORK/out/ycash-mainnet-0000000-0009999.blocks.gz"
printf '{"m":1}' > "$WORK/out/manifest.json"
printf '{"t":1}' > "$WORK/out/treestate.json"
(cd "$WORK/out" && sha256sum ycash-mainnet-0000000-0009999.blocks.gz manifest.json treestate.json > SHA256SUMS)
echo 9999 > "$WORK/split-height"
echo "sync 1 s" > "$WORK/timings.txt"
EOF
chmod +x "$FX/run-local-mainnet.sh" "$FX/publish-s3.sh"

# ---- fakes ---------------------------------------------------------------------------------------
B=$T/bin
mkdir -p "$B"
cat > "$B/curl" <<'EOF'
#!/bin/bash
url=${*: -1}
case "$url" in
  */api/token) echo tok ;;
  */meta-data/placement/region) echo xx-example-1 ;;
  */meta-data/instance-id) echo i-0test ;;
  */meta-data/spot/instance-action) [ -e "$FAKE_STATE/spot" ] && echo '{"action":"terminate"}' || exit 22 ;;
  */meta-data/tags/instance/*) k=${url##*/}; [ -e "$FAKE_STATE/tag-$k" ] && cat "$FAKE_STATE/tag-$k" || exit 22 ;;
  *) exit 22 ;;
esac
EOF
cat > "$B/aws" <<'EOF'
#!/bin/bash
# aws s3 cp SRC DST | aws s3 ls URI; s3://<bucket>/<key> is $FAKE_BUCKET/<bucket>/<key>
echo "aws $*" >> "$FAKE_LOG"
map() { case "$1" in s3://*) echo "$FAKE_BUCKET/${1#s3://}" ;; *) echo "$1" ;; esac; }
args=(); for a in "$@"; do case "$a" in --*) ;; *) args+=("$a") ;; esac; done
case "${args[0]} ${args[1]}" in
  "s3 ls") [ -e "$(map "${args[2]}")" ] ;;
  "s3 cp")
    src=$(map "${args[2]}"); dst=${args[3]}
    if [ "$dst" = - ]; then cat "$src"; exit; fi
    dst=$(map "$dst"); mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"
    case "$dst" in */status.json) cat "$dst" >> "$FAKE_STATE/status-history" ;; esac ;;
  *) exit 1 ;;
esac
EOF
cat > "$B/sudo" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -u) shift 2 ;; -H) shift ;; *) break ;; esac; done
exec "$@"
EOF
cat > "$B/git" <<'EOF'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    checkout) cp -r "$FAKE_FIXTURE"/. . ; exit 0 ;;
    rev-parse) echo "$FAKE_COMMIT"; exit 0 ;;
  esac
done
exit 0
EOF
cat > "$B/lsblk" <<'EOF'
#!/bin/bash
case "$*" in
  "-no PKNAME "*) echo nvme0n1 ;;
  "-dpno NAME,TYPE,MODEL") printf '/dev/nvme0n1 disk Amazon Elastic Block Store\n/dev/nvme1n1 disk Amazon Elastic Block Store\n' ;;
  "-no PARTTYPE /dev/nvme1n1") echo ;;
  "-no PARTTYPE "*) echo 0fc63daf ;;
esac
EOF
cat > "$B/install" <<'EOF'
#!/bin/bash
# install -d -o U -g G DIR...: the directories, without the owner
dirs=(); while [ $# -gt 0 ]; do case "$1" in -o|-g|-m) shift 2 ;; -*) shift ;; *) dirs+=("$1"); shift ;; esac; done
mkdir -p "${dirs[@]}"
EOF
cat > "$B/findmnt" <<'EOF'
#!/bin/bash
echo /dev/nvme0n1p1
EOF
cat > "$B/id" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$B/blkid" <<'EOF'
#!/bin/bash
exit 2
EOF
for c in shutdown apt-get systemctl snap mkfs.ext4 mount useradd; do
  # shellcheck disable=SC2016  # $* and $FAKE_LOG belong to the fake, not to this script
  printf '#!/bin/bash\necho "%s $*" >> "$FAKE_LOG"\n' "$c" > "$B/$c"
done
chmod +x "$B"/*

run() {  # [VAR=value ...]: one boot of the instance, from a clean state
  rm -rf "$T/state" "$T/data" "$T/run" "$T/log"
  mkdir -p "$T/state" "$T/data" "$T/run"
  : > "$T/log"
  cat > "$T/harvest.env" <<EOF
BUCKET=example-bucket
INFRA_REPO=https://example.org/example/ycash-infra.git
INFRA_COMMIT=$COMMIT
MAX_HOURS=48
RESERVE_MIN=360
SPLIT_HEIGHT=auto
CROSSCHECK=sync
RELEASE_TAG=mainnet-prefix-v1
ADDNODES_URL=
DBCACHE=4096
STATUS_INTERVAL_SEC=60
EOF
  for kv in "$@"; do
    case "$kv" in
      tag-*) printf '%s' "${kv#*=}" > "$T/state/${kv%%=*}" ;;
      spot) touch "$T/state/spot" ;;   # the instance metadata shows an interruption notice
      *) export "${kv?}" ;;
    esac
  done
  echo run-1 > "$T/state/tag-HarvestRun"
  for kv in "$@"; do case "$kv" in tag-HarvestRun=*) printf '%s' "${kv#*=}" > "$T/state/tag-HarvestRun" ;; esac; done
  rc=0
  env HARVEST_ENV="$T/harvest.env" HARVEST_DATA="$T/data" HARVEST_LOG="$T/harvest.log" HARVEST_RUNDIR="$T/run" \
    HARVEST_PATH="$B:/usr/bin:/bin" PUSH_POLL_SEC=1 FAKE_LOG="$T/log" FAKE_STATE="$T/state" \
    FAKE_BUCKET="$T/bucket" FAKE_FIXTURE="$T/fixture" FAKE_COMMIT="$COMMIT" \
    bash "$MOD/files/harvest-run.sh" > "$T/out" 2>&1 || rc=$?
  for kv in "$@"; do case "$kv" in tag-*|spot) ;; *) unset "${kv%%=*}" ;; esac; done
  return 0
}
st() { jq -r ".$2" "$T/bucket/example-bucket/runs/$1/status.json"; }
fail() { echo "FAIL: $*" >&2; cat "$T/out" >&2; echo "--- log" >&2; cat "$T/log" >&2; exit 1; }

# 1. a full run: the cap first, DONE, the bundle published and read back, result.json, power off
run
[ "$rc" = 0 ] || fail "success exits 0 (got $rc)"
[ "$(head -1 "$T/log")" = "shutdown -h +2880 ycash-harvest: lifetime cap of 48 h" ] || fail "the lifetime cap is the first thing set"
[ "$(st run-1 state)" = DONE ] && [ "$(st run-1 exit_code)" = 0 ] && [ "$(st run-1 stage)" = "done" ] || fail "status DONE"
[ "$(tail -1 "$T/log")" = "shutdown -h now ycash-harvest: DONE" ] || fail "powers off at the end"
P=$T/bucket/example-bucket/prefix/mainnet-prefix-v1
[ -f "$P/SHA256SUMS" ] && (cd "$P" && sha256sum -c --quiet SHA256SUMS) || fail "the bundle is in prefix/mainnet-prefix-v1/"
[ "$(jq -r '.last_height, .sums_sha256, .files' "$T/bucket/example-bucket/runs/run-1/result.json" | tr '\n' ' ')" = "9999 $(sha256sum < "$P/SHA256SUMS" | cut -d' ' -f1) 4 " ] || fail "result.json"
grep -q 'run-local-mainnet auto CROSSCHECK=sync SYNC_TIMEOUT_MIN=2520 DBCACHE=4096 ADDNODES_FILE=1' "$T/log" || fail "the harvest's arguments"
[ -f "$T/bucket/example-bucket/runs/run-1/harvest.log" ] && [ -f "$T/bucket/example-bucket/runs/run-1/timings.txt" ] || fail "log and timings uploaded"
! grep -q '192\.0\.2\.1' "$T/bucket/example-bucket/runs/run-1/harvest.log" || fail "a peer address in the log"
grep -q '"state": "RUNNING"' "$T/state/status-history" || fail "RUNNING was reported while it worked"
echo "ok - a full run: cap first, DONE, published, read back, result.json, powered off"

# 2. the same release again: publish-s3.sh refuses, FAILED at publish
run tag-HarvestRun=run-2
[ "$rc" = 1 ] && [ "$(st run-2 state)" = FAILED ] && [ "$(st run-2 stage)" = publish ] || fail "an existing bundle is never overwritten"
[ "$(tail -1 "$T/log")" = "shutdown -h now ycash-harvest: FAILED" ] || fail "powers off after a failure"
echo "ok - a second run for the same release is refused at publish"

# 3. the sync did not finish within the lifetime: the harvest's exit code 3, nothing published
run tag-HarvestRun=run-3 tag-HarvestReleaseTag=trial-3 FAKE_HARVEST_RC=3
[ "$(st run-3 state)" = FAILED ] && [ "$(st run-3 exit_code)" = 3 ] && [ "$(st run-3 stage)" = harvest ] || fail "exit 3 reported"
[ ! -e "$T/bucket/example-bucket/prefix/trial-3" ] || fail "nothing published after a failed harvest"
echo "ok - a harvest failure is FAILED with its exit code; nothing published"

# 4. per-run overrides from the instance tags
run tag-HarvestRun=trial-4 tag-HarvestReleaseTag=trial-4 tag-HarvestSplitHeight=19999 tag-HarvestCrosscheck=none
grep -q 'run-local-mainnet 19999 CROSSCHECK=none ' "$T/log" && [ -f "$T/bucket/example-bucket/prefix/trial-4/SHA256SUMS" ] || fail "tag overrides"
[ "$(st trial-4 state)" = DONE ] && [ "$(st trial-4 release_tag)" = trial-4 ] || fail "trial DONE"
echo "ok - the instance tags override split height, cross-check and release"

# 5. a tag that does not validate: nothing runs, FAILED 2 under runs/invalid-<instance>
run 'tag-HarvestRun=../x' tag-HarvestReleaseTag=trial-5
[ "$rc" = 2 ] && [ "$(st invalid-i-0test state)" = FAILED ] && ! grep -q run-local-mainnet "$T/log" || fail "a bad tag stops the run"
echo "ok - an invalid tag stops the run before anything is installed"

# 6. a spot interruption notice: reported as FAILED 7 while the instance is still up
run spot tag-HarvestRun=run-6 tag-HarvestReleaseTag=trial-6 FAKE_HARVEST_SLEEP=3 FAKE_HARVEST_RC=1
grep -q '"exit_code": 7' "$T/state/status-history" && grep -q 'spot interruption notice' "$T/harvest.log" || fail "spot notice reported"
echo "ok - a spot interruption notice is reported as FAILED 7"

echo "harvest-run: all checks passed"
