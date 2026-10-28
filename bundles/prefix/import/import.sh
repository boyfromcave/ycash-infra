#!/usr/bin/env bash
# Import a Zcash-testnet prefix (format v1) into a fresh ycashd testnet datadir and record the result.
#
# In plain words: this takes the published copy of Zcash's old testnet history, hands it to a Ycash
# node as if it were a block file on disk, and checks that the node accepts every block and ends on
# exactly the blocks the copy says it holds. It writes down what the node reports at the end (the
# chain tip, the coin set's fingerprint, how long it took, how much disk it used).
#
# Usage:
#   import.sh --bin DIR --prefix DIR --mode checkpoints|full --work DIR --out FILE [options]
#
#   --bin DIR            directory holding ycashd and ycash-cli
#   --prefix DIR         the prefix: manifest.json, SHA256SUMS, zcash-testnet-prefix-v1-*.blocks.gz
#   --mode MODE          checkpoints (the node's defaults) or full (-checkpoints=0: every proof and
#                        script below the compiled checkpoints is verified too)
#   --work DIR           scratch directory; must not exist or be empty (framed files, datadir)
#   --out FILE           the result JSON
#   --line NAME          label for the result (ycash6, ycash-dd); default: unnamed
#   --node-sha SHA       the node commit, recorded in the result
#   --magic HEX          network magic for the framing (default fa1af9bf, both lines' testnet)
#   --paramsdir DIR      zk parameter directory, passed as -paramsdir (ycash-dd needs
#                        sapling-spend.params, sapling-output.params, sprout-groth16.params; ycash6
#                        needs none). Default: the node's own default (~/.zcash-params).
#   --dbcache MB         -dbcache (default 2048)
#   --stall-timeout SEC  fail when the block count has not moved for this long (default 1800)
#   --max-wait SEC       fail when the import has not finished after this long (default 21000)
#   --done-grace SEC     after the node has read every file, how long the tip may stay short of
#                        the last height before that counts as a refused block (default 120)
#   --poll SEC           seconds between progress polls (default 5)
#   --keep               keep the framed files and the datadir (default: remove them at the end)
#
# Exit status: 0 when every check passed, 1 when a check failed (the result JSON says which),
# 2 on a usage error. The prefix is data only: nothing from it is executed.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
MAGIC=fa1af9bf
DBCACHE=2048
STALL=1800
MAX_WAIT=21000
DONE_GRACE=120
POLL=5
LINE=unnamed
NODE_SHA=
PARAMSDIR=
KEEP=0
BIN='' PREFIX='' MODE='' WORK='' OUT=''
# Ycash's compiled testnet checkpoint and activation hashes at or below the fork
# (ycash6 src/chainparams.cpp:571, :427-428 and :431-432; ycash-dd :513, :383-384, :387-388). The node does not
# enforce all of them while importing (README "Node behaviour"), so the script checks them itself.
COMPILED=(
  38000:001e9a2d2e2892b88e9998cf7b079b41d59dd085423a921fe8386cecc42287b8
  207500:0000257c4331b098045023fcfbfa2474681f4564ab483f84e4e1ad078e4acf44
  280000:000420e7fcc3a49d729479fb0b560dd7b8617b178a08e9e389620a9d1dd6361a
)

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }
die() { echo "import.sh: $*" >&2; exit 2; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --bin) BIN=$2; shift 2 ;;
    --prefix) PREFIX=$2; shift 2 ;;
    --mode) MODE=$2; shift 2 ;;
    --work) WORK=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --line) LINE=$2; shift 2 ;;
    --node-sha) NODE_SHA=$2; shift 2 ;;
    --magic) MAGIC=$2; shift 2 ;;
    --paramsdir) PARAMSDIR=$2; shift 2 ;;
    --dbcache) DBCACHE=$2; shift 2 ;;
    --stall-timeout) STALL=$2; shift 2 ;;
    --max-wait) MAX_WAIT=$2; shift 2 ;;
    --done-grace) DONE_GRACE=$2; shift 2 ;;
    --poll) POLL=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument $1 (--help)" ;;
  esac
