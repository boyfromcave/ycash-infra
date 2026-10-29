#!/bin/sh
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# The snapshotter and bundle verifier (workspace testnet plan §4.1-§4.3), one step per container of the
# snapshotter CronJob's pod (templates/snapshotter.yaml), in the node images (sh, ycashd-entrypoint,
# ycash-cli, curl, jq, GNU tar, gzip, sha256sum). The bundle it writes is bundles/state/FORMAT.md
# (`ycash-state/1`); bundles/state/verify.py re-checks one offline.
#
#   snapshot.sh pick            H_B from the reference node's tip (or SNAP_HEIGHT) -> $WORK/HEIGHT, or $WORK/SKIP
#   snapshot.sh produce         sync $DATADIR to H_B (-stopatheight), then pack it into $WORK/out
#   snapshot.sh restore-check   extract the tarball into an empty datadir, start it offline, write its statement
#   snapshot.sh verify          sync this line's own $DATADIR to H_B and write its statement (the ycash-dd leg)
#   snapshot.sh finalize        statements byte-identical -> manifest.json, SHA256SUMS; record the height
#   snapshot.sh publish-github  a GitHub release with the manifest, SHA256SUMS, the statements (and the tarball)
#   snapshot.sh publish-s3      the bundle to s3://$S3_BUCKET/$S3_PREFIX/<network>/<H_B>/ and .../latest/manifest.json
#
# Environment (the chart sets it): WORK (the per-run volume), DATADIR (the node's datadir), NETDIR (the
# network's datadir name: testnet-yb-fast, testnet-yb-slow, testnet-legacy), LINE (ycash6 | ycash-dd),
# STATE (where pick and finalize keep last-height; the producer's datadir), SNAP_EVERY, SNAP_DEPTH,
# SNAP_MIN_HEIGHT, SNAP_HEIGHT, SNAP_FORCE, FLAVOUR (full | full-insight), VERSION, REF_RPC_URL,
# YCASHD_RPC_USER / YCASHD_RPC_PASSWORD, STATEMENT_FIELDS, NODE_TIMEOUT (s), and the publish settings.
set -eu

WORK="${WORK:-/work}"
OUT="$WORK/out"
DATADIR="${DATADIR:-/var/lib/ycash}"
NETDIR="${NETDIR:?NETDIR is required (testnet-yb-fast, testnet-yb-slow or testnet-legacy)}"
STATE="${STATE:-$DATADIR}/.snapshotter"
FLAVOUR="${FLAVOUR:-full}"
STATEMENT_FIELDS="${STATEMENT_FIELDS:-network height blockhash chainwork utxo_hash_serialized vault_statehash yed_statehash}"
NODE_TIMEOUT="${NODE_TIMEOUT:-3600}"
LINE="${LINE:-ycash6}"

log() { echo "snapshot: $*"; }
die() { echo "snapshot: $*" >&2; exit 1; }
height() { cat "$WORK/HEIGHT"; }
skipped() { [ -e "$WORK/SKIP" ]; }
tarball_name() { echo "ycash6-$NETDIR-$(height)-$FLAVOUR.tar.gz"; }

# JSON-RPC to the reference node with the credential on curl's stdin config, never on its command line.
ref_rpc() {
  body=$(jq -cn --arg m "$1" --argjson p "${2:-[]}" '{jsonrpc: "1.0", id: "snapshot", method: $m, params: $p}')
  printf 'user = "%s:%s"\n' "$YCASHD_RPC_USER" "$YCASHD_RPC_PASSWORD" |
    curl -fsS -K - --max-time 30 -H 'Content-Type: text/plain' --data-binary "$body" "${REF_RPC_URL:?REF_RPC_URL}" |
    jq -e '.result'
}

pick() {
  mkdir -p "$OUT"
  rm -f "$WORK/SKIP" "$WORK/HEIGHT"
  every="${SNAP_EVERY:-1440}" depth="${SNAP_DEPTH:-1000}" min="${SNAP_MIN_HEIGHT:-510248}"
  if [ -n "${SNAP_HEIGHT:-}" ]; then
    h="$SNAP_HEIGHT"
  else
    tip=$(ref_rpc getblockcount) || die "the reference node ($REF_RPC_URL) did not answer getblockcount"
    h=$(( (tip - depth) / every * every ))
    log "reference tip $tip: H_B = $h (a multiple of $every at least $depth deep)"
  fi
  case "$h" in ''|*[!0-9]*) die "H_B '$h' is not a height" ;; esac
  if [ "$h" -lt "$min" ]; then
    log "H_B $h is below $min (the fork): nothing to bundle yet"; touch "$WORK/SKIP"; return 0
  fi
  last=$(cat "$STATE/last-height" 2>/dev/null || echo 0)
  if [ "$h" -le "$last" ] && [ "${SNAP_FORCE:-0}" != 1 ]; then
    log "H_B $h is not above the last bundle ($last): nothing to do"; touch "$WORK/SKIP"; return 0
  fi
  echo "$h" > "$WORK/HEIGHT"
  log "bundle height $h"
}

