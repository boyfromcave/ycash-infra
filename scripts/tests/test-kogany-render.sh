#!/usr/bin/env bash
# Render-only test of the lightwallet chart's kogany backend (nodeLine kogany, workspace kogany plan
# W9-c): values-kind.yaml + values-kind-kogany.yaml. lightwalletd-dd and yindex read the kogany node,
# the ycashd StatefulSet is its test rig (connect= kogany, no listen) and keeps the wallet (the miner,
# the arming Job and the faucet still reach ycashd), the arming Job rolls kogany, koganyd.toml carries
# ycashd's activation heights; with nodeLine ycash6 nothing kogany renders; the refusals hold; the
# storage mode is archive unless kogany.storageMode=pruned (and then only without lightwalletd-dd/yindex).
set -euo pipefail
cd "$(dirname "$0")/../.."
CHART=charts/ycash-lightwallet
kind=$(helm template t "$CHART" -f "$CHART/values-kind.yaml")
kog=$(helm template t "$CHART" -f "$CHART/values-kind.yaml" -f "$CHART/values-kind-kogany.yaml")
fail=0
has() { if grep -qF -- "$2" <<<"$1"; then echo "ok   $3"; else echo "FAIL $3 (missing: $2)"; fail=1; fi; }
hasnt() { if grep -qF -- "$2" <<<"$1"; then echo "FAIL $3 (present: $2)"; fail=1; else echo "ok   $3"; fi; }
has "$kog" '- { name: YCASHD_RPC_HOST, value: "t-kogany" }' 'kogany: lightwalletd-dd reads kogany'
has "$kog" '- { name: YCASHD_RPC_PORT, value: "18232" }' 'kogany: on kogany.rpc.port'
has "$kog" 'until nc -z t-kogany 18232' 'kogany: lightwalletd-dd waits for kogany'
if [ "$(grep -cF 'YINDEX_RPC_URL, value: "http://t-kogany:18232"' <<<"$kog")" = 2 ]; then
  echo "ok   kogany: yindex (serve and ingest) reads kogany"
else
  echo "FAIL kogany: yindex"; fail=1
fi
has "$kog" '- { name: YCASHD_CONF_EXTRA, value: "connect=t-kogany:18233\n" }' 'kogany: ycashd is the test rig, connect= kogany'
has "$kog" '- { name: YCASHD_LISTEN, value: "0" }' 'kogany: the rig does not listen'
has "$kog" 'rollout restart statefulset/t-kogany' 'kogany: the arming Job rolls kogany'
has "$kog" 'RPC_URL, value: "http://t-ycashd:18832/"' 'kogany: the wallet RPC (faucet, arming) stays on ycashd'
has "$kog" 'kind: StatefulSet' 'kogany: a StatefulSet'
has "$kog" 'image: ycash/koganyd:local' 'kogany: the koganyd image'
for nu in Overwinter Sapling Ycash Blossom Heartwood Canopy Vault; do
  has "$kog" "    $nu = 1" "kogany: koganyd.toml activation_heights.$nu = 1 (= ycashd -nuparams)"
done
has "$kog" 'p2p_stack = "legacy"' 'kogany: the legacy P2P stack only (K-11)'
hasnt "$kind" 't-kogany' 'ycash6: nothing kogany renders'
has "$kind" '- { name: YCASHD_RPC_HOST, value: "t-ycashd" }' 'ycash6: lightwalletd-dd reads ycashd'
if helm template t "$CHART" -f "$CHART/values-kind.yaml" --set nodeLine=kogany >/dev/null 2>&1; then echo "FAIL refusal: kogany without activation heights"; fail=1; else echo "ok   refusal: kogany without activation heights"; fi
if helm template t "$CHART" -f "$CHART/values-eks.yaml" -f "$CHART/values-kind-kogany.yaml" >/dev/null 2>&1; then echo "FAIL refusal: kogany off regtest"; fail=1; else echo "ok   refusal: kogany off regtest (K-19)"; fi
if helm template t "$CHART" -f "$CHART/values-kind.yaml" --set nodeLine=zcashd >/dev/null 2>&1; then echo "FAIL refusal: an unknown node line"; fail=1; else echo "ok   refusal: an unknown node line"; fi
# Storage mode (workspace pruning assessment KP-4, decisions 7 and 8): archive by default; pruned renders
# Zakura's [state.storage_mode.pruned] with the retention, only without lightwalletd-dd and yindex.
hasnt "$kog" 'storage_mode' 'kogany: archive by default (no storage_mode table)'
KOG=(-f "$CHART/values-kind.yaml" -f "$CHART/values-kind-kogany.yaml")
NOCLIENTS=(--set lightwalletd.replicas=0 --set yindex.enabled=false)
pruned=$(helm template t "$CHART" "${KOG[@]}" "${NOCLIENTS[@]}" --set kogany.storageMode=pruned)
has "$pruned" '[state.storage_mode.pruned]' 'kogany pruned: the storage_mode table'
has "$pruned" 'tx_retention = 34560' 'kogany pruned: the infrastructure retention 34,560 by default'
if helm template t "$CHART" "${KOG[@]}" --set kogany.storageMode=pruned >/dev/null 2>&1; then echo "FAIL refusal: pruned behind lightwalletd-dd"; fail=1; else echo "ok   refusal: pruned behind lightwalletd-dd and yindex (decision 7)"; fi
if helm template t "$CHART" "${KOG[@]}" "${NOCLIENTS[@]}" --set kogany.storageMode=pruned --set kogany.retention=1000 >/dev/null 2>&1; then echo "FAIL refusal: a retention below the floor"; fail=1; else echo "ok   refusal: a retention below Zakura's regtest floor 1,001"; fi
if helm template t "$CHART" "${KOG[@]}" --set kogany.storageMode=thin >/dev/null 2>&1; then echo "FAIL refusal: an unknown storage mode"; fail=1; else echo "ok   refusal: an unknown storage mode"; fi
exit $fail
