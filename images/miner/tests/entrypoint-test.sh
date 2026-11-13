#!/bin/bash
# Offline: images/miner/entrypoint.sh with a stand-in curl and stand-in miners (no GPU, no network).
# Checks that the miner is downloaded at start and runs only when its SHA-256 matches the pin, that
# a mismatch or a failed download refuses with a clear error and runs nothing, that a verified
# download is reused, that MINER=miniz is refused until it is pinned, that it refuses to start
# without a pool or with credentials in it, builds the Equihash 192,7 / ZcashPoW command for both
# miners, pays the username the way yolo expects, rejects pool and password options in MINER_ARGS,
# restarts lolMiner only on its watchdog exit code 42 and miniZ on any failure; that miniZ is fetched
# from a query URL (miniz.cc's download link), its archive found by content and its binary checked
# against the checksum file inside; that it prints what GPUs, driver libraries, OpenCL platforms and
# miner devices it sees and where the pool resolves, and exits 70 without mining when lolMiner has no
# OpenCL GPU (GPU bursts 1 and 2) or miniZ cannot load CUDA; that a card lolMiner lists as
# "Drivers: Cuda, OpenCL" counts as usable; and that a burst miner (MINER_UNTIL) stops at its end and
# ends its own rental with Vast's per-instance key (destroy, else stop), never printing that key.
# Run: images/miner/tests/entrypoint-test.sh   (make miners-test, CI)
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/files" "$T/pkg/1.98a" "$T/pkgz"

# stand-in miners: log their arguments; lolMiner exits 42 for the first FAKE_FAILS calls, mines for
# FAKE_SLEEP seconds, and lists FAKE_OCL OpenCL GPUs (none: no OpenCL at all) for --list-devices
cat > "$T/pkg/1.98a/lolMiner" <<'EOF'
#!/bin/bash
if [ "$1" = --list-devices ]; then
  if [ -n "${FAKE_OCL_ONCE:-}" ] && [ ! -e "$FAKE_LOG.listed" ]; then
    touch "$FAKE_LOG.listed"; echo "OpenCL driver detected. Number of OpenCL supported GPUs: $FAKE_OCL_ONCE"; exit 0
  fi
  if [ "${FAKE_OCL:-1}" = none ]; then echo "No OpenCL driver or GPUs detected."; else
    echo "OpenCL driver detected. Number of OpenCL supported GPUs: ${FAKE_OCL:-1}"; fi
  [ -z "${FAKE_DRIVERS:-}" ] || printf 'Device 0:\n    Drivers: %s\n' "$FAKE_DRIVERS"
  exit 0
fi
echo "lolMiner $*" >> "$FAKE_LOG"
[ -z "${CONTAINER_API_KEY:-}${CONTAINER_ID:-}" ] || echo "lolMiner saw the per-instance key" >> "$FAKE_LOG.key"
[ -z "${FAKE_SLEEP:-}" ] || sleep "$FAKE_SLEEP"
n=$(wc -l < "$FAKE_LOG")
if [ "$n" -le "${FAKE_FAILS:-0}" ]; then exit 42; fi
exit "${FAKE_RC:-0}"
EOF
cat > "$T/pkgz/miniZ" <<'EOF'
#!/bin/bash
if [ "$1" = --cuda-info ]; then
  if [ "${FAKE_SMI:-1}" = 0 ]; then echo 'dlopen "libcuda.so.1" failed!'; else echo "GPU 0: NVIDIA GeForce RTX 3060"; fi
  exit 0
fi
echo "miniZ $*" >> "$FAKE_LOG"
n=$(wc -l < "$FAKE_LOG")
if [ "$n" -le "${FAKE_FAILS:-0}" ]; then exit 1; fi
exit 0
EOF
chmod +x "$T/pkg/1.98a/lolMiner" "$T/pkgz/miniZ"
echo "SHA256 (miniZ) = $(sha256sum < "$T/pkgz/miniZ" | cut -d' ' -f1)" > "$T/pkgz/miniZ.sha256sum"
tar -czf "$T/files/lol.tar.gz" -C "$T/pkg" 1.98a
tar -czf "$T/files/miniz.tar.gz" -C "$T/pkgz" miniZ miniZ.sha256sum
# miniz.cc's download link is a query URL with no file name; the stand-in curl serves its last path part
cp "$T/files/miniz.tar.gz" "$T/files/?sdm_process_download=1&download_id=5200"
echo "SHA256 (miniZ) = $(printf '0%.0s' $(seq 64))" > "$T/pkgz/miniZ.sha256sum"
tar -czf "$T/files/miniz-badsum.tar.gz" -C "$T/pkgz" miniZ miniZ.sha256sum
printf 'something else' > "$T/files/evil.tar.gz"
LOLSHA=$(sha256sum < "$T/files/lol.tar.gz" | cut -d' ' -f1)
MZSHA=$(sha256sum < "$T/files/miniz.tar.gz" | cut -d' ' -f1)
MZBAD=$(sha256sum < "$T/files/miniz-badsum.tar.gz" | cut -d' ' -f1)

