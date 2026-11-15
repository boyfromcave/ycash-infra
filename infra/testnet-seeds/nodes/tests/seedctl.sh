#!/bin/bash
# shellcheck disable=SC2015  # `a && b || fail`: fail exits, so it is the if-then-else it reads as
# Offline test of files/seedctl: a scratch root (SEEDCTL_ROOT), a fake `docker` on PATH that logs
# what it is asked, and stand-ins for the prefix tools. Checks the per-network lifecycle on one
# host: apply (with the prefix bootstrap and the shared cache), the rendered node arguments and
# ports, prefix-check, status, reset of one network leaving the other alone, sync stopping a
# network no longer configured, boot re-rendering from the applied configs, and the refusals; then a
# pool beside a node, an explorer (insight, ZMQ, PostgreSQL, Inzyght built on the host, proxy; a
# failed build; install-files refusals), a detached run (and one still holding the lock; status
# before the first applied.json), and a host without the prefix tools.
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
  image) case "$2" in
      inspect) grep -qxF -- "$3" "$FAKE_IMAGES" 2>/dev/null ;;
      ls) grep -F "${!#}:" "$FAKE_IMAGES" 2>/dev/null || true ;;
      rm) grep -vxF -- "$3" "$FAKE_IMAGES" > "$FAKE_IMAGES.new"; mv "$FAKE_IMAGES.new" "$FAKE_IMAGES" ;;
    esac; exit ;;
  build) [ -z "${FAKE_BUILD_FAIL:-}" ] || { echo "fake build failure"; exit 1; }
    for a in "$@"; do last=$a; done; prev=""; for a in "$@"; do [ "$prev" = -t ] && echo "$a" >> "$FAKE_IMAGES"; prev=$a; done
    [ -s "$last/Dockerfile" ] && [ -x "$last/entrypoint.sh" ] || exit 1 ;;
  buildx) [ -z "${FAKE_NO_BUILDX:-}" ] || [ -e "$FAKE_IMAGES.buildx" ]; exit ;;
  exec)
    case "$2" in postgres-*) echo 510796; exit 0 ;;
      # lightwalletd's lwdinfo: GetLightdInfo and the latest block (FAKE_LWD_HEIGHT), or no answer
      lightwalletd-*) [ -z "${FAKE_LWD_DOWN:-}" ] || exit 1
        echo "{\"version\":\"v0.4.6\",\"vendor\":\"Ycash\",\"taddrSupport\":true,\"chainName\":\"test\",\"saplingActivationHeight\":280000,\"consensusBranchId\":\"6d5b7a31\",\"blockHeight\":${FAKE_LWD_HEIGHT:-600000},\"latestHeight\":${FAKE_LWD_HEIGHT:-600000}}"; exit 0 ;;
    esac
    case "${!#}" in
      getblockcount) echo "$FAKE_HEIGHT" ;;
      getblockchaininfo) echo '{"chain":"test","blocks":1,"headers":1,"verificationprogress":1}' ;;
      getpeerinfo) echo '[{"inbound":true},{"inbound":false}]' ;;
    esac ;;
  # a container named in FAKE_ABSENT is missing: an empty line on stdout, then the error (as docker does)
  inspect) case " ${FAKE_ABSENT:-} " in *" $4 "*) echo; echo "Error: No such object: $4" >&2; exit 1 ;; esac
    case "$3" in
      *RestartCount*) case "$4" in ycashd-*) echo "${FAKE_RESTARTS:-0} ${FAKE_OOM:-false}" ;; *) echo "0 false" ;; esac ;;
      *StartedAt*) echo 2026-11-14T10:00:00.123456789Z ;;
      *Health*) echo healthy ;; *Status*) echo running ;; *) echo img ;;
    esac ;;
esac
exit 0
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$LOG"
case "$*" in
  *api/v1/version*) echo 200; exit 0 ;;
  # a gRPC GetLightdInfo through the lightwallet's proxy (lw_probe): FAKE_LW ok (native: grpc-status
  # in the HTTP/2 trailers, which curl writes with the headers; gRPC-web: in the body's trailer
  # frame), starting (the proxy's 503) or down (no connection)
  *CompactTxStreamer/GetLightdInfo*)
    prev=""; for a in "$@"; do case "$prev" in -o) out=$a ;; -D) hdr=$a ;; esac; prev=$a; done
    cat >/dev/null
    case "${FAKE_LW:-ok}" in
      ok) case "$*" in
          *x-grpc-web*) printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"; printf '\000\000\000\000\002\010\001\200\000\000\000\017grpc-status:0\r\n' > "$out" ;;
          *) printf 'HTTP/2 200\r\ncontent-type: application/grpc\r\n\r\ngrpc-status: 0\r\n' > "$hdr"; : > "$out" ;;
        esac; echo 200 ;;
      starting) printf 'HTTP/2 503\r\n\r\n' > "$hdr"; echo starting > "$out"; echo 503 ;;
      down) echo 000; exit 7 ;;
    esac ;;
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
cat > "$T/bin/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >> "$LOG"
case "$*" in *" install "*docker-buildx*) touch "$FAKE_IMAGES.buildx" ;; esac
EOF
# the kernel log (status counts its OOM kills of ycashd): journalctl prints FAKE_KLOG (short-unix
# times) and, with FAKE_JOURNAL_FAIL, fails after printing it; dmesg prints FAKE_DMESG
cat > "$T/bin/journalctl" <<'EOF'
#!/bin/bash
printf '%s' "${FAKE_KLOG:-}"
[ -z "${FAKE_JOURNAL_FAIL:-}" ] || exit 1
EOF
cat > "$T/bin/dmesg" <<'EOF'
#!/bin/bash
printf '%s' "${FAKE_DMESG:-}"
EOF
# systemd-run: runs the unit's command at once, in the foreground; systemctl: no unit is active
cat > "$T/bin/systemd-run" <<'EOF'
#!/bin/bash
echo "systemd-run $*" >> "$LOG"
while [ "${1#--}" != "$1" ]; do shift; done
"$@" 2>>"$LOG.job" || true
EOF
# systemctl: no unit is active, unless FAKE_ACTIVE names a file that exists (a detached run going)
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
[ -n "${FAKE_ACTIVE:-}" ] && [ -e "$FAKE_ACTIVE" ] && exit 0
exit 3
EOF
chmod +x "$T/bin/journalctl" "$T/bin/dmesg" "$T/bin/docker" "$T/bin/curl" "$T/bin/iptables" "$T/bin/ip6tables" "$T/bin/apt-get" "$T/bin/systemd-run" "$T/bin/systemctl"
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
cp "$O/seed.env" "$T/seed.env.before"
for bad in '{"seed.env": {"mode": "0644", "content": "SEED_NAME=evil\n"}}' '{"../x": {"mode": "0644", "content": "x"}}' \
           '{"frame.py": {"mode": "0644", "content": "x"}, "setup.sh": {"mode": "0755", "content": "x"}}' \
           '{"frame.py": {"mode": "0777", "content": "x"}}' '{"frame.py\nseed.env": {"mode": "0644", "content": "x"}}'; do
  printf '%s' "$bad" > "$T/bad.json"
  if "$SEEDCTL" install-files "$T/bad.json" 2>/dev/null; then fail "install-files accepted $bad"; fi
