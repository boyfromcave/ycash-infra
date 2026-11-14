#!/bin/bash
# shellcheck disable=SC2015  # `a && b || fail`: fail exits, so it is the if-then-else it reads as
# Offline test of files/seedctl: a scratch root (SEEDCTL_ROOT), a fake `docker` on PATH that logs
# what it is asked, and stand-ins for the prefix tools. Checks the per-network lifecycle on one
# host: apply (with the prefix bootstrap and the shared cache), the rendered node arguments and
# ports, prefix-check, status, reset of one network leaving the other alone, sync stopping a
# network no longer configured, boot re-rendering from the applied configs, and the refusals; then a
# pool beside a node, and an explorer (insight, ZMQ, PostgreSQL, Inzyght built on the host, proxy).
# Run: infra/testnet-seeds/nodes/tests/seedctl.sh   (make seeds-validate runs it)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
SEEDCTL="$here/../files/seedctl"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export SEEDCTL_ROOT="$T/root" LOG="$T/log" FAKE_HEIGHT=600000 FAKE_IMAGES="$T/images"
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
  image) [ "$2" = inspect ] && grep -qxF -- "$3" "$FAKE_IMAGES" 2>/dev/null; exit ;;
  build) for a in "$@"; do last=$a; done; prev=""; for a in "$@"; do [ "$prev" = -t ] && echo "$a" >> "$FAKE_IMAGES"; prev=$a; done
    [ -s "$last/Dockerfile" ] && [ -x "$last/entrypoint.sh" ] || exit 1 ;;
  buildx) exit 0 ;;
  exec)
    case "$2" in postgres-*) echo 510796; exit 0 ;; esac
    case "${!#}" in
      getblockcount) echo "$FAKE_HEIGHT" ;;
      getblockchaininfo) echo '{"chain":"test","blocks":1,"headers":1,"verificationprogress":1}' ;;
      getpeerinfo) echo '[{"inbound":true},{"inbound":false}]' ;;
    esac ;;
  inspect) case "$3" in *Health*) echo healthy ;; *Status*) echo running ;; *) echo img ;; esac ;;
esac
exit 0
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$LOG"
case "$*" in
  *api/v1/version*) echo 200; exit 0 ;;
  *127.0.0.1:3334/status*) echo '{"nodeUp":true,"height":510432,"templateAgeSeconds":0,"miners":2,"connections":2,"accepted":1,"rejected":0,"lastSubmitVerdict":"accepted","payout":"smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb","equihash":"192,7","shares":9,"stale":4,"highHash":3,"shareRatio":32,"uptimeSeconds":60}' ;;
  *) exit 7 ;;