# stand-in curl: "downloads" https://…/<name> from $T/files/<name>; FAKE_NET=down fails like no network.
# A Vast API call (-X METHOD, the key in a config on stdin) is logged to $FAKE_API as "METHOD URL key=<k>"
# and fails when FAKE_API_FAIL names its method.
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
method=; prev=
for a in "$@"; do [ "$prev" = -X ] && method=$a; prev=$a; done
if [ -n "$method" ]; then
  key=$(sed -n 's/^header = "Authorization: Bearer \(.*\)"$/\1/p')
  echo "$method ${*: -1} key=$key" >> "$FAKE_API"
  case " ${FAKE_API_FAIL:-} " in *" $method "*) exit 22 ;; esac
  exit 0
fi
out=; prev=
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
url=${*: -1}
echo "$url" >> "$FAKE_DL"
if [ "${FAKE_NET:-up}" = down ]; then echo "curl: (6) Could not resolve host" >&2; exit 6; fi
cp "$FAKE_FILES/${url##*/}" "$out"
EOF
# stand-in nvidia-smi (FAKE_SMI=0: no GPU) and getent (FAKE_DNS=<address>, else the name does not resolve)
cat > "$T/bin/nvidia-smi" <<'EOF'
#!/bin/bash
if [ "${FAKE_SMI:-1}" = 0 ]; then echo "No devices were found"; exit 6; fi
case "$*" in *--query-gpu=driver_version*) echo 550.54.15; exit 0 ;; esac
echo "GPU 0: NVIDIA GeForce RTX 3060 (UUID: GPU-00000000-1111-2222-3333-444444444444)"
EOF
cat > "$T/bin/getent" <<'EOF'
#!/bin/bash
[ -n "${FAKE_DNS:-}" ] || exit 2
echo "$FAKE_DNS STREAM $3"
EOF
chmod +x "$T/bin/curl" "$T/bin/nvidia-smi" "$T/bin/getent"
cat > "$T/manifest" <<EOF
LOLMINER_VERSION=1.98a
LOLMINER_URL=https://releases.example/lol.tar.gz
LOLMINER_SHA256=$LOLSHA
MINIZ_URL=
MINIZ_SHA256=
EOF
export PATH="$T/bin:$PATH" FAKE_LOG="$T/calls" FAKE_DL="$T/downloads" FAKE_FILES="$T/files" \
  FAKE_API="$T/api" MINER_MANIFEST="$T/manifest" RESTART_DELAY=0
fail() { echo "FAIL: $*" >&2; cat "$T/out" >&2 || true; exit 1; }
fresh() { rm -rf "$T/cache"; }
run() { : > "$T/calls"; : > "$T/downloads"; : > "$T/api"; rm -f "$T/calls.listed"; rc=0
  env -u POOL_URL -u WORKER -u PAYOUT -u MINER_ARGS -u MINER_DRY_RUN -u MINER -u MINIZ_URL -u MINIZ_SHA256 \
    -u MINER_UNTIL -u MINER_DIAG -u CONTAINER_ID -u CONTAINER_API_KEY -u NO_GPU_GRACE -u VAST_RETRY_DELAY \
    MINER_CACHE="$T/cache" "$@" ./entrypoint.sh > "$T/out" 2>&1 || rc=$?; }

