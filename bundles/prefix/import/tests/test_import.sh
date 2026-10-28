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
[ "$rc" = 1 ] && grep -q 'FAILED' "$TMP/sum-bad" || { cat "$TMP/sum-bad"; echo "FAIL: summary of a failed result"; exit 1; }
pass=$((pass + 1))

# a work directory that is not empty: a usage error, nothing touched
mkdir -p "$TMP/w-busy" && touch "$TMP/w-busy/x"
rc=0
"$IMPORT" --bin "$T/mocknode" --prefix "$TMP/prefix" --mode full --work "$TMP/w-busy" --out "$TMP/r-busy.json" \
  > /dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && [ ! -e "$TMP/r-busy.json" ] || { echo "FAIL: non-empty work exit $rc"; exit 1; }
pass=$((pass + 1))

echo "test_import.sh: $pass checks passed"
