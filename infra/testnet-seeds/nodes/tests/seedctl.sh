#!/bin/bash
# shellcheck disable=SC2015  # `a && b || fail`: fail exits, so it is the if-then-else it reads as
# Offline test of files/seedctl: a scratch root (SEEDCTL_ROOT), a fake `docker` on PATH that logs
# what it is asked, and stand-ins for the prefix tools. Checks the per-network lifecycle on one
# host: apply (with the prefix bootstrap and the shared cache), the rendered node arguments and
# ports, prefix-check, status, reset of one network leaving the other alone, sync stopping a
# network no longer configured, boot re-rendering from the applied configs, and the refusals.
# Run: infra/testnet-seeds/nodes/tests/seedctl.sh   (make seeds-validate runs it)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
SEEDCTL="$here/../files/seedctl"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export SEEDCTL_ROOT="$T/root" LOG="$T/log" FAKE_HEIGHT=600000
O="$SEEDCTL_ROOT/opt/ycash-seed"
D="$SEEDCTL_ROOT/srv/ycash-data"
mkdir -p "$O" "$D" "$T/bin"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

printf 'SEED_NAME=seed-0\nVOLUME_ID=vol-0\nEXTERNAL_IP=192.0.2.10\nSWAP_MB=0\n' > "$O/seed.env"
cat > "$O/prefix-restore.sh" <<'EOF'
echo "restore $DATADIR $PREFIX_SUMS_SHA256 $PREFIX_LAST_HEIGHT $PREFIX_NETWORK" >> "$LOG"
mkdir -p "$DATADIR/prefix" && touch "$DATADIR/prefix/VERIFIED"
EOF
cat > "$O/frame.py" <<'EOF'
import os, sys
a = sys.argv[1:]
out = a[a.index("--out") + 1]
os.makedirs(out, exist_ok=True)
open(os.path.join(out, "blk0.dat"), "w").close()
open(os.environ["LOG"], "a").write("frame %s %s %s\n" % (a[a.index("--prefix") + 1], a[a.index("--network") + 1], a[a.index("--magic") + 1]))
EOF
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$LOG"
case "$1" in
  compose) f=$3; shift 3
    case "$1" in
      up) echo "up $(sed -n 's/^name: //p' "$f")" >> "$LOG" ;;
      down) echo "down $(sed -n 's/^name: //p' "$f")" >> "$LOG" ;;
    esac ;;
  exec)
    case "${!#}" in
      getblockcount) echo "$FAKE_HEIGHT" ;;
      getblockchaininfo) echo '{"chain":"test","blocks":1,"headers":1,"verificationprogress":1}' ;;
      getpeerinfo) echo '[{"inbound":true},{"inbound":false}]' ;;
    esac ;;
  inspect) case "$3" in *Status*) echo running ;; *) echo img ;; esac ;;
esac
exit 0
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$LOG"
case "$*" in
  *127.0.0.1:3334/status*) echo '{"nodeUp":true,"height":510432,"templateAgeSeconds":0,"miners":2,"connections":2,"accepted":1,"rejected":0,"lastSubmitVerdict":"accepted","payout":"smc9M6Kk4dt6ExX1dUKNYcwTxtPpyC4Jo13","equihash":"192,7","shares":9}' ;;
  *) exit 7 ;;
esac
EOF
chmod +x "$T/bin/docker" "$T/bin/curl"
export PATH="$T/bin:$PATH"