# ---- configuration refusals (nothing downloaded) -------------------------------------------------
run
if ! { [ "$rc" = 64 ] && grep -q 'POOL_URL is not set' "$T/out" && [ ! -s "$T/downloads" ]; }; then fail "no pool: refuses"; fi
run POOL_URL=stratum+tcp://u:secretpass@pool.example:3333
if ! { [ "$rc" = 64 ] && ! grep -q secretpass "$T/out"; }; then fail "credentials in the pool URL: refused, not echoed"; fi
for bad in pool.example pool.example:70000 https://pool.example:3333; do
  run POOL_URL=$bad
  [ "$rc" = 64 ] || fail "POOL_URL $bad refused"
done
run POOL_URL=pool.example:3333 WORKER='a b'
[ "$rc" = 64 ] || fail "a worker name with a space"
run POOL_URL=pool.example:3333 PAYOUT='not-an-address!'
[ "$rc" = 64 ] || fail "a malformed payout address"
for bad in '--pass x' '--user=someone' '-p other.example:1' '--watchdogscript /tmp/x' '--apiport 4444' '--pers ZERO_PoW' '--url=x@y:1' '--par=200,9'; do
  run POOL_URL=pool.example:3333 MINER_ARGS="$bad"
  if ! { [ "$rc" = 64 ] && [ ! -s "$T/calls" ]; }; then fail "MINER_ARGS '$bad' refused"; fi
done
run POOL_URL=pool.example:3333 MINER_ARGS='--devices 0;rm'
[ "$rc" = 64 ] || fail "MINER_ARGS with a shell character"
run POOL_URL=pool.example:3333 MINER=xmrig
[ "$rc" = 64 ] || fail "an unknown miner"
echo "ok - refuses: no pool, credentials, bad port/scheme/worker/payout/miner, pool or password options in MINER_ARGS"

# ---- miniZ is off until pinned --------------------------------------------------------------------
run POOL_URL=pool.example:3333 MINER=miniz
if ! { [ "$rc" = 64 ] && grep -q 'MINER=miniz is off' "$T/out" && [ ! -s "$T/downloads" ]; }; then fail "miniz without pins refused"; fi
run POOL_URL=pool.example:3333 MINER=miniz MINIZ_URL=https://releases.example/miniz.tar.gz
[ "$rc" = 64 ] || fail "miniz with a URL but no SHA-256 refused"
run POOL_URL=pool.example:3333 MINER=miniz MINIZ_URL=http://releases.example/miniz.tar.gz MINIZ_SHA256="$MZSHA"
if ! { [ "$rc" = 64 ] && grep -q 'https://' "$T/out"; }; then fail "a plain http download refused"; fi
echo "ok - miniZ: refused without both pins, and over plain http"

# ---- download, check, run --------------------------------------------------------------------------
fresh
run POOL_URL=stratum+tcp://pool.example:3333 WORKER=vast-fast-0
[ "$rc" = 0 ] || fail "lolMiner: downloaded, verified, started"
if ! grep -qx 'https://releases.example/lol.tar.gz' "$T/downloads"; then fail "downloaded from the pinned URL"; fi
grep -qx -- 'lolMiner --algo EQUI192_7 --pers ZcashPoW --pool pool.example:3333 --user vast-fast-0 --tls off --dns-over-https 0 --apiport 0 --watchdog exit --nocolor --timeprint on' "$T/calls" || fail "the 192,7 / ZcashPoW command, worker as username"
if grep -q -- '--pass' "$T/calls"; then fail "no password option"; fi
run POOL_URL=pool.example:3333 WORKER=vast-fast-0
if ! { [ "$rc" = 0 ] && [ ! -s "$T/downloads" ] && grep -q 'using the verified download' "$T/out"; }; then fail "a verified download is reused"; fi
printf 'x' >> "$T/cache/lolminer-$LOLSHA/download"
run POOL_URL=pool.example:3333
if ! { [ "$rc" = 0 ] && [ -s "$T/downloads" ]; }; then fail "a tampered cache is downloaded again"; fi
echo "ok - lolMiner: downloaded from the pin, SHA-256 checked, run with EQUI192_7 / ZcashPoW; cache reused, re-checked"

