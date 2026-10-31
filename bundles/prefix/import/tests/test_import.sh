#!/usr/bin/env bash
# import.sh against the stand-in node (tests/mocknode) on a prefix of Zcash testnet blocks 0..10:
# a clean import in both modes, a refused block, a corrupted prefix, a non-empty work directory.
# Run: bundles/prefix/import/tests/test_import.sh
set -euo pipefail
T=$(cd "$(dirname "$0")" && pwd)
IMPORT="$T/../import.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
python3 -I "$T/make_prefix.py" --hex "$T/data/zcash-testnet-blocks-0-10.hex" --out "$TMP/prefix" >/dev/null
fast=(--poll 1 --done-grace 3 --stall-timeout 30 --max-wait 120)
pass=0
check() { # name, python expression over the result `r`
  python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); assert eval(sys.argv[2]), (sys.argv[2], r)' "$1" "$2"
}

for mode in checkpoints full; do
  "$IMPORT" --bin "$T/mocknode" --prefix "$TMP/prefix" --mode "$mode" --work "$TMP/w-$mode" \
    --out "$TMP/r-$mode.json" --line mock --node-sha 0123abcd "${fast[@]}" > "$TMP/log-$mode" 2>&1 \
    || { cat "$TMP/log-$mode"; echo "FAIL: $mode import"; exit 1; }
  r="$TMP/r-$mode.json"
  check "$r" 'r["ok"] and r["failure"] is None and r["mode"] == "'"$mode"'"'
  check "$r" 'r["utxo"]["height"] == 10 and r["utxo"]["bestblock"] == r["prefix"]["tip_hash"]'
  check "$r" 'r["prefix"]["tip_hash"] == "079f4c752729be63e6341ee9bce42fbbe37236aba22e3deb82405f3c2805c112"'
  check "$r" 'r["hash_checks"] == {"checked": 2, "mismatches": []}'
  check "$r" '("-checkpoints=0" in r["node_args"]) == ("'"$mode"'" == "full")'
  check "$r" 'r["node_exit"] == "0" and r["datadir_bytes"] and r["seconds"]["total"] >= 0'
  [ ! -e "$TMP/w-$mode/datadir" ] || { echo "FAIL: datadir not removed"; exit 1; }
  pass=$((pass + 1))
done

# a refused block: the tip stops short and the result says where
rc=0
MOCK_REFUSE_AT=7 "$IMPORT" --bin "$T/mocknode" --prefix "$TMP/prefix" --mode full --work "$TMP/w-refuse" \
  --out "$TMP/r-refuse.json" "${fast[@]}" > "$TMP/log-refuse" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$TMP/log-refuse"; echo "FAIL: refused block exit $rc"; exit 1; }
check "$TMP/r-refuse.json" 'not r["ok"] and "stopped at height 6 of 10" in r["failure"] and "mock refusal" in r["debug_log_tail"]'
pass=$((pass + 1))

# a corrupted chunk: refused before the node starts
cp -r "$TMP/prefix" "$TMP/bad"
f=$(find "$TMP/bad" -name "*.blocks.gz" | sort | head -1); printf '\x00' | dd of="$f" bs=1 seek=50 conv=notrunc status=none
rc=0
"$IMPORT" --bin "$T/mocknode" --prefix "$TMP/bad" --mode checkpoints --work "$TMP/w-bad" \
  --out "$TMP/r-bad.json" "${fast[@]}" > "$TMP/log-bad" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$TMP/log-bad"; echo "FAIL: corrupted prefix exit $rc"; exit 1; }
check "$TMP/r-bad.json" 'not r["ok"] and "frame.py" in r["failure"] and r["node_exit"] is None'
grep -q 'refused: .*sha256' "$TMP/log-bad" || { cat "$TMP/log-bad"; echo "FAIL: no sha256 refusal"; exit 1; }
pass=$((pass + 1))

# the summary: the two good results agree; adding the refused one fails it
python3 -I "$T/../summarize.py" "$TMP/r-checkpoints.json" "$TMP/r-full.json" > "$TMP/sum-ok" \
  || { cat "$TMP/sum-ok"; echo "FAIL: summary of good results"; exit 1; }