# A config as the module's network_configs output carries it (locals.tf network_config).
conf() { # name profile p2p rpc magic [image-hex]; slow and legacy restore mainnet-prefix-v1, fast testnet-prefix-v1
  local pn=zcash-testnet ps=c7b55a2a6770df8108d910572cca2dbf643a0418eb0b2d556879928a43cbc403 pl=510247
  case "$2" in slow|legacy) pn=ycash-mainnet ps=456e820511ade7d9ffd8db41b168ee6063050bb05e2af6a651072bbfb74eecd3 pl=3079999 ;; esac
  jq -cn --arg n "$1" --arg p "$2" --argjson p2p "$3" --argjson rpc "$4" --arg m "$5" --arg h "${6:-0000000000000000000000000000000000000000000000000000000000000000}" \
    --arg pn "$pn" --arg ps "$ps" --argjson pl "$pl" '{
    name: $n, profile: $p, network: "testnet", image: ("ghcr.io/example/ycashd@sha256:" + $h),
    p2p_port: $p2p, rpc_port: $rpc, node_args: ("-testnet -testnetprofile=" + $p), dnsseed: false,
    extra_args: "-dbcache=256 -maxconnections=64",
    peers: [("192.0.2.10:" + ($p2p | tostring)), ("192.0.2.11:" + ($p2p | tostring))],
    prefix: {base_url: "https://example.org/prefix", sums_sha256: $ps, last_height: $pl, network: $pn, magic: $m}}'
}
b64() { base64 -w0; }
FAST=$(conf yb-fast fast 18833 18832 f77962d3 | b64)
SLOW=$(conf yb-slow slow 18933 18932 f77962d4 | b64)

# 1. apply fast: the prefix is fetched once into the cache, framed with fast's magic, imported
"$SEEDCTL" apply yb-fast "$FAST" 2>/dev/null
env_fast="$O/net/yb-fast/node.env"
grep -qx 'YCASHD_EXTRA_ARGS=-port=18833 -externalip=192.0.2.10 -testnet -testnetprofile=fast -dnsseed=0 -addnode=192.0.2.11:18833 -dbcache=256 -maxconnections=64 -loadblock=/var/lib/ycash/prefix/load/blk0.dat' "$env_fast" \
  || fail "fast's node arguments: $(grep EXTRA "$env_fast")"
grep -qx 'YCASHD_RPC_PORT=18832' "$env_fast" && grep -qx 'YCASHD_NETWORK=testnet' "$env_fast" && grep -qx 'YCASHD_TESTNET_PROFILE=fast' "$env_fast" && grep -qx 'YCASHD_RPC_BIND=127.0.0.1' "$env_fast" || fail "fast's RPC settings"
grep -q 'container_name: ycashd-yb-fast' "$O/net/yb-fast/compose.yaml" && grep -q 'image: ghcr.io/example/ycashd@sha256:0000' "$O/net/yb-fast/compose.yaml" || fail "fast's compose file"
grep -q "\"$D/yb-fast/node:/var/lib/ycash\"" "$O/net/yb-fast/compose.yaml" || fail "fast's own datadir"
[ "$(grep -c '^restore ' "$LOG")" = 1 ] && grep -q "^restore $D/prefix-cache/zcash-testnet/data c7b55a2a6770df8108d910572cca2dbf643a0418eb0b2d556879928a43cbc403 510247 zcash-testnet$" "$LOG" && grep -q "^frame $D/prefix-cache/zcash-testnet/data/prefix zcash-testnet f77962d3$" "$LOG" || fail "one fetch of testnet-prefix-v1, framed with d3"
[ -s "$D/yb-fast/applied.json" ] && [ "$(stat -c %a "$D/yb-fast/rpc.env")" = 600 ] || fail "applied config and a private rpc.env"
ok "apply fast: prefix fetched and framed, ports, profile, peers without itself"

# 2. apply slow: the cache is reused, framed with slow's magic, its own ports and datadir
"$SEEDCTL" apply yb-slow "$SLOW" 2>/dev/null
grep -q "^restore $D/prefix-cache/ycash-mainnet/data 456e820511ade7d9ffd8db41b168ee6063050bb05e2af6a651072bbfb74eecd3 3079999 ycash-mainnet$" "$LOG" || fail "slow fetched mainnet-prefix-v1 as ycash-mainnet"
grep -q "^frame $D/prefix-cache/ycash-mainnet/data/prefix ycash-mainnet f77962d4$" "$LOG" || fail "slow framed ycash-mainnet with d4"
[ -e "$D/prefix-cache/zcash-testnet/data/prefix/VERIFIED" ] || fail "slow's fetch evicted fast's cache"
grep -q -- '-port=18933 .*-testnetprofile=slow .*-addnode=192.0.2.11:18933' "$O/net/yb-slow/node.env" && grep -qx 'YCASHD_RPC_PORT=18932' "$O/net/yb-slow/node.env" || fail "slow's ports"
ok "apply slow: its own prefix (ycash-mainnet) in its own cache, its own magic and ports"