fresh
sed -i "s/^LOLMINER_SHA256=.*/LOLMINER_SHA256=$(printf '0%.0s' $(seq 64))/" "$T/manifest"
run POOL_URL=pool.example:3333
if ! { [ "$rc" = 65 ] && grep -q 'SHA-256 mismatch' "$T/out" && [ ! -s "$T/calls" ] && [ ! -e "$T/cache/lolminer-$(printf '0%.0s' $(seq 64))" ]; }; then fail "a checksum mismatch refuses and runs nothing"; fi
sed -i "s/^LOLMINER_SHA256=.*/LOLMINER_SHA256=$LOLSHA/; s#^LOLMINER_URL=.*#LOLMINER_URL=https://releases.example/evil.tar.gz#" "$T/manifest"
run POOL_URL=pool.example:3333
if ! { [ "$rc" = 65 ] && [ ! -s "$T/calls" ]; }; then fail "another file at the URL refuses"; fi
sed -i "s#^LOLMINER_URL=.*#LOLMINER_URL=https://releases.example/lol.tar.gz#" "$T/manifest"
run POOL_URL=pool.example:3333 FAKE_NET=down
if ! { [ "$rc" = 69 ] && grep -q 'could not download' "$T/out" && grep -q 'nothing was run' "$T/out" && [ ! -s "$T/calls" ]; }; then fail "no network: a clear error, nothing run"; fi
echo "ok - refuses on a SHA-256 mismatch (65) and when the download fails (69); nothing runs"

fresh
addr=tmAbCdEfGhJkLmNpQrStUvWxYz123456789
run POOL_URL=pool.example:3333 WORKER=vast-slow-1 PAYOUT=$addr MINER_ARGS='--devices 0 --keepfree=64'
if ! { [ "$rc" = 0 ] && grep -q -- "--user $addr --tls off .* --devices 0 --keepfree=64\$" "$T/calls"; }; then fail "payout as username, extra args appended"; fi
run POOL_URL=pool.example:3333 MINER=miniz MINIZ_URL=https://releases.example/miniz.tar.gz MINIZ_SHA256="$MZSHA" WORKER=vast-slow-1
if ! { [ "$rc" = 0 ] && grep -qx -- 'miniZ --url=vast-slow-1@pool.example:3333 --par=192,7 --pers=ZcashPoW --telemetry=0 --nocolour' "$T/calls"; }; then fail "miniZ, pinned: --url=<worker>@<pool> --par=192,7 --pers=ZcashPoW --telemetry=0"; fi
grep -q 'miniZ --cuda-info: GPU 0' "$T/out" || fail "miniZ lists its CUDA devices before mining"
fresh
run POOL_URL=pool.example:3333 MINER=miniz MINIZ_URL='https://miniz.example/?sdm_process_download=1&download_id=5200' MINIZ_SHA256="$MZSHA" WORKER=vast-fast-0
if ! { [ "$rc" = 0 ] && grep -qx -- 'miniZ --url=vast-fast-0@pool.example:3333 --par=192,7 --pers=ZcashPoW --telemetry=0 --nocolour' "$T/calls"; }; then fail "miniZ from a query URL (miniz.cc's download link)"; fi
run POOL_URL=pool.example:3333 MINER=miniz MINIZ_URL='https://miniz.example/?x=1;rm' MINIZ_SHA256="$MZSHA"
[ "$rc" = 64 ] || fail "a download URL with a shell character refused"
fresh
run POOL_URL=pool.example:3333 MINER=miniz MINIZ_URL=https://releases.example/miniz-badsum.tar.gz MINIZ_SHA256="$MZBAD"
if ! { [ "$rc" = 65 ] && grep -q 'does not match the checksum file' "$T/out" && [ ! -s "$T/calls" ]; }; then fail "miniZ's own checksum file is checked"; fi
fresh
run POOL_URL=pool.example:3333 MINER=miniz MINIZ_URL=https://releases.example/miniz.tar.gz MINIZ_SHA256="$MZSHA" FAKE_FAILS=2
if ! { [ "$rc" = 0 ] && [ "$(wc -l < "$T/calls")" = 3 ]; }; then fail "miniZ restarts after a failure"; fi
for m in '--url2=x@y:1' '--read-config' '--donate=5'; do
  run POOL_URL=pool.example:3333 MINER=miniz MINIZ_URL=https://releases.example/miniz.tar.gz MINIZ_SHA256="$MZSHA" MINER_ARGS="$m"
  [ "$rc" = 64 ] || fail "MINER_ARGS '$m' refused for miniZ"
done
echo "ok - username = PAYOUT or WORKER; miniZ once pinned: query URL, its own checksum file, --par=192,7 --pers=ZcashPoW --telemetry=0, restarts"

