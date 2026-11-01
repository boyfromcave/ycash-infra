#!/bin/bash
# Offline: images/miner/entrypoint.sh with a stand-in lolMiner (no GPU, no network). Checks that it
# refuses to start without a pool or with credentials in it, builds the Equihash 192,7 / ZcashPoW
# command, pays the username the way yolo expects, rejects pool and password options in MINER_ARGS,
# and restarts lolMiner only on its watchdog exit code 42.
# Run: images/miner/tests/entrypoint-test.sh   (make miner-test, CI)
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/lolMiner" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
n=$(wc -l < "$FAKE_LOG")
if [ "$n" -le "${FAKE_FAILS:-0}" ]; then exit 42; fi
exit "${FAKE_RC:-0}"
EOF
chmod +x "$T/lolMiner"
export LOLMINER="$T/lolMiner" FAKE_LOG="$T/calls" RESTART_DELAY=0
fail() { echo "FAIL: $*" >&2; cat "$T/out" >&2 || true; exit 1; }
run() { : > "$T/calls"; rc=0; env -u POOL_URL -u WORKER -u PAYOUT -u MINER_ARGS -u MINER_DRY_RUN "$@" ./entrypoint.sh > "$T/out" 2>&1 || rc=$?; }

run
if ! { [ "$rc" = 64 ] && grep -q 'POOL_URL is not set' "$T/out" && [ ! -s "$T/calls" ]; }; then fail "no pool: refuses"; fi
run POOL_URL=stratum+tcp://u:secretpass@pool.example:3333
if ! { [ "$rc" = 64 ] && ! grep -q secretpass "$T/out"; }; then fail "credentials in the pool URL: refused, not echoed"; fi
run POOL_URL=pool.example
[ "$rc" = 64 ] || fail "a pool without a port"
run POOL_URL=pool.example:70000
[ "$rc" = 64 ] || fail "a port out of range"
run POOL_URL=https://pool.example:3333
[ "$rc" = 64 ] || fail "only stratum+tcp"
run POOL_URL=pool.example:3333 WORKER='a b'
[ "$rc" = 64 ] || fail "a worker name with a space"
run POOL_URL=pool.example:3333 PAYOUT='not-an-address!'
[ "$rc" = 64 ] || fail "a malformed payout address"
for bad in '--pass x' '--user=someone' '-p other.example:1' '--watchdogscript /tmp/x' '--apiport 4444' '--pers ZERO_PoW'; do
  run POOL_URL=pool.example:3333 MINER_ARGS="$bad"
  if ! { [ "$rc" = 64 ] && [ ! -s "$T/calls" ]; }; then fail "MINER_ARGS '$bad' refused"; fi
done
run POOL_URL=pool.example:3333 MINER_ARGS='--devices 0;rm'
[ "$rc" = 64 ] || fail "MINER_ARGS with a shell character"
echo "ok - refuses: no pool, credentials, bad port/scheme/worker/payout, pool or password options in MINER_ARGS"

run POOL_URL=stratum+tcp://pool.example:3333 WORKER=vast-fast-0
[ "$rc" = 0 ] || fail "starts"
grep -qx -- '--algo EQUI192_7 --pers ZcashPoW --pool pool.example:3333 --user vast-fast-0 --tls off --dns-over-https 0 --apiport 0 --watchdog exit --nocolor --timeprint on' "$T/calls" || fail "the 192,7 / ZcashPoW command, worker as username"
! grep -q -- '--pass' "$T/calls" || fail "no password option"
if ! { grep -q "paid to the pool's own address" "$T/out" && grep -q '1% developer fee' "$T/out"; }; then fail "says who is paid and the fee"; fi
addr=tmAbCdEfGhJkLmNpQrStUvWxYz123456789
run POOL_URL=pool.example:3333 WORKER=vast-slow-1 PAYOUT=$addr MINER_ARGS='--devices 0 --keepfree=64'
if ! { [ "$rc" = 0 ] && grep -q -- "--user $addr --tls off .* --devices 0 --keepfree=64\$" "$T/calls"; }; then fail "payout as username, extra args appended"; fi
echo "ok - the command: EQUI192_7, ZcashPoW, no TLS, no DoH, no API port; username = PAYOUT or WORKER"

run POOL_URL=pool.example:3333 MINER_DRY_RUN=1
if ! { [ "$rc" = 0 ] && [ ! -s "$T/calls" ] && grep -q 'EQUI192_7' "$T/out"; }; then fail "dry run prints and does not start"; fi
run POOL_URL=pool.example:3333 FAKE_FAILS=2
if ! { [ "$rc" = 0 ] && [ "$(wc -l < "$T/calls")" = 3 ]; }; then fail "restarts after exit 42"; fi
run POOL_URL=pool.example:3333 FAKE_RC=3
if ! { [ "$rc" = 3 ] && [ "$(wc -l < "$T/calls")" = 1 ]; }; then fail "another exit code ends the container"; fi
echo "ok - dry run; restarts only on the watchdog's 42"
echo "entrypoint-test: all checks passed"