# 3. prefix-check: at the prefix's last height the -loadblock flags and framed copies go
"$SEEDCTL" prefix-check 2>/dev/null
[ -e "$D/yb-fast/node/prefix/IMPORTED" ] && [ ! -e "$D/yb-fast/node/prefix/load" ] || fail "fast imported"
! grep -q loadblock "$env_fast" || fail "-loadblock retired"
ok "prefix-check retires -loadblock once imported"

# 4. status: one JSON line per network
s=$("$SEEDCTL" status)
[ "$(echo "$s" | jq -r .network | sort | tr '\n' ' ')" = "yb-fast yb-slow " ] && [ "$(echo "$s" | jq -r 'select(.network=="yb-fast") | .inbound')" = 1 ] || fail "status: $s"
ok "status reports each network"

# 5. reset fast: its chain goes, slow is untouched, nothing is downloaded again
touch "$D/yb-fast/node/chainstate-marker" "$D/yb-slow/node/chainstate-marker"
: > "$LOG"
"$SEEDCTL" reset yb-fast "$FAST" 2>/dev/null
[ ! -e "$D/yb-fast/node/chainstate-marker" ] && [ -e "$D/yb-slow/node/chainstate-marker" ] || fail "reset touched the wrong datadir"
! grep -q '^restore ' "$LOG" && grep -q '^frame .* f77962d3$' "$LOG" || fail "reset re-frames from the cache"
! grep -q 'ycash-yb-slow' "$LOG" || fail "reset of fast touched slow's container"
ok "reset fast: its chain only, re-bootstrapped from the cache"

# 6. upgrade fast (a new image): only fast's container is recreated
FAST2=$(conf yb-fast fast 18833 18832 f77962d3 1111111111111111111111111111111111111111111111111111111111111111 | b64)
: > "$LOG"
"$SEEDCTL" apply yb-fast "$FAST2" 2>/dev/null
grep -q 'image: ghcr.io/example/ycashd@sha256:1111' "$O/net/yb-fast/compose.yaml" && grep -q '^up ycash-yb-fast$' "$LOG" && ! grep -q 'ycash-yb-slow' "$LOG" || fail "upgrade of fast"
ok "upgrade fast: new image, slow untouched"

# 7. sync with fast only: slow is stopped, its data kept
ALL=$(jq -cn --argjson f "$(echo "$FAST2" | base64 -d)" '{"yb-fast": $f}' | b64)
: > "$LOG"
"$SEEDCTL" sync "$ALL" 2>"$T/err" || { cat "$T/err"; fail sync; }
grep -q '^down ycash-yb-slow$' "$LOG" && [ -e "$D/yb-slow/node/chainstate-marker" ] || fail "sync stops a removed network and keeps its data"
ok "sync stops a network no longer configured, data kept"

# 8. boot (a new instance on an old volume): re-render from the applied configs
rm -rf "$O/net"
"$SEEDCTL" boot 2>/dev/null
[ -e "$O/net/yb-fast/compose.yaml" ] || fail "boot re-renders"
ok "boot restarts the applied networks"