run POOL_URL=pool.example:3333 MINER_DRY_RUN=1
if ! { [ "$rc" = 0 ] && [ ! -s "$T/calls" ] && [ ! -s "$T/downloads" ] && grep -q 'EQUI192_7' "$T/out"; }; then fail "dry run: no download, nothing run"; fi
run POOL_URL=pool.example:3333 FAKE_FAILS=2
if ! { [ "$rc" = 0 ] && [ "$(wc -l < "$T/calls")" = 3 ]; }; then fail "restarts after exit 42"; fi
run POOL_URL=pool.example:3333 FAKE_RC=3
if ! { [ "$rc" = 3 ] && [ "$(wc -l < "$T/calls")" = 1 ]; }; then fail "another exit code ends the container"; fi
echo "ok - dry run; restarts only on lolMiner's watchdog 42"

# ---- what it sees before mining; no GPU: exit 70, nothing mined ----------------------------------------
run POOL_URL=pool.example:3333 WORKER=vast-fast-0
for want in 'nvidia-smi: GPU 0: NVIDIA GeForce RTX 3060$' 'lolMiner --list-devices: OpenCL driver detected. Number of OpenCL supported GPUs: 1' \
            'pool pool.example:3333: the name does not resolve here' 'a usable GPU is there' 'NVIDIA_DRIVER_CAPABILITIES=' \
            'driver version: 550.54.15' 'driver libraries: libcuda.so.1=' 'libnvidia-gpucomp.so.550.54.15=' 'OCL_ICD_VENDORS='; do
  grep -q "$want" "$T/out" || fail "before mining it prints: $want"
done
if grep -q 'UUID' "$T/out"; then fail "GPU UUIDs are not printed"; fi
run POOL_URL=pool.example:3333 FAKE_OCL=none
if ! { [ "$rc" = 70 ] && grep -q 'No OpenCL driver or GPUs detected' "$T/out" && grep -q 'no usable GPU' "$T/out" && [ ! -s "$T/calls" ]; }; then fail "no OpenCL (GPU burst 1): exit 70, nothing mined"; fi
run POOL_URL=pool.example:3333 FAKE_OCL=0
if ! { [ "$rc" = 70 ] && grep -q 'miniZ (MINER=miniz) mines 192,7 with CUDA' "$T/out" && [ ! -s "$T/calls" ]; }; then fail "lolMiner, 0 OpenCL GPUs, Cuda only (GPU burst 2): exit 70"; fi
run POOL_URL=pool.example:3333 FAKE_OCL=0 FAKE_DRIVERS='Cuda, OpenCL'
if ! { [ "$rc" = 0 ] && [ -s "$T/calls" ]; }; then fail "a card listed as Drivers: Cuda, OpenCL is usable"; fi
run POOL_URL=pool.example:3333 FAKE_OCL=0 FAKE_SMI=0
if ! { [ "$rc" = 70 ] && [ ! -s "$T/calls" ]; }; then fail "no GPU at all: exit 70"; fi
run POOL_URL=pool.example:3333 MINER=miniz MINIZ_URL=https://releases.example/miniz.tar.gz MINIZ_SHA256="$MZSHA" FAKE_SMI=0
if ! { [ "$rc" = 70 ] && [ ! -s "$T/calls" ]; }; then fail "miniZ without a GPU: exit 70"; fi
run POOL_URL=pool.example:3333 MINER_DIAG=1
if ! { [ "$rc" = 0 ] && grep -q 'checks only' "$T/out" && [ ! -s "$T/calls" ]; }; then fail "MINER_DIAG=1: checks, no mining"; fi
run POOL_URL=pool.example:3333 MINER_DIAG=1 FAKE_DNS=127.0.0.1
if ! { grep -q 'resolves to 127.0.0.1' "$T/out" && grep -qE 'stratum port accepts|no TCP connection' "$T/out"; }; then fail "the pool's address and port are checked"; fi
echo "ok - prints GPUs, OpenCL and the pool before mining; no OpenCL GPU: exit 70, nothing mined; MINER_DIAG"