esac
EOF
cat > "$T/bin/iptables" <<'EOF'
#!/bin/bash
echo "iptables $*" >> "$LOG"
[ "$1" != -C ] || grep -qF -- "iptables -I $2 1 ${*:3}" "$LOG"
EOF
sed 's/iptables/ip6tables/g' "$T/bin/iptables" > "$T/bin/ip6tables"
chmod +x "$T/bin/docker" "$T/bin/curl" "$T/bin/iptables" "$T/bin/ip6tables"
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
POOLED=$(conf yb-fast fast 18833 18832 f77962d3 | jq -c '.pool = {image: "ghcr.io/example/yolo@sha256:2222222222222222222222222222222222222222222222222222222222222222", payout: "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", port: 3333, status_port: 3334, text: "testnet pool", share_ratio: 32}' | b64)
: > "$LOG"
"$SEEDCTL" apply yb-fast "$POOLED" 2>"$T/err" || { cat "$T/err"; fail "apply with a pool"; }
c="$O/net/yb-fast/compose.yaml"
grep -q 'container_name: yolo-yb-fast' "$c" && grep -q 'image: ghcr.io/example/yolo@sha256:2222' "$c" && grep -q 'depends_on: \[ycashd\]' "$c" || fail "the yolo service: $(cat "$c")"
grep -qF 'command: ["--conf", "/etc/yolo/pool.conf", "--payout", "smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb", "--bind", "0.0.0.0", "--port", "3333", "--status-port", "3334", "--status-bind", "127.0.0.1", "--max-connections", "64", "--max-per-ip", "4", "--log", "info", "--share-ratio", "32", "--text", "testnet pool"]' "$c" || fail "yolo's command line: $(grep command "$c")"
grep -q 'read_only: true' "$c" && grep -q 'cap_drop: \[ALL\]' "$c" && grep -qF "\"$D/yb-fast/pool.conf:/etc/yolo/pool.conf:ro\"" "$c" || fail "yolo is read-only, no capabilities, the conf mounted read-only"
pw=$(sed -n 's/^YCASHD_RPC_PASSWORD=//p' "$D/yb-fast/rpc.env")
grep -qx "rpcpassword=$pw" "$D/yb-fast/pool.conf" && grep -qx 'rpcport=18832' "$D/yb-fast/pool.conf" && grep -qx 'rpcconnect=127.0.0.1' "$D/yb-fast/pool.conf" && [ "$(stat -c %a "$D/yb-fast/pool.conf")" = 400 ] || fail "pool.conf: the node's credential, its RPC port on loopback, mode 0400"
! grep -q "$pw" "$c" || fail "the RPC password is on yolo's command line"
grep -q '127.0.0.1:3334/status' "$LOG" || fail "apply waits for the pool's status page"
grep -qx 'iptables -I OUTPUT 1 -d 169.254.169.254/32 -m owner --uid-owner 2004 -j REJECT' "$LOG" \
  && grep -qx 'ip6tables -I OUTPUT 1 -d fd00:ec2::254/128 -m owner --uid-owner 2004 -j REJECT' "$LOG" || fail "yolo's uid is refused the metadata service"
"$SEEDCTL" boot 2>/dev/null
[ "$(grep -c '^iptables -I' "$LOG")" = 1 ] || fail "the metadata rule is installed once, not again at boot"
s=$("$SEEDCTL" status yb-fast)
[ "$(echo "$s" | jq -r '.pool.accepted')" = 1 ] && [ "$(echo "$s" | jq -c '[.pool.stale, .pool.highHash, .pool.shares, .pool.shareRatio, (.pool | has("uptimeSeconds"))]')" = '[4,3,9,32,false]' ] && [ "$(echo "$s" | jq -r '.pool.container')" = running ] && [ "$(echo "$s" | jq -r '.pool.payout')" = smFo5fMXqQU2CTMv97yXCu4kbcKbaooMRLb ] || fail "status with a pool: $s"
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
# 11. an explorer beside fast (the explorer host): the node on the explorer's networks with its
#     indexes, PostgreSQL and the proxy at once, Inzyght (built on the host from the delivered,
#     checked build context) and ZMQ only once the prefix is imported; secrets only in 0400 files
: > "$LOG"; rm -rf "$D/yb-fast" "$O/net/yb-fast"
CTX='{"Dockerfile":"FROM scratch\n","entrypoint.sh":"#!/bin/sh\n"}'
printf '%s' "$CTX" > "$T/ctx.json"
CTXSHA=$(sha256sum < "$T/ctx.json" | cut -d' ' -f1)
HF=$(jq -cn --rawfile x "$T/ctx.json" --rawfile e "$here/../files/seedctl-explorer" '{"inzyght-build.json": {mode: "0644", content: $x}, "seedctl-explorer": {mode: "0644", content: $e}}')
printf '%s' "$HF" > "$T/hf.json"
"$SEEDCTL" install-files "$T/hf.json" 2>/dev/null
cmp -s "$O/inzyght-build.json" "$T/ctx.json" && cmp -s "$O/seedctl-explorer" "$here/../files/seedctl-explorer" || fail "install-files writes the host files byte for byte"
EXPL=$(conf yb-fast fast 18833 18832 f77962d3 | jq -c --arg s "$CTXSHA" '.insight = true | .zmq_port = 28332 | .extra_args += " -disablewallet" | .explorer = {
  hostname: "explorer.example.org", acme_email: "ops@example.org", tls: true, image: null,
  build: {repo: "https://github.com/example/inzyght", commit: "17f505f273c053247b59d20270e4d6a7b74994fb", jobs: 2, context_sha256: $s},
  postgres_image: "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333",
  proxy_image: "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444",
  threads: 4, mem_limit_mb: 2048, log_level: "INFO", pg_shared_buffers_mb: 256}' | b64)