done
[ -n "$BIN" ] && [ -n "$PREFIX" ] && [ -n "$MODE" ] && [ -n "$WORK" ] && [ -n "$OUT" ] || usage
case "$MODE" in checkpoints|full) ;; *) die "--mode is checkpoints or full" ;; esac
case "$LINE" in *[!A-Za-z0-9._-]*|'') die "--line: letters, digits, . _ - only" ;; esac
case "$NODE_SHA" in *[!0-9a-f]*) die "--node-sha is a hex commit" ;; esac
for n in "$DBCACHE" "$STALL" "$MAX_WAIT" "$DONE_GRACE" "$POLL"; do case "$n" in *[!0-9]*|'') die "not a number: $n" ;; esac; done
YCASHD="$BIN/ycashd"; CLI="$BIN/ycash-cli"
[ -x "$YCASHD" ] && [ -x "$CLI" ] || die "$BIN must hold executable ycashd and ycash-cli"
[ -f "$PREFIX/manifest.json" ] && [ -f "$PREFIX/SHA256SUMS" ] || die "$PREFIX lacks manifest.json or SHA256SUMS"
[ -z "$PARAMSDIR" ] || [ -d "$PARAMSDIR" ] || die "--paramsdir $PARAMSDIR is not a directory"
if [ -e "$WORK" ] && [ -n "$(ls -A "$WORK")" ]; then die "--work $WORK is not empty"; fi
mkdir -p "$WORK" "$(dirname "$OUT")"
WORK=$(cd "$WORK" && pwd)
FRAMED="$WORK/framed"; DD="$WORK/datadir"; STATE="$WORK/state"
mkdir -p "$DD" "$STATE"

FAILURE=
NODE_PID=
T0=$(date +%s)
T_FRAMED=$T0; T_IMPORTED=$T0

cli() { timeout 600 "$CLI" -testnet -datadir="$DD" "$@"; }

debug_log() { find "$DD" -maxdepth 2 -name debug.log -print -quit; }

stop_node() {
  [ -n "$NODE_PID" ] || return 0
  if kill -0 "$NODE_PID" 2>/dev/null; then
    log "stopping ycashd (pid $NODE_PID)"
    cli stop >/dev/null 2>&1 || true
    for _ in $(seq 1 600); do kill -0 "$NODE_PID" 2>/dev/null || break; sleep 1; done
    if kill -0 "$NODE_PID" 2>/dev/null; then
      log "ycashd did not stop in 600 s: SIGTERM"
      kill -TERM "$NODE_PID" 2>/dev/null || true
      sleep 30
      kill -KILL "$NODE_PID" 2>/dev/null || true
      FAILURE=${FAILURE:-"ycashd did not stop cleanly"}
    fi
  fi
  wait "$NODE_PID" 2>/dev/null && echo 0 > "$STATE/exit" || echo $? > "$STATE/exit"
  NODE_PID=
}

write_result() {
  local t_end; t_end=$(date +%s)
  local dlog; dlog=$(debug_log || true)
  if [ -n "$dlog" ]; then tail -n 200 "$dlog" > "$STATE/debug-tail.log" || true; fi
  du -sb "$DD" 2>/dev/null | cut -f1 > "$STATE/datadir_bytes" || true
  python3 -I - "$STATE" "$OUT" "$LINE" "$NODE_SHA" "$MODE" "$FAILURE" "$T0" "$T_FRAMED" "$T_IMPORTED" "$t_end" \
      "$PREFIX/manifest.json" <<'PY'
import hashlib, json, os, sys
state, out, line, sha, mode, failure, t0, tf, ti, te, manifest = sys.argv[1:]
t0, tf, ti, te = (int(x) for x in (t0, tf, ti, te))

def load(name, default=None):
    p = os.path.join(state, name)
    if not os.path.exists(p):
        return default
    with open(p, encoding="utf-8", errors="replace") as f:
        text = f.read()
    if name.endswith(".json"):
        try:
            return json.loads(text)
        except ValueError:
            return {"unparsed": text[:2000]}
    return text.strip()

summary = load("summary.json", {}) or {}
info = load("getblockchaininfo.json")
utxo = load("gettxoutsetinfo.json")
checks = load("hash_checks.json", {"checked": 0, "mismatches": []})
with open(manifest, "rb") as f:
    manifest_sha = hashlib.sha256(f.read()).hexdigest()
size = load("datadir_bytes")
result = {
    "ok": not failure,
    "failure": failure or None,
    "line": line,
    "node_sha": sha or None,
    "mode": mode,
    "node_version": load("version"),
    "node_args": load("args.json"),
    "node_exit": load("exit"),
    "prefix": {
        "manifest_sha256": manifest_sha,
        "first_height": summary.get("first_height"),
        "last_height": summary.get("last_height"),
        "tip_hash": summary.get("tip_hash"),
        "chunks": summary.get("chunks"),
        "raw_bytes": summary.get("raw_bytes"),
        "magic": summary.get("magic"),
        "sources": summary.get("sources"),
    },
    "hash_checks": checks,
    "seconds": {"frame": tf - t0, "import": max(ti - tf, 0), "total": te - t0},
    "datadir_bytes": int(size) if size and size.isdigit() else None,
    "getblockchaininfo": info,
    "gettxoutsetinfo": utxo,
    "utxo": {k: utxo.get(k) for k in ("height", "bestblock", "transactions", "txouts", "hash_serialized", "total_amount")}
            if isinstance(utxo, dict) else None,
    "progress": load("progress.log"),
    "debug_log_tail": load("debug-tail.log") if failure else None,
}
with open(out, "w", encoding="utf-8") as f:
    f.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
PY
}