# ---- a burst miner ends its own rental ---------------------------------------------------------------
IKEY=$(printf 'k%.0s' $(seq 32))
now=$(date +%s)
run POOL_URL=pool.example:3333 MINER_UNTIL=soon
[ "$rc" = 64 ] || fail "MINER_UNTIL not a time"
run POOL_URL=pool.example:3333 MINER_UNTIL=$((now - 5)) CONTAINER_ID=4242 CONTAINER_API_KEY="$IKEY"
if ! { [ "$rc" = 0 ] && grep -q 'burst is over' "$T/out" && [ ! -s "$T/calls" ] && [ ! -s "$T/downloads" ] \
       && grep -qx "DELETE https://console.vast.ai/api/v0/instances/4242/ key=$IKEY" "$T/api"; }; then fail "a burst already over: destroys itself, mines nothing"; fi
if grep -q "$IKEY" "$T/out"; then fail "the per-instance key is never printed"; fi
run POOL_URL=pool.example:3333 MINER_UNTIL=$((now + 3)) CONTAINER_ID=4242 CONTAINER_API_KEY="$IKEY" FAKE_SLEEP=30 FAKE_API_FAIL=DELETE
if ! { [ "$rc" = 0 ] && [ "$(wc -l < "$T/calls")" = 1 ] && grep -q '^PUT ' "$T/api" && grep -q 'instance is stopped' "$T/out"; }; then fail "at its end: lolMiner stopped, destroy refused so stopped"; fi
if [ -e "$T/calls.key" ]; then fail "lolMiner runs without Vast's per-instance key in its environment"; fi
grep -q "per-instance key present: yes" "$T/out" || fail "whether the key is there is printed (yes/no only)"
run POOL_URL=pool.example:3333 MINER_UNTIL=$((now - 5))
if ! { [ "$rc" = 0 ] && grep -q 'no per-instance Vast key' "$T/out" && [ ! -s "$T/api" ]; }; then fail "no Vast key: just exits"; fi
run POOL_URL=pool.example:3333 FAKE_OCL=0 CONTAINER_ID=4242 CONTAINER_API_KEY="$IKEY" NO_GPU_GRACE=0
if ! { [ "$rc" = 70 ] && [ ! -s "$T/calls" ] && grep -qx "DELETE https://console.vast.ai/api/v0/instances/4242/ key=$IKEY" "$T/api"; }; then fail "no usable GPU with Vast's key: destroys its own instance (Vast restarts an exited container), exit 70"; fi
run POOL_URL=pool.example:3333 FAKE_OCL=0 CONTAINER_ID=4242 CONTAINER_API_KEY="$IKEY" NO_GPU_GRACE=0 VAST_RETRY_DELAY=0 FAKE_API_FAIL=DELETE
if ! { [ "$rc" = 70 ] && [ "$(grep -c '^DELETE ' "$T/api")" = 3 ] && grep -q '^PUT ' "$T/api" && grep -q 'instance is stopped' "$T/out"; }; then fail "no GPU, destroy refused: 3 tries, then stopped"; fi
run POOL_URL=pool.example:3333 FAKE_OCL=0 CONTAINER_ID=4242 CONTAINER_API_KEY="$IKEY" NO_GPU_GRACE=0 VAST_RETRY_DELAY=0 FAKE_API_FAIL="DELETE PUT"
if ! { [ "$rc" = 70 ] && grep -q 'refused both destroy and stop' "$T/out"; }; then fail "no GPU, destroy and stop refused: says so, exit 70"; fi
run POOL_URL=pool.example:3333 FAKE_OCL_ONCE=0 CONTAINER_ID=4242 CONTAINER_API_KEY="$IKEY" NO_GPU_GRACE=0
if ! { [ "$rc" = 0 ] && [ ! -s "$T/api" ] && [ -s "$T/calls" ] && grep -q 'checking the GPU again' "$T/out"; }; then fail "a GPU found on the second check: mines, rental kept"; fi
run POOL_URL=pool.example:3333 FAKE_OCL=0 CONTAINER_ID=4242 CONTAINER_API_KEY="$IKEY" NO_GPU_GRACE=0 MINER_DIAG=1
if ! { [ "$rc" = 70 ] && [ ! -s "$T/api" ]; }; then fail "MINER_DIAG never destroys"; fi
echo "ok - MINER_UNTIL: stops mining at the burst's end and destroys (else stops) its own instance; key never printed; no GPU: destroys itself after its grace"
echo "entrypoint-test: all checks passed"