# Run the node in the foreground with -stopatheight=H_B until it stops by itself; fail on anything else.
sync_to_height() {
  h=$(height)
  log "$LINE: syncing $DATADIR to $h (-stopatheight)"
  YCASHD_DATADIR="$DATADIR" YCASHD_LISTEN=0 ycashd-entrypoint -stopatheight="$h" > "$WORK/$LINE-sync.log" 2>&1 &
  pid=$!
  tail -n +1 -f --pid="$pid" "$WORK/$LINE-sync.log" &
  rc=0; wait "$pid" || rc=$?
  [ "$rc" = 0 ] || die "$LINE: ycashd exited with status $rc before reaching $h"
  if ! grep -q -- "-stopatheight: the active chain is at height $h;" "$WORK/$LINE-sync.log"; then
    # a node that starts at or above H_B stops without the message (it connects nothing)
    [ "${SNAP_FORCE:-0}" = 1 ] || grep -q -- "-stopatheight:" "$WORK/$LINE-sync.log" ||
      die "$LINE: ycashd stopped without reaching $h (no -stopatheight line in its log)"
  fi
}

# The datadir's files that go into a bundle (FORMAT.md "Contents"), relative to $1, sorted bytewise.
bundle_files() {
  ( cd "$1" && find "$NETDIR/blocks" "$NETDIR/chainstate" "$NETDIR/vaults" "$NETDIR/yellowback" \
      \( -type d -o -type f \) 2>/dev/null ) |
    while IFS= read -r p; do
      case "$p" in
        "$NETDIR/blocks/insight-index"|"$NETDIR/blocks/insight-index/"*) [ "$FLAVOUR" = full-insight ] || continue ;;
        "$NETDIR/yellowback/carriers.dat") continue ;;
        */LOCK|*/LOG|*/LOG.old) continue ;;
      esac
      printf '%s\n' "$p"
    done | LC_ALL=C sort
}

pack() {
  [ -d "$DATADIR/$NETDIR/blocks" ] && [ -d "$DATADIR/$NETDIR/chainstate" ] || die "no $NETDIR/blocks or chainstate in $DATADIR"
  t="$OUT/$(tarball_name)"
  bundle_files "$DATADIR" > "$WORK/files.txt"
  [ -s "$WORK/files.txt" ] || die "nothing to pack"
  log "packing $(wc -l < "$WORK/files.txt") entries into $t"
  # the list is sorted and names every directory and file (no recursion), so the entry order is the list's
  tar --create --no-recursion --format=gnu --numeric-owner --owner=0 --group=0 --mtime=@0 \
      --mode='u=rwX,go=rX' -C "$DATADIR" -T "$WORK/files.txt" | gzip -n -6 > "$t.part"
  mv "$t.part" "$t"
  log "packed $(wc -c < "$t") bytes"
}

produce() {
  skipped && { log "skipped"; return 0; }
  sync_to_height
  pack
}

