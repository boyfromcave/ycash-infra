#!/bin/bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file LICENSE or https://www.opensource.org/licenses/mit-license.php .
# shellcheck disable=SC2046,SC2015  # docker ps ids are whole words; `a && b || fail`: fail exits
#
# The local rehearsal of one attestor host (README.md, "The attestors": "Local rehearsal"; workspace
# docs/plans/beta4/price-feed.md item 3c): real containers, a regtest chain, seedctl as the deploy
# workflow runs it, three seats on one host. Not part of make seeds-validate (it needs Docker and the
# images); run it by hand:
#
#   infra/testnet-seeds/nodes/tests/attestors-regtest.sh
#     YCASHD_IMAGE   a ycashd image with the vault upgrade (default: the published 6.22.0-beta3 one)
#     ATTEST_IMAGE   the attest image, built from images/attest/Dockerfile (default ycash/attest:local)
#     RUN_DIR        a directory Docker can bind-mount, outside any git tree (default: a fresh one in $HOME)
#     KEEP=1         leave the containers and RUN_DIR behind for a look
#
# What it does and checks:
#   1. a "ceremony" node (plain docker run, regtest, Vault at 200) mines, creates the attestor set
#      (the module's adoption parameters, maturity 8), joins three seats with fresh keys and writes
#      their key files in the ceremony's format (<network>-seat-N.json), as contrib/testnet/ceremony does
#   2. the host: seedctl (in a helper container with the Docker socket, its root at RUN_DIR/host, as
#      on an instance) applies a config with `attestors` (three seats, node backend, the regtest knobs:
#      the dir transport and a mock price); its node syncs from the ceremony node; the agents start
#      and cannot sign (no key yet)
#   3. attest-import of the three key files (each deleted once imported); the agents sign every 2
#      blocks; the subscribe agents put every statement into both nodes' pools
#   4. status and attest-health: three seats live, their last statements young
#   5. one agent stopped: attest-health fails and names it; started again: passes
#   6. reset: the chain goes, the seat keys and the guard file stay; the seats sign again
#   7. A-6: attest-export; the host's whole data directory deleted (a lost instance and volume); a
#      fresh apply; attest-import of the bundle (guard first, then the keys); the restored node refuses
#      to sign an already signed citedHeight at another price (equivocation-guard) and returns the
#      recorded signature for the same price
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
FILES="$here/../files"
YCASHD_IMAGE=${YCASHD_IMAGE:-ghcr.io/boyfromcave/ycashd@sha256:70c0a29f83b6d8024c89de1f85f84a3cf5220e8a2915f38ea6f56fc045cad340}
ATTEST_IMAGE=${ATTEST_IMAGE:-ycash/attest:local}
RUN_DIR=${RUN_DIR:-$(mktemp -d "$HOME/attest-regtest.XXXXXX")}
RUN_DIR=$(cd "$RUN_DIR" && pwd)
NET=yb-reg
VAULT=200
CER_RPC=29442 CER_P2P=29443 HOST_RPC=29432 HOST_P2P=29433 REG_PORT=29500
H="$RUN_DIR/host"; D="$H/srv/ycash-data"; O="$H/opt/ycash-seed"
CER=attest-rehearsal-ceremony REG=attest-rehearsal-registry HELPER=attest-rehearsal-helper
NUP="-nuparams=5ba81b19:1 -nuparams=76b809bb:1 -nuparams=374d694f:1 -nuparams=8e471bd6:1 -nuparams=66314da3:1 -nuparams=19bd2d2f:1 -nuparams=6d5b7a31:$VAULT"
say() { echo "== $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }
cleanup() {
  [ "${KEEP:-}" = 1 ] && { echo "KEEP=1: containers and $RUN_DIR left in place"; return 0; }
  docker exec "$HELPER" /h/seedctl stop "$NET" >/dev/null 2>&1 || true
  docker rm -f "$CER" "$REG" "$HELPER" attest-rehearsal-cersub "ycashd-$NET" "attsub-$NET" \
    $(docker ps -aq --filter "name=^attest-[0-9]+-$NET\$") >/dev/null 2>&1 || true
  docker run --rm -v "$RUN_DIR:/r" --entrypoint sh debian:bookworm-slim -c 'rm -rf /r/* /r/.[!.]*' >/dev/null 2>&1 || true
  rmdir "$RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT

ccli() { docker exec "$CER" ycash-cli -datadir=/var/lib/ycash -conf=/var/lib/ycash/ycash.conf "$@"; }
sctl() { docker exec "$HELPER" env SEEDCTL_ROOT="$H" /h/seedctl "$@"; }
hcli() { docker exec "ycashd-$NET" ycash-cli -datadir=/var/lib/ycash -conf=/var/lib/ycash/ycash.conf -regtest "$@"; }
mine() { ccli generate "$1" >/dev/null; }
wait_for() { # seconds description command...
  local n=$1 what=$2 i=0; shift 2
  until "$@" >/dev/null 2>&1; do i=$((i + 2)); [ "$i" -lt "$n" ] || fail "timed out waiting for $what"; sleep 2; done
}
synced() { [ "$(hcli getblockcount 2>/dev/null)" = "$(ccli getblockcount)" ]; }

mkdir -p "$RUN_DIR/ceremony" "$RUN_DIR/secrets" "$RUN_DIR/bus" "$D" "$O"
chmod 0700 "$RUN_DIR/secrets"; chmod 0777 "$RUN_DIR/bus"

# ---- images: the attest image through a local registry (seedctl wants every image by digest and pulls it)
say "registry and images"
docker run -d --name "$REG" -p "127.0.0.1:$REG_PORT:5000" registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373 >/dev/null
sleep 2
docker tag "$ATTEST_IMAGE" "localhost:$REG_PORT/ycash-attest:rehearsal"
AIMG=$(docker push "localhost:$REG_PORT/ycash-attest:rehearsal" | sed -n 's/.*digest: \(sha256:[0-9a-f]\{64\}\).*/\1/p')
[ -n "$AIMG" ] || fail "could not push the attest image"
AIMG="localhost:$REG_PORT/ycash-attest@$AIMG"
docker pull -q "$YCASHD_IMAGE" >/dev/null
# the helper: seedctl's tools (bash, jq, flock, openssl, the Docker CLI and compose); iptables is a
# no-op there (the metadata rule is for an instance, and this must not touch the Docker VM's firewall)
docker build -q -t attest-rehearsal-helper:local - >/dev/null <<'EOF'
FROM docker@sha256:851f91d241214e7c6db86513b270d58776379aacc5eb9c4a87e5b47115e3065c
RUN apk add --no-cache bash jq util-linux openssl coreutils \
 && printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/iptables && cp /usr/local/bin/iptables /usr/local/bin/ip6tables \
 && chmod 0755 /usr/local/bin/iptables /usr/local/bin/ip6tables
EOF

# ---- 1. the ceremony node: the set, three seats, their key files
say "1. ceremony: chain, attestor set, three seats"
start_ceremony() { # [setid]
  # a clean stop first: a killed regtest node loses the blocks it has not flushed
  docker stop -t 120 "$CER" >/dev/null 2>&1 || true
  docker rm -f "$CER" >/dev/null 2>&1 || true
  docker run -d --name "$CER" --network host -v "$RUN_DIR/ceremony:/var/lib/ycash" \
    -e YCASHD_NETWORK=regtest -e YCASHD_VAULT_HEIGHT=$VAULT -e YCASHD_INSIGHT=0 -e YCASHD_RPC_PORT=$CER_RPC \
    -e YCASHD_RPC_USER=rehearsal -e YCASHD_RPC_PASSWORD=rehearsal -e YCASHD_RPC_BIND=127.0.0.1 \
    -e YCASHD_YELLOWBACK_ATTESTOR_SET="${1:-}" -e "YCASHD_CONF_EXTRA=port=$CER_P2P" "$YCASHD_IMAGE" >/dev/null
  wait_for 300 "the ceremony node's RPC" ccli getblockcount
}
start_ceremony
mine $((VAULT + 10))
SETID=$(ccli set_create '{"seats":15,"unlockthreshold":1,"cancelthreshold":1,"slashthreshold":1,"open":true,"ratelimitbps":0,"livenesswindow":1000,"maturity":8,"bondmin":10,"bondlockmin":0}' | jq -r .setid)
[[ "$SETID" =~ ^[0-9a-f]{64}$ ]] || fail "set_create: $SETID"
mine 1
start_ceremony "$SETID"
ccli yed_getinfo >/dev/null || fail "Yellowback is not live on the ceremony node with the set"
for n in 1 2 3; do
  a=$(ccli getnewaddress); k=$(ccli validateaddress "$a" | jq -r .pubkey)
  j=$(ccli set_join "$SETID" 10 $(( $(ccli getblockcount) + 1 )) "$k")
  ( umask 077; jq -n --arg s "$SETID" --argjson n "$n" --arg k "$k" --arg a "$a" --arg w "$(ccli dumpprivkey "$a")" --arg b "$(jq -r '.bondoutpoint // ""' <<<"$j")" \
      '{network: "regtest", setid: $s, seat: $n, memberkey: $k, address: $a, wif: $w, bondoutpoint: $b}' > "$RUN_DIR/secrets/regtest-seat-$n.json" )
  mine 1
done
mine 12
SEATS=$(ccli yed_listattestors | jq -c '[.[] | {seq, memberkey: .attestorPubKey}]')
[ "$(jq length <<<"$SEATS")" = 3 ] || fail "the set lists $(jq length <<<"$SEATS") attestors, not 3"
ok "ceremony: set $SETID created, three seats joined (seqs $(jq -r '[.[].seq] | join(",")' <<<"$SEATS")), key files written"

# ---- 2. the host: seedctl applies the attestors config
say "2. the attestor host: seedctl apply"
printf 'SEED_NAME=rehearsal-a\nVOLUME_ID=vol-rehearsal\nEXTERNAL_IP=127.0.0.1\nSWAP_MB=0\n' > "$O/seed.env"
mkdir -p "$RUN_DIR/h"; cp "$FILES/seedctl" "$FILES/seedctl-attest" "$RUN_DIR/h/"; cp "$FILES/seedctl-attest" "$O/"
docker run -d --name "$HELPER" --network host -v /var/run/docker.sock:/var/run/docker.sock -v "$RUN_DIR:$RUN_DIR" \
  -v "$RUN_DIR/h:/h:ro" --entrypoint sleep attest-rehearsal-helper:local infinity >/dev/null
CONFIG=$(jq -cn --arg img "$YCASHD_IMAGE" --arg aimg "$AIMG" --argjson seats "$SEATS" --arg bus "$RUN_DIR/bus" \
  --arg x "$NUP -pqfalconheight=0 -yellowbackattestorset=$SETID -addnode=127.0.0.1:$CER_P2P -listen=0" --argjson rpc $HOST_RPC --argjson p2p $HOST_P2P '{
  name: "yb-reg", profile: "fast", network: "mainnet", image: $img, p2p_port: $p2p, rpc_port: $rpc,
  node_args: "-regtest", dnsseed: false, extra_args: $x, peers: [], prefix: null, pool: null,
  attestors: {image: $aimg, backend: "node", lightwalletd: [], seats: $seats, every_blocks: 2, heartbeat_blocks: 0,
    peers: [], relays: [], cancel: false, subscribe: true, mem_limit_mb: 128, bus: $bus, mock_price: "0.50"}}' | base64 | tr -d '\n')
sctl apply "$NET" "$CONFIG" || fail "seedctl apply"
wait_for 300 "the host's node to sync from the ceremony node" synced
s=$(sctl status "$NET" | jq -c .attestors)
[ "$(jq -r '[.mine[] | .container] | unique | join(",")' <<<"$s")" = running ] && [ "$(jq -r '[.mine[] | .keyHeld] | any' <<<"$s")" = false ] || fail "before the import: $s"
ok "the host: node synced, three agents and a subscribe agent running, no seat key held yet"

# ---- 3. the keys
say "3. attest-import of the three key files"
mkdir -p "$D/import"; cp "$RUN_DIR"/secrets/regtest-seat-*.json "$D/import/"
for f in "$D"/import/regtest-seat-*.json; do sctl attest-import "$NET" "$f" || fail "attest-import $f"; done
[ -z "$(ls "$D/import")" ] || fail "an imported key file was left on the host"
# a subscribe agent beside the ceremony node too (the network's other nodes hear the host's seats)
( umask 077; printf '[node]\nrpc_url = "http://127.0.0.1:%s"\nrpc_user = "rehearsal"\nrpc_password = "rehearsal"\n\n[transport]\nkind = "dir"\npath = "/bus"\n' $CER_RPC > "$RUN_DIR/cersub.toml" )
docker run -d --name attest-rehearsal-cersub --network host --user 0 -v "$RUN_DIR/cersub.toml:/etc/yellowback-attest/host.toml:ro" -v "$RUN_DIR/bus:/bus" "$AIMG" subscribe >/dev/null
for _ in $(seq 1 12); do mine 1; sleep 3; done
ok "three seat keys imported, every file deleted; 12 blocks mined"

# ---- 4. status and health
say "4. status and attest-health"
s=$(sctl status "$NET" | jq -c .attestors)
echo "$s" | jq '{yellowback, height, attestStatus, mine}'
[ "$(jq -r '[.mine[] | .keyHeld] | all' <<<"$s")" = true ] || fail "keys: $s"
sctl attest-health "$NET" >/dev/null 2>"$RUN_DIR/health.err" || fail "attest-health with three live seats: $(cat "$RUN_DIR/health.err")"
[ "$(ccli yed_getattestations | jq '[.[].seq] | unique | length')" = 3 ] || fail "the ceremony node's pool does not hold all three seats"
ok "three seats live (keys held, statements at most 2 x every_blocks + ref_lag old) on the host; the ceremony node's pool holds all three"

# ---- 5. one agent down
say "5. one agent stopped"
SEQ1=$(jq -r '.[0].seq' <<<"$SEATS")
docker stop "attest-$SEQ1-$NET" >/dev/null
for _ in $(seq 1 8); do mine 1; sleep 1; done
if sctl attest-health "$NET" >/dev/null 2>"$RUN_DIR/health.err"; then fail "attest-health passed with seat $SEQ1's agent stopped"; fi
grep -q "seat $SEQ1: agent exited" "$RUN_DIR/health.err" || fail "health: $(cat "$RUN_DIR/health.err")"
docker start "attest-$SEQ1-$NET" >/dev/null
for _ in $(seq 1 6); do mine 1; sleep 3; done
sctl attest-health "$NET" >/dev/null 2>"$RUN_DIR/health.err" || fail "attest-health after the agent came back: $(cat "$RUN_DIR/health.err")"
ok "an agent down: attest-health fails and names the seat; back up: passes"

# ---- 6. reset
say "6. reset"
sctl reset "$NET" "$CONFIG" || fail "seedctl reset"
wait_for 300 "the host to resync" synced
for _ in $(seq 1 6); do mine 1; sleep 3; done
s=$(sctl status "$NET" | jq -c .attestors)
[ "$(jq -r '[.mine[] | .keyHeld] | all' <<<"$s")" = true ] || fail "keys after the reset: $s"
sctl attest-health "$NET" >/dev/null 2>"$RUN_DIR/health.err" || fail "attest-health after the reset: $(cat "$RUN_DIR/health.err")"
ok "reset: the chain resynced; the seat keys and the guard stayed; the seats sign again"

# ---- 7. A-6: a lost host restored from its export refuses to re-sign at another price
say "7. export, the host lost, restored from the bundle"
SEQ2=$(jq -r '.[1].seq' <<<"$SEATS")
SIGNED=$(hcli yed_getattestations | jq -c --argjson s "$SEQ2" '[.[] | select(.seq == $s)] | max_by(.citedHeight)')
[ "$SIGNED" != null ] || fail "no statement of seat $SEQ2 in the host's pool"
EXP=$(sctl attest-export "$NET" | tail -n 1 | jq -r .path)
cp "$EXP" "$RUN_DIR/secrets/bundle.json"
sctl stop "$NET" >/dev/null
docker rm -f "ycashd-$NET" "attsub-$NET" $(docker ps -aq --filter "name=^attest-[0-9]+-$NET\$") >/dev/null 2>&1 || true
docker run --rm -v "$D:/d" --entrypoint sh debian:bookworm-slim -c "rm -rf /d/$NET"
sctl apply "$NET" "$CONFIG" || fail "apply on the empty host"
wait_for 300 "the new host to sync" synced
wait_for 120 "Yellowback live on the new host" hcli yed_getinfo
cp "$RUN_DIR/secrets/bundle.json" "$D/bundle.json"
sctl attest-import "$NET" "$D/bundle.json" || fail "attest-import of the bundle"
wait_for 300 "the restored node's RPC" hcli getblockcount
CH=$(jq -r .citedHeight <<<"$SIGNED"); PR=$(jq -r .priceMicroUsd <<<"$SIGNED")
if out=$(hcli yed_signattestation "$SEQ2" $((PR + 1000)) "$CH" 2>&1); then fail "the restored host re-signed $CH at another price: $out"; fi
grep -q equivocation-guard <<<"$out" || fail "re-sign at another price: $out"
[ "$(hcli yed_signattestation "$SEQ2" "$PR" "$CH" | jq -r .reused)" = true ] || fail "the same price did not return the recorded signature"
ok "A-6: the restored host refuses seat $SEQ2's citedHeight $CH at another price (equivocation-guard) and returns the recorded signature for the same price"
# the agents restart with the node (the guard import): give them a few blocks to sign again
for i in $(seq 1 12); do
  mine 1; sleep 3
  [ "$i" -lt 6 ] && continue
  if sctl attest-health "$NET" >/dev/null 2>"$RUN_DIR/health.err"; then break; fi
  [ "$i" -lt 12 ] || fail "attest-health on the restored host: $(cat "$RUN_DIR/health.err")"
done
sctl status "$NET" | jq '.attestors | {yellowback, height, attestStatus, walletZat, subscribe, mine, others}' > "$RUN_DIR/status.json"
cat "$RUN_DIR/status.json"
echo "attestors-regtest: all checks passed"