# 9. refusals: an image by tag, a config for another network, a bad network name
BAD=$(conf yb-fast fast 18833 18832 f77962d3 | jq -c '.image = "ghcr.io/example/ycashd:latest"' | b64)
if "$SEEDCTL" apply yb-fast "$BAD" 2>/dev/null; then fail "accepted an image by tag"; fi
if "$SEEDCTL" apply yb-slow "$FAST" 2>/dev/null; then fail "accepted another network's config"; fi
if "$SEEDCTL" stop '../x' 2>/dev/null; then fail "accepted a bad network name"; fi
INJ=$(conf yb-fast fast 18833 18832 f77962d3 | jq -c '.extra_args = "-x\nYCASHD_RPC_BIND=0.0.0.0"' | b64)
if "$SEEDCTL" apply yb-fast "$INJ" 2>/dev/null; then fail "accepted a newline in extra_args"; fi
ok "refuses a tag, a foreign config, a bad name, an injected line"
# 10. a pool beside fast (the pool host): yolo in the same compose project, the node's credential in
#     a private pool.conf (never on a command line), status with a pool field; removing the pool removes it
POOLED=$(conf yb-fast fast 18833 18832 f77962d3 | jq -c '.pool = {image: "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout: "smc9M6Kk4dt6ExX1dUKNYcwTxtPpyC4Jo13", port: 3333, status_port: 3334, text: "testnet pool", share_ratio: 32}' | b64)
: > "$LOG"
"$SEEDCTL" apply yb-fast "$POOLED" 2>"$T/err" || { cat "$T/err"; fail "apply with a pool"; }
c="$O/net/yb-fast/compose.yaml"
grep -q 'container_name: yolo-yb-fast' "$c" && grep -q 'image: ghcr.io/example/yolo@sha256:2222' "$c" && grep -q 'depends_on: \[ycashd\]' "$c" || fail "the yolo service: $(cat "$c")"
grep -qF 'command: ["--conf", "/etc/yolo/pool.conf", "--payout", "smc9M6Kk4dt6ExX1dUKNYcwTxtPpyC4Jo13", "--bind", "0.0.0.0", "--port", "3333", "--status-port", "3334", "--log", "info", "--share-ratio", "32", "--text", "testnet pool"]' "$c" || fail "yolo's command line: $(grep command "$c")"
grep -q 'read_only: true' "$c" && grep -q 'cap_drop: \[ALL\]' "$c" && grep -qF "\"$D/yb-fast/pool.conf:/etc/yolo/pool.conf:ro\"" "$c" || fail "yolo is read-only, no capabilities, the conf mounted read-only"
pw=$(sed -n 's/^YCASHD_RPC_PASSWORD=//p' "$D/yb-fast/rpc.env")
grep -qx "rpcpassword=$pw" "$D/yb-fast/pool.conf" && grep -qx 'rpcport=18832' "$D/yb-fast/pool.conf" && grep -qx 'rpcconnect=127.0.0.1' "$D/yb-fast/pool.conf" && [ "$(stat -c %a "$D/yb-fast/pool.conf")" = 400 ] || fail "pool.conf: the node's credential, its RPC port on loopback, mode 0400"
! grep -q "$pw" "$c" || fail "the RPC password is on yolo's command line"
grep -q '127.0.0.1:3334/status' "$LOG" || fail "apply waits for the pool's status page"
s=$("$SEEDCTL" status yb-fast)
[ "$(echo "$s" | jq -r '.pool.accepted')" = 1 ] && [ "$(echo "$s" | jq -r '.pool.container')" = running ] && [ "$(echo "$s" | jq -r '.pool.payout')" = smc9M6Kk4dt6ExX1dUKNYcwTxtPpyC4Jo13 ] || fail "status with a pool: $s"
ok "a pool beside fast: compose service, private pool.conf, status page waited for and reported"
: > "$LOG"
"$SEEDCTL" apply yb-fast "$FAST2" 2>/dev/null
! grep -q yolo "$O/net/yb-fast/compose.yaml" && grep -q 'docker rm -f yolo-yb-fast' "$LOG" && [ "$("$SEEDCTL" status yb-fast | jq -r 'has("pool")')" = false ] || fail "a pool removed from the config"
ok "a pool removed from the config is removed from the host"
BADPOOL=$(echo "$POOLED" | base64 -d | jq -c '.pool.payout = "x;reboot"' | b64)
if "$SEEDCTL" apply yb-fast "$BADPOOL" 2>/dev/null; then fail "accepted a shell character in the payout"; fi
BADPOOL=$(echo "$POOLED" | base64 -d | jq -c '.pool.image = "ghcr.io/example/yolo:latest"' | b64)
if "$SEEDCTL" apply yb-fast "$BADPOOL" 2>/dev/null; then fail "accepted a pool image by tag"; fi
ok "refuses a pool image by tag and a bad payout"
echo "seedctl: all checks passed"