finish() {
  local rc=$?
  trap - EXIT
  stop_node
  if [ -z "$FAILURE" ] && [ "$rc" -ne 0 ]; then FAILURE="import.sh exited with status $rc"; fi
  write_result || echo "import.sh: could not write $OUT" >&2
  if [ "$KEEP" = 0 ]; then rm -rf "$FRAMED" "$DD"; fi
  if [ -n "$FAILURE" ]; then echo "import.sh: FAILED: $FAILURE" >&2; exit 1; fi
  log "OK: $LINE $MODE, result in $OUT"
  exit 0
}
trap finish EXIT
fail() { FAILURE=$*; exit 1; }

"$YCASHD" --version 2>/dev/null | head -n 1 > "$STATE/version" || true
log "node: $(cat "$STATE/version")"

# 1. Check the prefix as data and frame it.
expect=()
for e in "${COMPILED[@]}"; do expect+=(--expect "$e"); done
log "checking SHA256SUMS and the manifest, framing with magic $MAGIC"
python3 -I "$HERE/frame.py" --prefix "$PREFIX" --out "$FRAMED" --magic "$MAGIC" "${expect[@]}" \
  --summary "$STATE/summary.json" || fail "the prefix failed its checks (frame.py)"
T_FRAMED=$(date +%s)
mapfile -t FILES < <(python3 -I -c 'import json,sys; [print(p) for p in json.load(open(sys.argv[1]))["files"]]' "$STATE/summary.json")
LAST=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["last_height"])' "$STATE/summary.json")
TIP=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["tip_hash"])' "$STATE/summary.json")
log "framed ${#FILES[@]} files, heights 0..$LAST, tip $TIP"

# 2. Start the node on a fresh datadir, importing the framed files.
pw=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
port=$((20000 + RANDOM % 20000))
{
  echo "rpcuser=import"
  echo "rpcpassword=$pw"
  echo "rpcport=$port"
  echo "rpcbind=127.0.0.1"
  echo "rpcallowip=127.0.0.1"
} > "$DD/ycash.conf"
args=(-testnet -datadir="$DD" -server=1 -connect=0 -listen=0 -dnsseed=0 -discover=0 -disablewallet=1
      -printtoconsole=0 -dbcache="$DBCACHE")
