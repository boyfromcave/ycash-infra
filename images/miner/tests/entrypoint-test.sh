#!/bin/bash
# Offline: images/miner/entrypoint.sh with a stand-in curl and stand-in miners (no GPU, no network).
# Checks that the miner is downloaded at start and runs only when its SHA-256 matches the pin, that
# a mismatch or a failed download refuses with a clear error and runs nothing, that a verified
# download is reused, that MINER=miniz is refused until it is pinned, that it refuses to start
# without a pool or with credentials in it, builds the Equihash 192,7 / ZcashPoW command for both
# miners, pays the username the way yolo expects, rejects pool and password options in MINER_ARGS,
# and restarts lolMiner only on its watchdog exit code 42.
# Run: images/miner/tests/entrypoint-test.sh   (make miners-test, CI)
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/files" "$T/pkg/1.98a" "$T/pkgz"

# stand-in miners: log their arguments; lolMiner exits 42 for the first FAKE_FAILS calls
cat > "$T/pkg/1.98a/lolMiner" <<'EOF'
#!/bin/bash
echo "lolMiner $*" >> "$FAKE_LOG"
n=$(wc -l < "$FAKE_LOG")
if [ "$n" -le "${FAKE_FAILS:-0}" ]; then exit 42; fi
exit "${FAKE_RC:-0}"
EOF
cat > "$T/pkgz/miniZ" <<'EOF'
#!/bin/bash
echo "miniZ $*" >> "$FAKE_LOG"
EOF
chmod +x "$T/pkg/1.98a/lolMiner" "$T/pkgz/miniZ"
tar -czf "$T/files/lol.tar.gz" -C "$T/pkg" 1.98a
tar -czf "$T/files/miniz.tar.gz" -C "$T/pkgz" miniZ
printf 'something else' > "$T/files/evil.tar.gz"
LOLSHA=$(sha256sum < "$T/files/lol.tar.gz" | cut -d' ' -f1)
MZSHA=$(sha256sum < "$T/files/miniz.tar.gz" | cut -d' ' -f1)

# stand-in curl: "downloads" https://…/<name> from $T/files/<name>; FAKE_NET=down fails like no network
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
out=; prev=
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
url=${*: -1}
echo "$url" >> "$FAKE_DL"
if [ "${FAKE_NET:-up}" = down ]; then echo "curl: (6) Could not resolve host" >&2; exit 6; fi
cp "$FAKE_FILES/${url##*/}" "$out"
EOF
chmod +x "$T/bin/curl"
cat > "$T/manifest" <<EOF
LOLMINER_VERSION=1.98a
LOLMINER_URL=https://releases.example/lol.tar.gz
LOLMINER_SHA256=$LOLSHA
MINIZ_URL=
MINIZ_SHA256=
EOF
export PATH="$T/bin:$PATH" FAKE_LOG="$T/calls" FAKE_DL="$T/downloads" FAKE_FILES="$T/files" \
  MINER_MANIFEST="$T/manifest" RESTART_DELAY=0
fail() { echo "FAIL: $*" >&2; cat "$T/out" >&2 || true; exit 1; }
fresh() { rm -rf "$T/cache"; }
run() { : > "$T/calls"; : > "$T/downloads"; rc=0
  env -u POOL_URL -u WORKER -u PAYOUT -u MINER_ARGS -u MINER_DRY_RUN -u MINER -u MINIZ_URL -u MINIZ_SHA256 \
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
if ! { [ "$rc" = 0 ] && grep -qx -- 'miniZ --url=vast-slow-1@pool.example:3333 --par=192,7 --pers=ZcashPoW' "$T/calls"; }; then fail "miniZ, pinned: --url=<worker>@<pool> --par=192,7 --pers=ZcashPoW"; fi
echo "ok - username = PAYOUT or WORKER; miniZ once pinned runs with --par=192,7 --pers=ZcashPoW"

run POOL_URL=pool.example:3333 MINER_DRY_RUN=1
if ! { [ "$rc" = 0 ] && [ ! -s "$T/calls" ] && [ ! -s "$T/downloads" ] && grep -q 'EQUI192_7' "$T/out"; }; then fail "dry run: no download, nothing run"; fi
run POOL_URL=pool.example:3333 FAKE_FAILS=2
if ! { [ "$rc" = 0 ] && [ "$(wc -l < "$T/calls")" = 3 ]; }; then fail "restarts after exit 42"; fi
run POOL_URL=pool.example:3333 FAKE_RC=3
if ! { [ "$rc" = 3 ] && [ "$(wc -l < "$T/calls")" = 1 ]; }; then fail "another exit code ends the container"; fi
echo "ok - dry run; restarts only on lolMiner's watchdog 42"
echo "entrypoint-test: all checks passed"