done
cmp -s "$O/seed.env" "$T/seed.env.before" && [ ! -e "$SEEDCTL_ROOT/opt/x" ] && [ ! -e "$O/setup.sh" ] && ! grep -qx x "$O/frame.py" || fail "a refused host file was written"
ok "install-files: the module's five names only, modes 0644 or 0755, nothing written on a refusal"
printf 'ycash-local/inzyght:000000000000-000000000000\n' > "$FAKE_IMAGES"   # a stale build
EXPL=$(conf yb-fast fast 18833 18832 f77962d3 | jq -c --arg s "$CTXSHA" '.insight = true | .zmq_port = 28332 | .extra_args += " -disablewallet" | .explorer = {
  hostname: "explorer.example.org", acme_email: "ops@example.org", tls: true, image: null,
  build: {repo: "https://github.com/example/inzyght", commit: "17f505f273c053247b59d20270e4d6a7b74994fb", jobs: 2, context_sha256: $s},
  postgres_image: "docker.io/library/postgres@sha256:3333333333333333333333333333333333333333333333333333333333333333",
  proxy_image: "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444",
  threads: 4, mem_limit_mb: 2048, log_level: "INFO", pg_shared_buffers_mb: 256}' | b64)
"$SEEDCTL" apply yb-fast "$EXPL" 2>"$T/err" || { cat "$T/err"; fail "apply with an explorer"; }
c="$O/net/yb-fast/compose.yaml"; e="$O/net/yb-fast/node.env"; IMG=ycash-local/inzyght:17f505f273c0-${CTXSHA:0:12}
grep -qx 'YCASHD_INSIGHT=1' "$e" && grep -qx 'YCASHD_RPC_BIND=0.0.0.0' "$e" && grep -qx 'YCASHD_RPC_ALLOWIP=172.31.250.12' "$e" && ! grep -q zmqpub "$e" && grep -q -- '-loadblock=' "$e" || fail "the node while importing: indexes, RPC for the backend network only, no ZMQ yet: $(cat "$e")"
! grep -q 'network_mode: host' "$c" && grep -q 'ipv4_address: "172.31.250.11"' "$c" && grep -q 'read_only: true' "$c" && grep -q 'container_name: postgres-yb-fast' "$c" && grep -q 'container_name: proxy-yb-fast' "$c" && ! grep -q 'container_name: inzyght-yb-fast' "$c" || fail "while importing: node, PostgreSQL and proxy, no Inzyght: $(cat "$c")"
grep -q 'internal: true' "$c" && grep -qF 'ports: ["80:80", "443:443"]' "$c" && [ "$(grep -c 'ports:' "$c")" = 1 ] || fail "backend internal; the proxy publishes 80 and 443, nothing else publishes"
grep -q "docker build --build-arg INZYGHT_REPO=https://github.com/example/inzyght --build-arg INZYGHT_COMMIT=17f505f273c053247b59d20270e4d6a7b74994fb --build-arg JOBS=2 --label org.ycash.infra.context=$CTXSHA -t $IMG " "$LOG" || fail "Inzyght built from the checked context: $(grep 'docker build' "$LOG")"
grep -q 'docker compose .* pull -q ycashd postgres proxy' "$LOG" || fail "the built image is never pulled"
grep -qx 'docker builder prune -f' "$LOG" && grep -qx 'docker image rm ycash-local/inzyght:000000000000-000000000000' "$LOG" && grep -qxF "$IMG" "$FAKE_IMAGES" || fail "after the build: BuildKit's cache pruned, the stale tag removed, the new one kept"
[ "$(stat -c %a "$O/net/yb-fast/Caddyfile")" = 640 ] && [ "$(stat -c %a "$D/yb-fast/applied.json")" = 600 ] || fail "the Caddyfile (0640) and the config (0600) carry the certificate contact"
cmp -s "$D/yb-fast/explorer/build-context.json" "$T/ctx.json" && cmp -s "$D/seedctl-explorer" "$here/../files/seedctl-explorer" || fail "the build context and seedctl-explorer are kept on the data volume"
[ "$(stat -c %a "$D/yb-fast/explorer/pg.env")" = 400 ] && [ "$(stat -c %a "$D/yb-fast/explorer/inzyght.env")" = 400 ] && [ "$(stat -c %a "$D/yb-fast/explorer")" = 700 ] || fail "the explorer's secrets: 0400 in a 0700 directory"
pgpw=$(sed -n 's/^INZYGHT_DB_PASSWORD=//p' "$D/yb-fast/explorer/pg.env"); pw=$(sed -n 's/^YCASHD_RPC_PASSWORD=//p' "$D/yb-fast/rpc.env")
grep -qx "INZYGHT_PG_PASSWORD=$pgpw" "$D/yb-fast/explorer/inzyght.env" && grep -qx "INZYGHT_RPC_PASSWORD=$pw" "$D/yb-fast/explorer/inzyght.env" && ! grep -rqF -e "$pgpw" -e "$pw" "$O/net/yb-fast" || fail "Inzyght's credentials only in its env file, never in a rendered file"
grep -qx 'explorer.example.org {' "$O/net/yb-fast/Caddyfile" && grep -qx '	email ops@example.org' "$O/net/yb-fast/Caddyfile" && grep -q 'reverse_proxy inzyght:8080' "$O/net/yb-fast/Caddyfile" && grep -q 'user: "2006:2006"' "$c" && [ "$(grep -c 'mem_limit:' "$c")" = 3 ] || fail "the Caddyfile: the name, the contact, Inzyght"
grep -qx 'iptables -I DOCKER-USER 1 -s 172.31.250.0/23 -d 169.254.169.254/32 -j REJECT' "$LOG" || fail "the explorer's networks are refused the metadata service"
grep -qx '    mem_limit: 2304m' "$c" && grep -qx '    memswap_limit: 4352m' "$c" && [ "$(grep -c 'memswap_limit:' "$c")" = 1 ] || fail "the node: 2304 MiB by default (a config without node_mem_limit_mb), 2 GiB of swap beyond it: $(grep mem "$c")"
s=$(FAKE_HEIGHT=255123 FAKE_ABSENT=inzyght-yb-fast "$SEEDCTL" status yb-fast)
[ "$(echo "$s" | jq -r .explorer.phase)" = "prefix import: 255123 of 510247 (49 %)" ] || fail "status during the import: $s"
[ "$(echo "$s" | jq -c '[.explorer.inzyght, .explorer.image, .explorer.restarts, .explorer.oomKilled, .explorer.nodeStartedAt, .explorer.nodeOomKills, .explorer.nodeOomKillsSinceBoot]')" = '["absent","-",{"ycashd":0,"postgres":0,"inzyght":null,"proxy":0},{"ycashd":false,"postgres":false,"inzyght":null,"proxy":false},"2026-11-14T10:00:00.123456789Z",{"cgroup":0,"host":0},{"cgroup":0,"host":0}]' ] || fail "status: restarts, OOM flags, a missing container without docker's empty line: $s"
s=$(FAKE_HEIGHT=255123 FAKE_ABSENT=inzyght-yb-fast FAKE_RESTARTS=2 "$SEEDCTL" status yb-fast)
[ "$(echo "$s" | jq -r .explorer.phase)" = "prefix import: 255123 of 510247 (49 %), node restarted 2 times (OOM: no)" ] || fail "a restart during the import: $s"
# the fake node started at 2026-11-14T10:00:00Z = 1794650400; kernel lines as journalctl -o short-unix prints them
cg() { echo "$1.250000 host kernel: Memory cgroup out of memory: Killed process 4242 (ycashd) total-vm:3000000kB, anon-rss:1549184kB"; }
hw() { echo "$1.250000 host kernel: Out of memory: Killed process 4243 (ycashd) total-vm:3000000kB"; }
s=$(FAKE_HEIGHT=255123 FAKE_RESTARTS=1 FAKE_KLOG="$(cg 1794650370)"$'\n' "$SEEDCTL" status yb-fast)
[ "$(echo "$s" | jq -r .explorer.phase)" = "prefix import: 255123 of 510247 (49 %), node restarted 1 time (OOM: yes)" ] && [ "$(echo "$s" | jq -c '[.explorer.nodeOomKills, .explorer.nodeOomKillsSinceBoot]')" = '[{"cgroup":1,"host":0},{"cgroup":1,"host":0}]' ] || fail "a cgroup OOM kill 30 s before the node's start: $s"
s=$(FAKE_HEIGHT=255123 FAKE_RESTARTS=2 FAKE_KLOG="$(cg 1794646800)"$'\n' "$SEEDCTL" status yb-fast)
[ "$(echo "$s" | jq -r .explorer.phase)" = "prefix import: 255123 of 510247 (49 %), node restarted 2 times (OOM: no)" ] && [ "$(echo "$s" | jq -c '[.explorer.nodeOomKills, .explorer.nodeOomKillsSinceBoot]')" = '[{"cgroup":0,"host":0},{"cgroup":1,"host":0}]' ] || fail "a kill an hour before the current start is not this restart's: $s"
s=$(FAKE_HEIGHT=255123 FAKE_RESTARTS=1 FAKE_KLOG="$(cg 1794646800)"$'\n'"$(hw 1794650395)"$'\n' "$SEEDCTL" status yb-fast)
[ "$(echo "$s" | jq -r .explorer.phase)" = "prefix import: 255123 of 510247 (49 %), node restarted 1 time (OOM: yes, the host ran out of memory)" ] && [ "$(echo "$s" | jq -c '[.explorer.nodeOomKills, .explorer.nodeOomKillsSinceBoot]')" = '[{"cgroup":0,"host":1},{"cgroup":1,"host":1}]' ] || fail "a host-wide OOM kill, counted apart from the cgroup ones: $s"
s=$(FAKE_HEIGHT=255123 FAKE_RESTARTS=1 FAKE_JOURNAL_FAIL=1 FAKE_KLOG="$(cg 1794650370)"$'\n' FAKE_DMESG=$'[  812.1] Memory cgroup out of memory: Killed process 4242 (ycashd) total-vm:3000000kB\n' "$SEEDCTL" status yb-fast)
[ "$(echo "$s" | jq -c .explorer.nodeOomKillsSinceBoot)" = '{"cgroup":1,"host":0}' ] || fail "a failing journalctl, then dmesg: each kill counted once: $s"
[ "$(FAKE_HEIGHT=255123 FAKE_RESTARTS=1 FAKE_OOM=true "$SEEDCTL" status yb-fast | jq -r .explorer.phase)" = "prefix import: 255123 of 510247 (49 %), node restarted 1 time (OOM: yes)" ] || fail "Docker's OOMKilled flag"
[ "$(FAKE_ABSENT=ycashd-yb-fast "$SEEDCTL" status yb-fast | jq -c '[.container, .image, .explorer.restarts.ycashd, .explorer.nodeStartedAt]')" = '["absent","-",null,null]' ] || fail "status with the node's container missing"
ok "an explorer while the prefix imports: node on its networks, PostgreSQL and proxy, Inzyght built, secrets private; status in percent, restarts and OOM kills"
"$SEEDCTL" prefix-check 2>/dev/null
grep -q -- '-zmqpubhashblock=tcp://172.31.250.11:28332 -zmqpubhashtx=tcp://172.31.250.11:28332' "$e" && ! grep -q loadblock "$e" || fail "ZMQ on the node's backend address after the import: $(grep EXTRA "$e")"
grep -q 'container_name: inzyght-yb-fast' "$c" && grep -q "image: $IMG" "$c" && grep -q 'pull_policy: never' "$c" && grep -q 'INZYGHT_ZMQ_ENDPOINT: "tcp://172.31.250.11:28332"' "$c" && grep -q 'INZYGHT_TRUSTED_PROXIES: "172.31.250.10"' "$c" && grep -q 'user: "2005:2005"' "$c" && grep -q 'ipv4_address: "172.31.250.12"' "$c" || fail "Inzyght after the import: $(cat "$c")"
s=$(FAKE_HEIGHT=510796 "$SEEDCTL" status yb-fast)
[ "$(echo "$s" | jq -c '[.explorer.indexedHeight, .explorer.httpOnHost, .explorer.httpPublic, .explorer.url, .explorer.inzyght, .explorer.phase]')" = '[510796,"200","200","https://explorer.example.org/","healthy","serving"]' ] && [ "$(echo "$s" | jq 'has("job")')" = false ] || fail "status with an explorer: $s"
[ "$("$SEEDCTL" status yb-fast | jq -r .explorer.phase)" = "indexing: 510796 of 600000" ] || fail "status while Inzyght indexes"
ok "after the import: ZMQ, Inzyght at its fixed address; status reports the phase, the index height and HTTPS"
# a build that fails keeps Inzyght down, never the node: the rest starts, apply fails naming it,
# status says why; the next apply builds and starts it
: > "$FAKE_IMAGES"; : > "$LOG"
if FAKE_BUILD_FAIL=1 FAKE_NO_BUILDX=1 "$SEEDCTL" apply yb-fast "$EXPL" 2>"$T/err"; then fail "apply succeeded without the Inzyght image"; fi
grep -q 'Inzyght is not: docker build failed' "$T/err" && grep -q '^up ycash-yb-fast$' "$LOG" && grep -q 'container_name: ycashd-yb-fast' "$c" && grep -q 'container_name: proxy-yb-fast' "$c" && ! grep -q 'inzyght:' "$c" && ! grep -q 'depends_on: { inzyght' "$c" || fail "a failed build: node, PostgreSQL and proxy up without Inzyght: $(cat "$T/err")"
grep -qx 'apt-get -o DPkg::Lock::Timeout=600 install -y -q --no-install-recommends docker-buildx' "$LOG" || fail "docker-buildx installed with the dpkg lock wait: $(grep apt-get "$LOG")"
s=$("$SEEDCTL" status yb-fast)
echo "$s" | jq -e '(.explorer.phase | startswith("explorer image missing: docker build failed")) and (.explorer.imageMissing | startswith("docker build failed")) and .container == "running"' >/dev/null || fail "status names the missing image: $s"
: > "$LOG"
"$SEEDCTL" apply yb-fast "$EXPL" 2>"$T/err" || { cat "$T/err"; fail "the next apply builds Inzyght"; }
grep -q 'container_name: inzyght-yb-fast' "$c" && [ ! -e "$D/yb-fast/explorer/build-failed" ] && [ "$("$SEEDCTL" status yb-fast | jq '.explorer | has("imageMissing")')" = false ] || fail "the image built on the next apply"
ok "a failed Inzyght build: the node, PostgreSQL and the proxy run, apply and status name it; the next apply recovers"
# a new instance on the old volume: no image, no seedctl-explorer on the root disk; boot rebuilds from the volume's copies
rm -rf "$O/net" "$O/seedctl-explorer" "$O/inzyght-build.json"; : > "$FAKE_IMAGES"; : > "$LOG"
"$SEEDCTL" boot 2>/dev/null
grep -q "docker build .* -t $IMG " "$LOG" && grep -q 'container_name: inzyght-yb-fast' "$c" || fail "boot on a new instance rebuilds Inzyght and renders the explorer"
[ "$(grep -n -m1 '^up ycash-yb-fast$' "$LOG" | cut -d: -f1)" -lt "$(grep -n -m1 '^docker build ' "$LOG" | cut -d: -f1)" ] && [ "$(grep -c '^up ycash-yb-fast$' "$LOG")" = 2 ] || fail "boot starts the node before the build, then Inzyght"
ok "boot on a new instance: the node first, then the image rebuilt from the data volume's copies and Inzyght started"
touch "$D/yb-fast/explorer/pg/PG_VERSION" "$D/yb-fast/explorer/caddy/data/cert"
"$SEEDCTL" reset yb-fast "$EXPL" 2>/dev/null
[ ! -e "$D/yb-fast/explorer/pg/PG_VERSION" ] && [ -e "$D/yb-fast/explorer/caddy/data/cert" ] && grep -qx "INZYGHT_DB_PASSWORD=$pgpw" "$D/yb-fast/explorer/pg.env" || fail "reset: the index goes with the chain; the certificate and the secrets stay"
ok "reset: the index is wiped with the chain, the certificate kept"
BADX=$(echo "$EXPL" | base64 -d | jq -c '.explorer.node_mem_limit_mb = 100' | b64)
if "$SEEDCTL" apply yb-fast "$BADX" 2>/dev/null; then fail "accepted a node memory limit of 100 MiB"; fi
MEMX=$(echo "$EXPL" | base64 -d | jq -c '.explorer.node_mem_limit_mb = 3072' | b64)
"$SEEDCTL" apply yb-fast "$MEMX" 2>/dev/null || fail "apply with node_mem_limit_mb"
grep -qx '    mem_limit: 3072m' "$c" && grep -qx '    memswap_limit: 5120m' "$c" || fail "node_mem_limit_mb 3072: $(grep mem "$c")"
BADX=$(echo "$EXPL" | base64 -d | jq -c '.explorer.log_level = "DEBUG"' | b64)
if "$SEEDCTL" apply yb-fast "$BADX" 2>/dev/null; then fail "accepted DEBUG (it logs the database password)"; fi
BADX=$(echo "$EXPL" | base64 -d | jq -c '.explorer.hostname = "x\nemail evil"' | b64)
if "$SEEDCTL" apply yb-fast "$BADX" 2>/dev/null; then fail "accepted a newline in the host name"; fi
BADX=$(echo "$EXPL" | base64 -d | jq -c '.explorer.build.context_sha256 = "abababababababababababababababababababababababababababababababab"' | b64)
if "$SEEDCTL" apply yb-fast "$BADX" 2>/dev/null; then fail "built from a context that does not match its sha256"; fi
ok "node_mem_limit_mb renders the node's limit; refuses a small one, DEBUG, an injected host name, a build context that does not match"
# inbound P2P: the node's P2P port published (IPv4, that port only), the host's address advertised;
# refused with a -listen in the arguments or a non-boolean; without the option, the file as before
"$SEEDCTL" apply yb-fast "$MEMX" 2>/dev/null && cp "$c" "$T/compose.before" || fail "apply without p2p_inbound"
INX=$(echo "$MEMX" | base64 -d | jq -c '.explorer.p2p_inbound = true' | b64)
"$SEEDCTL" apply yb-fast "$INX" 2>/dev/null || fail "apply with p2p_inbound"
grep -qxF '    ports: ["0.0.0.0:18833:18833/tcp"]' "$c" && [ "$(grep -c 'ports:' "$c")" = 2 ] && grep -qF 'ports: ["80:80", "443:443"]' "$c" \
  && [ "$(awk '/^  [a-z]+:$/ { s = $1 } /ports: \["0.0.0.0:18833/ { print s }' "$c")" = "ycashd:" ] || fail "p2p_inbound: the node publishes 18833 on IPv4, the proxy 80 and 443, nothing else: $(grep -n 'ports:' "$c")"
diff <(grep -v '^    ports: \["0.0.0.0:18833:18833/tcp"\]$' "$c") "$T/compose.before" >/dev/null || fail "p2p_inbound changes the published port only"
grep -q -- '-port=18833 -externalip=192.0.2.10 ' "$e" && ! grep -q -- '-listen' "$e" && grep -qx 'YCASHD_LISTEN=1' "$e" || fail "p2p_inbound: the node listens and advertises the host's address: $(cat "$e")"
for bad in '.extra_args += " -listen=0"' '.extra_args += " -nolisten"' '.extra_args += " -listen=false"' '.explorer.p2p_inbound = "yes"'; do
  BADX=$(echo "$INX" | base64 -d | jq -c "$bad" | b64)
  if "$SEEDCTL" apply yb-fast "$BADX" 2>/dev/null; then fail "p2p_inbound accepted $bad"; fi
done
"$SEEDCTL" apply yb-fast "$MEMX" 2>/dev/null && cmp -s "$c" "$T/compose.before" || fail "p2p_inbound off again: the compose file as before"
ok "p2p_inbound publishes the node's P2P port only, advertises the host's address; refuses a -listen; off renders as before"
: > "$LOG"
"$SEEDCTL" apply yb-fast "$FAST2" 2>/dev/null
grep -q 'network_mode: host' "$c" && ! grep -q postgres "$c" && grep -q 'docker rm -f postgres-yb-fast inzyght-yb-fast proxy-yb-fast' "$LOG" && grep -qx 'YCASHD_INSIGHT=0' "$e" || fail "an explorer removed from the config"
ok "an explorer removed from the config is removed from the host"
# 12. detach: the command runs as a transient unit (here at once), status reports it
: > "$LOG"
"$SEEDCTL" detach apply yb-fast "$EXPL" 2>/dev/null
grep -q "^systemd-run --unit=ycash-seedctl-job .* $(readlink -f "$SEEDCTL") job$" "$LOG" && [ ! -e "$D/job.args" ] && grep -q 'container_name: postgres-yb-fast' "$c" || fail "detach runs the apply as ycash-seedctl-job"
s=$("$SEEDCTL" status yb-fast)
echo "$s" | jq -e '.job.command == "apply yb-fast" and .job.state == "succeeded" and .job.phase == "done" and (.job.finished | type == "string")' >/dev/null || fail "status reports the detached run: $s"
[ "$(stat -c %a "$D/job.log")" = 600 ] || fail "the job's log is private"
BADJ=$(echo "$EXPL" | base64 -d | jq -c '.explorer.log_level = "DEBUG"' | b64)
"$SEEDCTL" detach apply yb-fast "$BADJ" 2>/dev/null
s=$("$SEEDCTL" status yb-fast)
echo "$s" | jq -e '.job.state == "failed" and (.job.message | test("not valid"))' >/dev/null || fail "a failed detached run: $s"
if "$SEEDCTL" detach stop yb-fast 2>/dev/null; then fail "detach accepted stop"; fi
ok "detach: apply in the background, its result and phase in status"
# 12b. a detached run still going (it holds the host lock): status answers at once with its phase,
#      install-files (a second deploy's first command) refuses at once naming the phase, detach too
mkdir -p "$SEEDCTL_ROOT/run"
jq -cn '{command: "apply yb-fast", state: "running", phase: "building the Inzyght image", phaseSince: "2026-11-14T10:00:00Z", started: "2026-11-14T09:58:00Z"}' > "$D/job.json"
touch "$T/active"; export FAKE_ACTIVE="$T/active"
flock "$SEEDCTL_ROOT/run/ycash-seedctl.lock" sleep 60 & holder=$!
sleep 1
t0=$(date +%s)
s=$(timeout 20 "$SEEDCTL" status yb-fast) || fail "status during a held lock did not answer"
echo "$s" | jq -e '.job.state == "running" and .job.phase == "building the Inzyght image"' >/dev/null || fail "status during a detached run: $s"
if timeout 20 "$SEEDCTL" install-files "$T/hf.json" 2>"$T/err"; then fail "install-files ran during a detached run"; fi
grep -qF 'a detached run is still going: phase building the Inzyght image (seedctl apply yb-fast, since 2026-11-14T10:00:00Z); run status' "$T/err" || fail "install-files during a detached run: $(cat "$T/err")"
if timeout 20 "$SEEDCTL" detach apply yb-fast "$EXPL" 2>"$T/err"; then fail "a second detach started"; fi
grep -qF 'a detached run is still going: phase building the Inzyght image' "$T/err" || fail "detach during a detached run: $(cat "$T/err")"
[ $(($(date +%s) - t0)) -lt 10 ] || fail "status, install-files and detach waited on the lock"
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
ok "a detached run holding the lock: status answers at once with its phase; install-files and detach refuse at once, naming it"
# 12c. before the first applied.json: status (all) prints the job; after a reboot it is interrupted
mkdir -p "$T/kept"; for f in "$D"/*/applied.json; do mv "$(dirname "$f")" "$T/kept/"; done
s=$("$SEEDCTL" status)
echo "$s" | jq -e '.host == "seed-0" and .job.state == "running" and .job.phase == "building the Inzyght image" and (has("network") | not)' >/dev/null || fail "status all before the first applied.json: $s"
s=$("$SEEDCTL" status yb-fast)
echo "$s" | jq -e '.network == "yb-fast" and .container == "running" and .job.state == "running" and (has("explorer") | not)' >/dev/null || fail "status NET before the first applied.json: $s"
rm -f "$T/active"
s=$("$SEEDCTL" status)
echo "$s" | jq -e '.job.state == "interrupted" and .job.phase == "building the Inzyght image"' >/dev/null || fail "status after a reboot: $s"
"$SEEDCTL" install-files "$T/hf.json" 2>/dev/null || fail "install-files after an interrupted run"
mv "$T/kept"/* "$D/"; rm -f "$D/job.json"; unset FAKE_ACTIVE
[ -z "$(SEEDCTL_ROOT="$T/empty" bash -c 'mkdir -p "$SEEDCTL_ROOT/opt/ycash-seed"; cp "$1" "$SEEDCTL_ROOT/opt/ycash-seed/"; "$2" status' x "$O/seed.env" "$SEEDCTL")" ] || fail "a host with no network and no job prints nothing (as before)"
ok "status before the first applied.json: the job's phase and state, interrupted after a reboot; nothing on a host without a job"
# 14. a lightwallet beside fast (the lightwallet host): the node on the lightwallet's networks with its
#     indexes, the two proxies at once, lightwalletd only once the prefix is imported; the node's
#     credential only in lightwalletd's 0400 conf; status reports GetLightdInfo, the height and the
#     four probes; a reset keeps the certificate; refusals; removed from the config
: > "$LOG"; rm -rf "$D/yb-fast" "$O/net/yb-fast"
jq -cn --rawfile l "$here/../files/seedctl-lightwallet" '{"seedctl-lightwallet": {mode: "0644", content: $l}}' > "$T/hfl.json"
"$SEEDCTL" install-files "$T/hfl.json" 2>/dev/null && cmp -s "$O/seedctl-lightwallet" "$here/../files/seedctl-lightwallet" || fail "install-files: seedctl-lightwallet"
LWC=$(conf yb-fast fast 18833 18832 f77962d3 | jq -c '.insight = true | .extra_args += " -disablewallet" | .lightwallet = {
  hostname: "lightwallet.example.org", acme_email: "ops@example.org", tls: true,
  image: "ghcr.io/example/lightwalletd@sha256:6666666666666666666666666666666666666666666666666666666666666666",
  grpcweb_image: "docker.io/envoyproxy/envoy@sha256:7777777777777777777777777777777777777777777777777777777777777777",
  proxy_image: "docker.io/library/caddy@sha256:4444444444444444444444444444444444444444444444444444444444444444",
  grpcweb_origins: ["*"], mem_limit_mb: 768, node_mem_limit_mb: 2304, log_level: 4}')
LW=$(echo "$LWC" | b64)
"$SEEDCTL" apply yb-fast "$LW" 2>"$T/err" || { cat "$T/err"; fail "apply with a lightwallet"; }
c="$O/net/yb-fast/compose.yaml"; e="$O/net/yb-fast/node.env"; L="$D/yb-fast/lightwallet"
grep -qx 'YCASHD_INSIGHT=1' "$e" && grep -qx 'YCASHD_RPC_BIND=0.0.0.0' "$e" && grep -qx 'YCASHD_RPC_ALLOWIP=172.31.252.12' "$e" && ! grep -q zmqpub "$e" && grep -q -- '-loadblock=' "$e" && grep -q -- '-disablewallet' "$e" || fail "the node while importing: indexes, RPC for lightwalletd's address only, no wallet: $(cat "$e")"
! grep -q 'network_mode: host' "$c" && grep -q 'ipv4_address: "172.31.252.11"' "$c" && grep -q 'container_name: grpcweb-yb-fast' "$c" && grep -q 'container_name: lwproxy-yb-fast' "$c" && ! grep -q 'container_name: lightwalletd-yb-fast' "$c" && grep -q 'mem_limit: 2304m' "$c" && grep -q 'memswap_limit: 4352m' "$c" || fail "while importing: node and the two proxies, no lightwalletd: $(cat "$c")"
grep -qF 'ports: ["80:80", "443:443"]' "$c" && [ "$(grep -c 'ports:' "$c")" = 1 ] && [ "$(awk '/^  [a-z]+:$/ { s = $1 } /ports:/ { print s }' "$c")" = "lwproxy:" ] || fail "only the TLS proxy publishes ports, 80 and 443"
grep -qx 'lightwallet.example.org {' "$O/net/yb-fast/Caddyfile" && grep -qx '	email ops@example.org' "$O/net/yb-fast/Caddyfile" && grep -q 'reverse_proxy h2c://172.31.252.13:8080 {' "$O/net/yb-fast/Caddyfile" && grep -q 'header_up X-Real-IP {remote_host}' "$O/net/yb-fast/Caddyfile" && grep -q 'protocols h1 h2$' "$O/net/yb-fast/Caddyfile" || fail "the Caddyfile: the name, the contact, h2c to the gRPC-web proxy, the client's address"
grep -q 'allow_origin_string_match: \[{"safe_regex":{"regex":".\*"}}\]' "$O/net/yb-fast/envoy.yaml" && grep -q 'address: 172.31.252.12, port_value: 9067' "$O/net/yb-fast/envoy.yaml" && grep -q 'prefix: "/cash.z.wallet.sdk.rpc.YellowbackStreamer/"' "$O/net/yb-fast/envoy.yaml" && grep -q 'direct_response: { status: 404 }' "$O/net/yb-fast/envoy.yaml" && ! grep -q 'admin' "$O/net/yb-fast/envoy.yaml" || fail "envoy.yaml: any origin, lightwalletd's two services only, no admin"
pw=$(sed -n 's/^YCASHD_RPC_PASSWORD=//p' "$D/yb-fast/rpc.env")
[ "$(stat -c %a "$L/lightwalletd.conf")" = 400 ] && grep -qx "rpcpassword=$pw" "$L/lightwalletd.conf" && grep -qx 'rpcbind=172.31.252.11' "$L/lightwalletd.conf" && grep -qx 'rpcport=18832' "$L/lightwalletd.conf" && ! grep -rqF -e "$pw" "$O/net/yb-fast" && [ "$(stat -c %a "$D/yb-fast/applied.json")" = 600 ] || fail "the node's credential only in lightwalletd's 0400 conf; the config (with the contact) root only"
grep -qx 'iptables -I DOCKER-USER 1 -s 172.31.252.0/23 -d 169.254.169.254/32 -j REJECT' "$LOG" || fail "the lightwallet's networks are refused the metadata service"
s=$(FAKE_HEIGHT=255123 "$SEEDCTL" status yb-fast)
[ "$(echo "$s" | jq -r .lightwallet.phase)" = "prefix import: 255123 of 510247 (49 %)" ] && [ "$(echo "$s" | jq -c '[.lightwallet.restarts, .lightwallet.nodeOomKills]')" = '[{"ycashd":0,"lightwalletd":0,"grpcweb":0,"lwproxy":0},{"cgroup":0,"host":0}]' ] || fail "status during the import: $s"
ok "a lightwallet while the prefix imports: node on its networks, the two proxies, credential private; status in percent"
"$SEEDCTL" prefix-check 2>/dev/null
grep -q 'container_name: lightwalletd-yb-fast' "$c" && grep -q 'LWD_TRUSTED_PROXY_CIDRS: "172.31.252.13/32"' "$c" && grep -q 'LWD_YELLOWBACK: "1"' "$c" && grep -q 'LWD_INSECURE: "1"' "$c" && grep -q 'user: "2002:2002"' "$c" && grep -q 'ipv4_address: "172.31.252.12"' "$c" && grep -qF "$L/lightwalletd.conf:/etc/lightwalletd/ycash.conf:ro" "$c" && grep -q 'mem_limit: 768m' "$c" && grep -q 'depends_on: { lightwalletd: { condition: service_started } }' "$c" && ! grep -q loadblock "$e" || fail "lightwalletd after the import: $(cat "$c")"
s=$(FAKE_HEIGHT=600000 "$SEEDCTL" status yb-fast)
[ "$(echo "$s" | jq -c '[.lightwallet.phase, .lightwallet.height, .lightwallet.getLightdInfo.chainName, .lightwallet.getLightdInfo.consensusBranchId, .lightwallet.grpcOnHost, .lightwallet.grpcWebOnHost, .lightwallet.grpcPublic, .lightwallet.grpcWebPublic, .lightwallet.url, .lightwallet.grpc, .lightwallet.lightwalletd]')" = '["serving",600000,"test","6d5b7a31","0","0","0","0","https://lightwallet.example.org","lightwallet.example.org:443","healthy"]' ] || fail "status serving: $s"
grep -q -- "--resolve lightwallet.example.org:443:127.0.0.1 .*--http2 .*https://lightwallet.example.org/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLightdInfo" "$LOG" && grep -q -- "--http1.1 -H content-type: application/grpc-web+proto" "$LOG" || fail "the probes: native gRPC over HTTP/2 and gRPC-web, on this host for the name"
[ "$(FAKE_LWD_HEIGHT=599000 "$SEEDCTL" status yb-fast | jq -r .lightwallet.phase)" = "lightwalletd is catching up: 599000 of 600000" ] || fail "status while lightwalletd catches up"
[ "$(FAKE_LWD_DOWN=1 "$SEEDCTL" status yb-fast | jq -c '[.lightwallet.phase, .lightwallet.getLightdInfo, .lightwallet.height]')" = '["lightwalletd is starting (no GetLightdInfo yet)",null,null]' ] || fail "status before lightwalletd answers"
[ "$(FAKE_LW=starting "$SEEDCTL" status yb-fast | jq -c '[.lightwallet.phase, .lightwallet.grpcOnHost, .lightwallet.grpcWebPublic]')" = '["starting (the TLS proxy answers gRPC http 503, gRPC-web http 503 on this host)","http 503","http 503"]' ] || fail "status with the proxy not through"
[ "$(FAKE_LW=down "$SEEDCTL" status yb-fast | jq -r .lightwallet.grpcPublic)" = none ] || fail "status without a connection"
ok "after the import: lightwalletd at its fixed address, trusting the gRPC-web proxy only; status reports GetLightdInfo, the height and the four probes"
mkdir -p "$L/cache/db" && touch "$L/cache/db/blocks" "$L/caddy/data/cert"
"$SEEDCTL" reset yb-fast "$LW" 2>/dev/null
[ ! -e "$L/cache/db/blocks" ] && [ -e "$L/caddy/data/cert" ] && [ -e "$L/lightwalletd.conf" ] && grep -q 'docker rm -f .* lightwalletd-yb-fast grpcweb-yb-fast lwproxy-yb-fast' "$LOG" || fail "reset: the block cache goes with the chain; the certificate stays"
ok "reset: lightwalletd's cache goes with the chain, the certificate stays"
PLAIN=$(echo "$LWC" | jq -c '.lightwallet.tls = false | .lightwallet.grpcweb_origins = ["https://wallet.example.org", "http://localhost:5173"]' | b64)
"$SEEDCTL" apply yb-fast "$PLAIN" 2>/dev/null || fail "apply plain HTTP"
grep -qx ':80 {' "$O/net/yb-fast/Caddyfile" && grep -q 'protocols h1 h2c$' "$O/net/yb-fast/Caddyfile" && grep -qF 'ports: ["80:80"]' "$c" && grep -qF 'allow_origin_string_match: [{"exact":"https://wallet.example.org"},{"exact":"http://localhost:5173"}]' "$O/net/yb-fast/envoy.yaml" || fail "plain HTTP: port 80 with h2c; the origins exactly"
: > "$LOG"; "$SEEDCTL" status yb-fast >/dev/null
grep -q -- "--http2-prior-knowledge .*http://127.0.0.1/cash.z" "$LOG" || fail "plain HTTP: the native probe is h2c on this host"
ok "plain HTTP (no name): port 80, h2c for native gRPC; CORS for the listed origins only"
for bad in '.lightwallet.grpcweb_origins = ["https://x.example.org/path"]' '.lightwallet.grpcweb_origins = []' '.lightwallet.image = "ghcr.io/example/lightwalletd:latest"' \
           '.lightwallet.hostname = "x\nemail evil"' '.lightwallet.log_level = 7' '.insight = false' '.lightwallet.mem_limit_mb = 100' \
           '.explorer = {"hostname": "explorer.example.org"}' '.network = "mainnet"'; do
  BADL=$(echo "$LWC" | jq -c "$bad" | b64)
  if "$SEEDCTL" apply yb-fast "$BADL" 2>/dev/null; then fail "a lightwallet accepted $bad"; fi
done
ok "refuses a lightwallet with a bad origin, a tag, a bad name or level, no indexes, a small limit, an explorer beside it, on mainnet"
: > "$LOG"
"$SEEDCTL" apply yb-fast "$FAST" 2>/dev/null
grep -q 'network_mode: host' "$c" && ! grep -q lwproxy "$c" && grep -q 'docker rm -f lightwalletd-yb-fast grpcweb-yb-fast lwproxy-yb-fast' "$LOG" && [ "$("$SEEDCTL" status yb-fast | jq 'has("lightwallet")')" = false ] || fail "a lightwallet removed from the config"
ok "a lightwallet removed from the config is removed from the host"
# 13. a host without the prefix tools (an instance made by this module revision, its root without
#     the host_files output): an empty datadir refuses at once, nothing is fetched
rm -f "$O/prefix-restore.sh"; rm -rf "$D/yb-slow" "$D/prefix-cache"; : > "$LOG"
if "$SEEDCTL" apply yb-slow "$SLOW" 2>"$T/err"; then fail "applied without the prefix tools"; fi
grep -q 'prefix-restore.sh is missing: the prefix tools come with the module.s host_files output' "$T/err" && ! grep -q '^restore ' "$LOG" || fail "no prefix tools: $(cat "$T/err")"
ok "no prefix tools on the host: refused at once, with the reason"
echo "seedctl: all checks passed"
