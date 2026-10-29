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
echo "restore $DATADIR $PREFIX_SUMS_SHA256 $PREFIX_LAST_HEIGHT" >> "$LOG"
mkdir -p "$DATADIR/prefix" && touch "$DATADIR/prefix/VERIFIED"
EOF
cat > "$O/frame.py" <<'EOF'
import os, sys
a = sys.argv[1:]
out = a[a.index("--out") + 1]
os.makedirs(out, exist_ok=True)
open(os.path.join(out, "blk0.dat"), "w").close()
open(os.environ["LOG"], "a").write("frame %s %s\n" % (a[a.index("--prefix") + 1], a[a.index("--magic") + 1]))
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
chmod +x "$T/bin/docker"
export PATH="$T/bin:$PATH"

# A config as the module's network_configs output carries it (locals.tf network_config).
conf() { # name profile p2p rpc magic [image-hex]
  jq -cn --arg n "$1" --arg p "$2" --argjson p2p "$3" --argjson rpc "$4" --arg m "$5" --arg h "${6:-0000000000000000000000000000000000000000000000000000000000000000}" '{
    name: $n, profile: $p, network: "testnet", image: ("ghcr.io/example/ycashd@sha256:" + $h),
    p2p_port: $p2p, rpc_port: $rpc, node_args: ("-testnet -testnetprofile=" + $p), dnsseed: false,
    extra_args: "-dbcache=256 -maxconnections=64",
    peers: [("192.0.2.10:" + ($p2p | tostring)), ("192.0.2.11:" + ($p2p | tostring))],
    prefix: {base_url: "https://example.org/prefix", sums_sha256: "c7b55a2a6770df8108d910572cca2dbf643a0418eb0b2d556879928a43cbc403", last_height: 510247, magic: $m}}'
}
b64() { base64 -w0; }
FAST=$(conf yb-fast fast 18833 18832 f77962d3 | b64)
SLOW=$(conf yb-slow slow 18933 18932 f77962d4 | b64)

# 1. apply fast: the prefix is fetched once into the cache, framed with fast's magic, imported
"$SEEDCTL" apply yb-fast "$FAST" 2>/dev/null
env_fast="$O/net/yb-fast/node.env"
grep -qx 'YCASHD_EXTRA_ARGS=-port=18833 -externalip=192.0.2.10 -testnet -testnetprofile=fast -dnsseed=0 -addnode=192.0.2.11:18833 -dbcache=256 -maxconnections=64 -loadblock=/var/lib/ycash/prefix/load/blk0.dat' "$env_fast" \
  || fail "fast's node arguments: $(grep EXTRA "$env_fast")"
grep -qx 'YCASHD_RPC_PORT=18832' "$env_fast" && grep -qx 'YCASHD_NETWORK=testnet' "$env_fast" && grep -qx 'YCASHD_RPC_BIND=127.0.0.1' "$env_fast" || fail "fast's RPC settings"
grep -q 'container_name: ycashd-yb-fast' "$O/net/yb-fast/compose.yaml" && grep -q 'image: ghcr.io/example/ycashd@sha256:0000' "$O/net/yb-fast/compose.yaml" || fail "fast's compose file"
grep -q "\"$D/yb-fast/node:/var/lib/ycash\"" "$O/net/yb-fast/compose.yaml" || fail "fast's own datadir"
[ "$(grep -c '^restore ' "$LOG")" = 1 ] && grep -q "^frame $D/prefix-cache/data/prefix f77962d3$" "$LOG" || fail "one fetch, framed with d3"
[ -s "$D/yb-fast/applied.json" ] && [ "$(stat -c %a "$D/yb-fast/rpc.env")" = 600 ] || fail "applied config and a private rpc.env"
ok "apply fast: prefix fetched and framed, ports, profile, peers without itself"

# 2. apply slow: the cache is reused, framed with slow's magic, its own ports and datadir
"$SEEDCTL" apply yb-slow "$SLOW" 2>/dev/null
[ "$(grep -c '^restore ' "$LOG")" = 1 ] || fail "the second network fetched the prefix again"
grep -q "^frame $D/prefix-cache/data/prefix f77962d4$" "$LOG" || fail "slow framed with d4"
grep -q -- '-port=18933 .*-testnetprofile=slow .*-addnode=192.0.2.11:18933' "$O/net/yb-slow/node.env" && grep -qx 'YCASHD_RPC_PORT=18932' "$O/net/yb-slow/node.env" || fail "slow's ports"
ok "apply slow: the verified prefix is shared, its own magic and ports"

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
echo "seedctl: all checks passed"