grep -q 'All results ok and consistent' "$TMP/sum-ok"
rc=0; python3 -I "$T/../summarize.py" "$TMP/r-full.json" "$TMP/r-refuse.json" > "$TMP/sum-bad" || rc=$?
if [ "$rc" != 1 ] || ! grep -q 'FAILED' "$TMP/sum-bad"; then
  cat "$TMP/sum-bad"; echo "FAIL: summary of a failed result"; exit 1
fi
pass=$((pass + 1))

# a work directory that is not empty: a usage error, nothing touched
mkdir -p "$TMP/w-busy" && touch "$TMP/w-busy/x"
rc=0
"$IMPORT" --bin "$T/mocknode" --prefix "$TMP/prefix" --mode full --work "$TMP/w-busy" --out "$TMP/r-busy.json" \
  > /dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && [ ! -e "$TMP/r-busy.json" ] || { echo "FAIL: non-empty work exit $rc"; exit 1; }
pass=$((pass + 1))

# Ycash mainnet history: real mainnet blocks 0..20 packed by harvest.py itself, imported under
# mainnet parameters (no -testnet, magic 24e92764), z_gettreestate compared with treestate.json
python3 -I - "$T/../.." "$TMP/mraw" "$TMP/mprefix" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import harvest as H
blocks = [bytes.fromhex(l.strip()) for l in open(os.path.join(sys.argv[1], "tests", "vectors", "ycash-mainnet-blocks-0-20.hex")) if l.strip()]
os.makedirs(sys.argv[2])
with open(os.path.join(sys.argv[2], H.chunk_name(0, 20, gz=False, net=H.MAINNET)), "wb") as f:
    f.write(b"".join(len(b).to_bytes(4, "little") + b for b in blocks))
ts = {"hash": H.display(H.parse_block(blocks[20])[0]), "height": 20, "time": H.block_time(blocks[20]),
      "sprout": {"commitments": {"finalRoot": "mock-sprout"}}, "sapling": {"commitments": {"finalRoot": "mock-sapling"}}}
H.pack(sys.argv[2], sys.argv[3], 20, log=lambda *a: None, net=H.MAINNET, treestate=ts)
PY
"$IMPORT" --bin "$T/mocknode" --prefix "$TMP/mprefix" --network ycash-mainnet --mode checkpoints --work "$TMP/w-main" \
  --out "$TMP/r-main.json" --line mock "${fast[@]}" > "$TMP/log-main" 2>&1 \
  || { cat "$TMP/log-main"; echo "FAIL: mainnet import"; exit 1; }
check "$TMP/r-main.json" 'r["ok"] and r["prefix"]["magic"] == "24e92764" and r["prefix"]["network"] == "ycash-mainnet"'
check "$TMP/r-main.json" 'r["prefix"]["tip_hash"] == "0001cdc223983ae6a2392cc0a92caeaea870bb587d0dd686374059ff25708013"'
check "$TMP/r-main.json" 'r["prefix"]["split"]["chaintx"] == 21 and "-testnet" not in r["node_args"]'
# hashes at 0, 20 (manifest) and the treestate comparison
check "$TMP/r-main.json" 'r["hash_checks"] == {"checked": 3, "mismatches": []}'
pass=$((pass + 1))

# the node computes a different tree state than the one published: refused
rc=0
MOCK_SAPLING_ROOT=other "$IMPORT" --bin "$T/mocknode" --prefix "$TMP/mprefix" --network ycash-mainnet --mode checkpoints \
  --work "$TMP/w-main-ts" --out "$TMP/r-main-ts.json" "${fast[@]}" > "$TMP/log-main-ts" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$TMP/log-main-ts"; echo "FAIL: treestate mismatch exit $rc"; exit 1; }
check "$TMP/r-main-ts.json" 'not r["ok"] and "treestate" in r["failure"]'
pass=$((pass + 1))

# a mainnet prefix offered as testnet history is refused before the node starts
rc=0
"$IMPORT" --bin "$T/mocknode" --prefix "$TMP/mprefix" --mode checkpoints --work "$TMP/w-main-wrong" \
  --out "$TMP/r-main-wrong.json" "${fast[@]}" > "$TMP/log-main-wrong" 2>&1 || rc=$?
[ "$rc" = 1 ] && grep -q "manifest network 'ycash-mainnet', expected 'zcash-testnet'" "$TMP/log-main-wrong" \
  || { cat "$TMP/log-main-wrong"; echo "FAIL: network mix-up exit $rc"; exit 1; }
pass=$((pass + 1))

echo "test_import.sh: $pass checks passed"