"$SEEDCTL" apply yb-fast "$EXPL" 2>"$T/err" || { cat "$T/err"; fail "apply with an explorer"; }
c="$O/net/yb-fast/compose.yaml"; e="$O/net/yb-fast/node.env"; IMG=ycash-local/inzyght:17f505f273c0-${CTXSHA:0:12}
grep -qx 'YCASHD_INSIGHT=1' "$e" && grep -qx 'YCASHD_RPC_BIND=0.0.0.0' "$e" && grep -qx 'YCASHD_RPC_ALLOWIP=172.31.250.0/24' "$e" && ! grep -q zmqpub "$e" && grep -q -- '-loadblock=' "$e" || fail "the node while importing: indexes, RPC for the backend network only, no ZMQ yet: $(cat "$e")"
! grep -q 'network_mode: host' "$c" && grep -q 'ipv4_address: "172.31.250.11"' "$c" && grep -q 'read_only: true' "$c" && grep -q 'container_name: postgres-yb-fast' "$c" && grep -q 'container_name: proxy-yb-fast' "$c" && ! grep -q 'container_name: inzyght-yb-fast' "$c" || fail "while importing: node, PostgreSQL and proxy, no Inzyght: $(cat "$c")"
grep -q 'internal: true' "$c" && grep -qF 'ports: ["80:80", "443:443"]' "$c" && [ "$(grep -c 'ports:' "$c")" = 1 ] || fail "backend internal; the proxy publishes 80 and 443, nothing else publishes"
grep -q "docker build --build-arg INZYGHT_REPO=https://github.com/example/inzyght --build-arg INZYGHT_COMMIT=17f505f273c053247b59d20270e4d6a7b74994fb --build-arg JOBS=2 --label org.ycash.infra.context=$CTXSHA -t $IMG " "$LOG" || fail "Inzyght built from the checked context: $(grep 'docker build' "$LOG")"
grep -q 'docker compose .* pull -q ycashd postgres proxy' "$LOG" || fail "the built image is never pulled"
cmp -s "$D/yb-fast/explorer/build-context.json" "$T/ctx.json" && cmp -s "$D/seedctl-explorer" "$here/../files/seedctl-explorer" || fail "the build context and seedctl-explorer are kept on the data volume"
[ "$(stat -c %a "$D/yb-fast/explorer/pg.env")" = 400 ] && [ "$(stat -c %a "$D/yb-fast/explorer/inzyght.env")" = 400 ] && [ "$(stat -c %a "$D/yb-fast/explorer")" = 700 ] || fail "the explorer's secrets: 0400 in a 0700 directory"
pgpw=$(sed -n 's/^INZYGHT_DB_PASSWORD=//p' "$D/yb-fast/explorer/pg.env"); pw=$(sed -n 's/^YCASHD_RPC_PASSWORD=//p' "$D/yb-fast/rpc.env")
grep -qx "INZYGHT_PG_PASSWORD=$pgpw" "$D/yb-fast/explorer/inzyght.env" && grep -qx "INZYGHT_RPC_PASSWORD=$pw" "$D/yb-fast/explorer/inzyght.env" && ! grep -rqF -e "$pgpw" -e "$pw" "$O/net/yb-fast" || fail "Inzyght's credentials only in its env file, never in a rendered file"
grep -qx 'explorer.example.org {' "$O/net/yb-fast/Caddyfile" && grep -qx '	email ops@example.org' "$O/net/yb-fast/Caddyfile" && grep -q 'reverse_proxy inzyght:8080' "$O/net/yb-fast/Caddyfile" && grep -q 'user: "2006:2006"' "$c" && [ "$(grep -c 'mem_limit:' "$c")" = 3 ] || fail "the Caddyfile: the name, the contact, Inzyght"
grep -qx 'iptables -I DOCKER-USER 1 -s 172.31.250.0/23 -d 169.254.169.254/32 -j REJECT' "$LOG" || fail "the explorer's networks are refused the metadata service"
ok "an explorer while the prefix imports: node on its networks, PostgreSQL and proxy, Inzyght built, secrets private"
"$SEEDCTL" prefix-check 2>/dev/null
grep -q -- '-zmqpubhashblock=tcp://172.31.250.11:28332 -zmqpubhashtx=tcp://172.31.250.11:28332' "$e" && ! grep -q loadblock "$e" || fail "ZMQ on the node's backend address after the import: $(grep EXTRA "$e")"
grep -q 'container_name: inzyght-yb-fast' "$c" && grep -q "image: $IMG" "$c" && grep -q 'pull_policy: never' "$c" && grep -q 'INZYGHT_ZMQ_ENDPOINT: "tcp://172.31.250.11:28332"' "$c" && grep -q 'INZYGHT_TRUSTED_PROXIES: "172.31.250.10"' "$c" && grep -q 'user: "2005:2005"' "$c" || fail "Inzyght after the import: $(cat "$c")"
s=$("$SEEDCTL" status yb-fast)
[ "$(echo "$s" | jq -c '[.explorer.indexedHeight, .explorer.httpOnHost, .explorer.httpPublic, .explorer.url, .explorer.inzyght]')" = '[510796,"200","200","https://explorer.example.org/","healthy"]' ] || fail "status with an explorer: $s"
ok "after the import: ZMQ, Inzyght; status reports the index height and HTTPS"
# a new instance on the old volume: no image, no seedctl-explorer on the root disk; boot rebuilds from the volume's copies
rm -rf "$O/net" "$O/seedctl-explorer" "$O/inzyght-build.json"; : > "$FAKE_IMAGES"; : > "$LOG"
"$SEEDCTL" boot 2>/dev/null
grep -q "docker build .* -t $IMG " "$LOG" && grep -q 'container_name: inzyght-yb-fast' "$c" || fail "boot on a new instance rebuilds Inzyght and renders the explorer"
ok "boot on a new instance: seedctl-explorer and the build context from the data volume"
touch "$D/yb-fast/explorer/pg/PG_VERSION" "$D/yb-fast/explorer/caddy/data/cert"
"$SEEDCTL" reset yb-fast "$EXPL" 2>/dev/null
[ ! -e "$D/yb-fast/explorer/pg/PG_VERSION" ] && [ -e "$D/yb-fast/explorer/caddy/data/cert" ] && grep -qx "INZYGHT_DB_PASSWORD=$pgpw" "$D/yb-fast/explorer/pg.env" || fail "reset: the index goes with the chain; the certificate and the secrets stay"
ok "reset: the index is wiped with the chain, the certificate kept"
BADX=$(echo "$EXPL" | base64 -d | jq -c '.explorer.log_level = "DEBUG"' | b64)
if "$SEEDCTL" apply yb-fast "$BADX" 2>/dev/null; then fail "accepted DEBUG (it logs the database password)"; fi
BADX=$(echo "$EXPL" | base64 -d | jq -c '.explorer.hostname = "x\nemail evil"' | b64)
if "$SEEDCTL" apply yb-fast "$BADX" 2>/dev/null; then fail "accepted a newline in the host name"; fi
BADX=$(echo "$EXPL" | base64 -d | jq -c '.explorer.build.context_sha256 = "abababababababababababababababababababababababababababababababab"' | b64)
if "$SEEDCTL" apply yb-fast "$BADX" 2>/dev/null; then fail "built from a context that does not match its sha256"; fi
ok "refuses DEBUG, an injected host name, a build context that does not match"
: > "$LOG"
"$SEEDCTL" apply yb-fast "$FAST2" 2>/dev/null
grep -q 'network_mode: host' "$c" && ! grep -q postgres "$c" && grep -q 'docker rm -f postgres-yb-fast inzyght-yb-fast proxy-yb-fast' "$LOG" && grep -qx 'YCASHD_INSIGHT=0' "$e" || fail "an explorer removed from the config"
ok "an explorer removed from the config is removed from the host"
echo "seedctl: all checks passed"