[ "$MODE" = full ] && args+=(-checkpoints=0)
[ -n "$PARAMSDIR" ] && args+=(-paramsdir="$PARAMSDIR")
for f in "${FILES[@]}"; do args+=(-loadblock="$f"); done
python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${args[@]}" | sed "s#$WORK#<work>#g" > "$STATE/args.json"
log "starting ycashd: $(sed 's/"-loadblock=[^"]*",\{0,1\}//g' "$STATE/args.json") + ${#FILES[@]} -loadblock files"
"$YCASHD" "${args[@]}" > "$STATE/stdout.log" 2>&1 &
NODE_PID=$!

# 3. Wait for the tip to reach the manifest's last height.
start=$(date +%s); last_move=$start; last_report=0; prev=-1; blocks=-1
: > "$STATE/progress.log"
while :; do
  sleep "$POLL"
  now=$(date +%s)
  if ! kill -0 "$NODE_PID" 2>/dev/null; then
    wait "$NODE_PID" 2>/dev/null && echo 0 > "$STATE/exit" || echo $? > "$STATE/exit"
    NODE_PID=
    fail "ycashd exited during the import (status $(cat "$STATE/exit"), at height $blocks); see debug_log_tail"
  fi
  if info=$(cli getblockchaininfo 2>/dev/null); then
    bh=$(printf '%s' "$info" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(int(d["blocks"]), int(d["headers"]))') || continue
    read -r blocks headers <<< "$bh"
  else
    continue  # RPC warming up (loading the block index, verifying the parameters)
  fi
  if [ "$blocks" != "$prev" ]; then prev=$blocks; last_move=$now; fi
  if [ $((now - last_report)) -ge 60 ] || [ "$blocks" = "$LAST" ]; then
    el=$((now - start))
    line="elapsed ${el}s blocks $blocks headers $headers of $LAST ($(( blocks * 100 / (LAST > 0 ? LAST : 1) ))%)"
    log "$line"; echo "$line" >> "$STATE/progress.log"; last_report=$now
  fi
  [ "$blocks" = "$LAST" ] && break
  dlog=$(debug_log || true)
  if [ -n "$dlog" ]; then
    # Every -loadblock file read to its end, yet the tip is short of LAST: a block was refused.
    done_files=$(grep -c 'Loaded [0-9]* blocks from external file' "$dlog" || true)
    if [ "${done_files:-0}" -ge "${#FILES[@]}" ] && [ $((now - last_move)) -ge "$DONE_GRACE" ]; then
      fail "the import read every file but stopped at height $blocks of $LAST (a block was refused; see debug_log_tail)"
    fi
  fi
  [ "$blocks" -le "$LAST" ] || fail "the node is at $blocks, above the prefix's $LAST"
  [ $((now - last_move)) -lt "$STALL" ] || fail "no new block for ${STALL}s at height $blocks"
  [ $((now - start)) -lt "$MAX_WAIT" ] || fail "the import did not finish in ${MAX_WAIT}s (height $blocks)"
done
T_IMPORTED=$(date +%s)
log "tip at $LAST after $((T_IMPORTED - T_FRAMED))s"

# 4. Check the chain the node holds against the manifest and the compiled hashes.
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); [print(h, v) for h, v in sorted(d["hashes"].items(), key=lambda x: int(x[0]))]' \
  "$STATE/summary.json" > "$STATE/hash_heights"
checked=0; : > "$STATE/mismatches"
while read -r h want; do
  got=$(cli getblockhash "$h" 2>&1 || true)
  checked=$((checked + 1))
  [ "$got" = "$want" ] || echo "$h $want $got" >> "$STATE/mismatches"
done < "$STATE/hash_heights"
best=$(cli getbestblockhash)
[ "$best" = "$TIP" ] || echo "best $TIP $best" >> "$STATE/mismatches"
python3 -I -c '
import json, sys
mm = [dict(zip(("height", "expected", "got"), l.split(" ", 2))) for l in open(sys.argv[1]).read().splitlines()]
print(json.dumps({"checked": int(sys.argv[2]), "mismatches": mm}))' "$STATE/mismatches" "$checked" > "$STATE/hash_checks.json"
log "checked $checked hashes: $(wc -l < "$STATE/mismatches") mismatches"

cli getblockchaininfo > "$STATE/getblockchaininfo.json"
log "gettxoutsetinfo (walks the whole coin set)"
cli gettxoutsetinfo > "$STATE/gettxoutsetinfo.json"
stop_node
[ "$(cat "$STATE/exit")" = 0 ] || FAILURE=${FAILURE:-"ycashd stopped with status $(cat "$STATE/exit")"}
[ ! -s "$STATE/mismatches" ] || fail "hash mismatches: $(head -c 500 "$STATE/mismatches")"
[ -z "$FAILURE" ] || exit 1