# Is every tar entry a regular file or directory under $NETDIR/, with no '..' and no absolute path?
check_entries() {
  tar -tvzf "$1" | while IFS= read -r line; do
    case "$line" in d*|-*) ;; *) die "a tarball entry that is neither a file nor a directory: $line" ;; esac
  done
  tar -tzf "$1" | while IFS= read -r p; do
    case "$p" in
      /*|../*|*/../*|*/..) die "unsafe tarball path: $p" ;;
      "$NETDIR"/*|"$NETDIR/") ;;
      *) die "tarball path outside $NETDIR/: $p" ;;
    esac
  done
}

cli() { ycash-cli -datadir="$NODE_DIR" "$@"; }

# Start ycashd offline on $NODE_DIR and wait until its tip stops moving (it connects whatever blocks the
# datadir already holds, above H_B too).
start_offline() {
  # no addnode= lines either: nothing may reach this node while it is measured
  YCASHD_DATADIR="$NODE_DIR" YCASHD_LISTEN=0 YCASHD_CONF_EXTRA="" \
    ycashd-entrypoint -connect=0 -dnsseed=0 -listen=0 > "$WORK/$1-offline.log" 2>&1 &
  NODE_PID=$!
  t=0; last=-1; same=0
  while :; do
    kill -0 "$NODE_PID" 2>/dev/null || { cat "$WORK/$1-offline.log" >&2; die "$1: ycashd exited while starting offline"; }
    if n=$(cli getblockcount 2>/dev/null); then
      if [ "$n" = "$last" ]; then same=$((same + 1)); else same=0; last=$n; fi
      [ "$same" -ge 3 ] && break
    fi
    t=$((t + 1)); [ "$t" -lt "$((NODE_TIMEOUT / 2))" ] || die "$1: the offline node did not settle in $NODE_TIMEOUT s"
    sleep "${POLL:-2}"
  done
}

stop_offline() {
  cli stop >/dev/null 2>&1 || true
  wait "$NODE_PID" || true
}

# The statement (FORMAT.md "Statement") of the node on $NODE_DIR at H_B, into $OUT/statement-$1.json.
# A tip above H_B is rolled back with invalidateblock (the datadir is a throwaway copy, or $2 = keep:
# reconsiderblock afterwards, so a kept datadir carries no failed-block mark).
statement() {
  name=$1 keep=${2:-}
  h=$(height)
  tip=$(cli getblockcount)
  [ "$tip" -ge "$h" ] || die "$name: the node's tip $tip is below H_B $h"
  above=""
  if [ "$tip" -gt "$h" ]; then
    above=$(cli getblockhash $((h + 1)))
    log "$name: tip $tip above $h: invalidateblock $above (rolled back for the statement)"
    cli invalidateblock "$above"
  fi
  bh=$(cli getblockhash "$h")
  [ "$(cli getbestblockhash)" = "$bh" ] || die "$name: the tip is not block $h after the rollback"
  hdr=$(cli getblockheader "$bh")
  utxo=$(cli gettxoutsetinfo | jq -r '.hash_serialized')
  vault=null
  if v=$(cli vault_getinfo 2>/dev/null); then
    vat=$(echo "$v" | jq -r '.dbtip.hash // empty')
    if [ -n "$vat" ] && [ "$vat" != "$bh" ]; then die "$name: vault state is at $vat, not $bh"; fi
    vault=$(echo "$v" | jq '.statehash // null')
  fi
  yed=null
  if y=$(cli yed_getstatehash "$h" 2>/dev/null); then
    [ "$(echo "$y" | jq -r '.blockhash')" = "$bh" ] || die "$name: yed_getstatehash is not at $bh"
    yed=$(echo "$y" | jq '.statehash')
  fi
  jq -n -S --arg network "$NETDIR" --argjson height "$h" --arg blockhash "$bh" \
     --arg chainwork "$(echo "$hdr" | jq -r '.chainwork')" --arg utxo "$utxo" \
     --argjson vault "$vault" --argjson yed "$yed" --arg fields "$STATEMENT_FIELDS" \
     '{network: $network, height: $height, blockhash: $blockhash, chainwork: $chainwork,
       utxo_hash_serialized: $utxo, vault_statehash: $vault, yed_statehash: $yed}
      | with_entries(select(.key as $k | ($fields | split(" ")) | index($k)))' > "$OUT/statement-$name.json"
  if [ "$name" = ycash6 ]; then
    # facts for the manifest (not part of the statement): the block's time and the node's version
    jq -n -S --argjson time "$(echo "$hdr" | jq '.time')" --arg subversion "$(cli getnetworkinfo | jq -r '.subversion')" \
      '{time: $time, subversion: $subversion}' > "$WORK/meta.json"
  fi
  if [ -n "$above" ] && [ "$keep" = keep ]; then cli reconsiderblock "$above"; fi
  log "$name: statement at $h written"
}

restore_check() {
  skipped && { log "skipped"; return 0; }
  t="$OUT/$(tarball_name)"
  check_entries "$t"
  NODE_DIR="$WORK/restore"
  rm -rf "$NODE_DIR"; mkdir -p "$NODE_DIR"
  tar -xzf "$t" -C "$NODE_DIR" --no-same-owner --no-same-permissions
  start_offline restore
  statement ycash6
  stop_offline
  rm -rf "$NODE_DIR"
}

verify() {
  skipped && { log "skipped"; return 0; }
  sync_to_height
  NODE_DIR="$DATADIR"
  start_offline "$LINE"
  statement "$LINE" keep
  stop_offline
}

finalize() {
  skipped && { log "skipped"; return 0; }
  h=$(height)
  t="$(tarball_name)"
  first=""
  for s in "$OUT"/statement-*.json; do
    [ -e "$s" ] || die "no statements"
    if [ -z "$first" ]; then first=$s; continue; fi
    cmp -s "$first" "$s" || { diff "$first" "$s" >&2 || true; die "the statements disagree: $(basename "$first") vs $(basename "$s")"; }
  done
  n=0; for st in "$OUT"/statement-*.json; do n=$((n + 1)); done
  [ "$n" -ge "${MIN_STATEMENTS:-2}" ] || die "$n statement(s); at least ${MIN_STATEMENTS:-2} are required"
  version="${VERSION:-}"
  [ -n "$version" ] || version=$(jq -r '.subversion' "$WORK/meta.json" | sed 's|^/[^:]*:||; s|/.*$||')
  created=$(jq -r '.time | todate' "$WORK/meta.json")
  sha=$(sha256sum "$OUT/$t" | cut -d' ' -f1)
  verifiers=$(cd "$OUT" && for st in statement-*.json; do st=${st#statement-}; printf '%s\n' "${st%.json}"; done | LC_ALL=C sort | jq -R . | jq -s -c .)
  jq -S --arg format ycash-state/1 --arg line ycash6 --arg version "$version" --arg flavour "$FLAVOUR" \
     --arg tarball "$t" --arg sha "$sha" --argjson bytes "$(wc -c < "$OUT/$t")" --arg created "$created" \
     --arg profile "${PROFILE:-}" --argjson verifiers "$verifiers" \
     '. + {format: $format, line: $line, version: $version, flavour: $flavour, profile: $profile,
           tarball: $tarball, sha256: $sha, bytes: $bytes, created: $created,
           producer: "ycash-infra/snapshotter", verifiers: $verifiers}' "$first" > "$OUT/manifest.json"
  ( cd "$OUT" && for f in *; do [ "$f" = SHA256SUMS ] || printf '%s\n' "$f"; done | LC_ALL=C sort |
      while IFS= read -r f; do sha256sum "$f"; done > SHA256SUMS.part && mv SHA256SUMS.part SHA256SUMS )
  mkdir -p "$STATE"
  echo "$h" > "$STATE/last-height"
  log "bundle $h verified by $n statements: $t ($sha)"
  cat "$OUT/manifest.json"
}

gh_api() {  # method url [curl args...]: the token on curl's stdin config, never on its command line
  m=$1 u=$2; shift 2
  printf 'header = "Authorization: Bearer %s"\n' "${GH_TOKEN:?GH_TOKEN}" |
    curl -fsS -K - -X "$m" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$@" "$u"
}

publish_github() {
  skipped && { log "skipped"; return 0; }
  repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY (owner/name)}"
  h=$(height); tag="state-$NETDIR-$h"; t="$(tarball_name)"
  body="State bundle $NETDIR at height $h (bundles/state/FORMAT.md). Tarball: ${TARBALL_URL:-attached}"
  jq -n --arg tag "$tag" --arg body "$body" --argjson draft "${GITHUB_DRAFT:-true}" \
     '{tag_name: $tag, name: $tag, body: $body, draft: $draft, prerelease: true}' > "$WORK/release.json"
  rel=$(gh_api POST "${GITHUB_API:-https://api.github.com}/repos/$repo/releases" --data-binary "@$WORK/release.json") ||
    die "creating release $tag failed (it may exist already)"
  id=$(echo "$rel" | jq -r '.id')
  for f in manifest.json SHA256SUMS "$OUT"/statement-*.json "$t"; do
    f=$(basename "$f")
    if [ "$f" = "$t" ]; then
      [ "${GITHUB_UPLOAD_TARBALL:-false}" = true ] || continue
      [ "$(wc -c < "$OUT/$f")" -lt 2147483648 ] || { log "$f is over GitHub's 2 GiB asset limit: not uploaded"; continue; }
    fi
    gh_api POST "${GITHUB_UPLOADS:-https://uploads.github.com}/repos/$repo/releases/$id/assets?name=$f" \
      -H 'Content-Type: application/octet-stream' --data-binary "@$OUT/$f" > /dev/null
    log "uploaded $f to $tag"
  done
}

publish_s3() {
  skipped && { log "skipped"; return 0; }
  h=$(height)
  dest="s3://${S3_BUCKET:?S3_BUCKET}/${S3_PREFIX:+$S3_PREFIX/}$NETDIR"
  t="$(tarball_name)"
  # the tarball and the statements first, the manifest and its sums last, then latest/
  for f in "$t" "$OUT"/statement-*.json SHA256SUMS manifest.json; do
    f=$(basename "$f")
    aws s3 cp --only-show-errors "$OUT/$f" "$dest/$h/$f"
  done
  aws s3 cp --only-show-errors "$OUT/manifest.json" "$dest/latest/manifest.json"
  log "published to $dest/$h/"
}

case "${1:-}" in
  pick) pick ;;
  produce) produce ;;
  restore-check) restore_check ;;
  verify) verify ;;
  finalize) finalize ;;
  publish-github) publish_github ;;
  publish-s3) publish_s3 ;;
  *) die "usage: snapshot.sh pick|produce|restore-check|verify|finalize|publish-github|publish-s3" ;;
esac
