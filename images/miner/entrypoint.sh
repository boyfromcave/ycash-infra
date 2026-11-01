#!/bin/bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# ycash-miner: start lolMiner on Equihash 192,7 with Ycash's personalization against one stratum pool.
#
# In plain words: this is the start-up script inside the miner container. It reads where to mine
# (the pool), what to call this machine (the worker name) and, optionally, which address is paid,
# checks them, and starts the miner. It refuses to start without a pool, and it never accepts or
# prints a password, key or token: the container runs on rented machines that others can inspect.
#
# Environment:
#   POOL_URL    required. The stratum pool, host:port or stratum+tcp://host:port (no user:password@).
#   WORKER      the worker name (letters, digits, . _ -; default ycash-miner).
#   PAYOUT      optional, a transparent address. yolo pays the stratum username unless the pool runs
#               with --payout, so: PAYOUT set -> the username is PAYOUT (WORKER is only logged);
#               PAYOUT unset -> the username is WORKER (the pool must run with --payout).
#   MINER_ARGS  optional extra lolMiner options, space separated (no pool, user or password options).
#   MINER_DRY_RUN=1  print the command and exit (tests; no GPU needed).
#   LOLMINER    the lolMiner executable (default /opt/lolminer/lolMiner; tests point it at a stand-in).
#   RESTART_DELAY  seconds before a watchdog restart (default 10).
# lolMiner's own exit code 42 (a GPU hung, --watchdog exit) restarts it here, at most 20 times;
# any other exit ends the container, so the fleet reconcile replaces the machine.
set -euo pipefail

LOLMINER=${LOLMINER:-/opt/lolminer/lolMiner}
ALGO=EQUI192_7
PERS=ZcashPoW   # ycash6 src/crypto/equihash.cpp: "ZcashPoW" || le32(192) || le32(7); lolMiner appends N, K

die() { echo "ycash-miner: $*" >&2; exit 64; }

pool=${POOL_URL:-}
[ -n "$pool" ] || die "POOL_URL is not set (host:port of a stratum pool); refusing to start"
pool=${pool#stratum+tcp://}
case "$pool" in
  *@*) die "POOL_URL must not carry a user or password (user:password@host); give the pool as host:port" ;;
  *://*) die "POOL_URL: only stratum+tcp:// (plain stratum) or host:port" ;;
esac
[[ $pool =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})?:[0-9]{1,5}$ ]] || die "POOL_URL must be host:port"
port=${pool##*:}
(( 10#$port >= 1 && 10#$port <= 65535 )) || die "POOL_URL: port out of range"

worker=${WORKER:-ycash-miner}
[[ $worker =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "WORKER: 1 to 64 letters, digits, '.', '_' or '-'"

payout=${PAYOUT:-}
if [ -n "$payout" ]; then
  # base58 (no 0, O, I, l); Ycash transparent addresses are 35 characters
  [[ $payout =~ ^[1-9A-HJ-NP-Za-km-z]{26,40}$ ]] || die "PAYOUT is not a transparent address"
  user=$payout
else
  user=$worker
fi

extra=()
if [ -n "${MINER_ARGS:-}" ]; then
  read -r -a extra <<< "$MINER_ARGS"
  for a in "${extra[@]}"; do
    [[ $a =~ ^[A-Za-z0-9=,._:/*-]+$ ]] || die "MINER_ARGS: unexpected characters in '$a'"
    case "${a%%=*}" in
      -p|--pool|-u|--user|--pass|--dualpool|--dualuser|--dualpass|-a|--algo|--pers|-c|--coin|--config|--json|--profile|--watchdogscript|--apihost|--apiport|--tls|--socks5|--dns-over-https)
        die "MINER_ARGS: $a is set by this entrypoint or not allowed" ;;
    esac
  done
fi

cmd=("$LOLMINER" --algo "$ALGO" --pers "$PERS" --pool "$pool" --user "$user" --tls off
     --dns-over-https 0 --apiport 0 --watchdog exit --nocolor --timeprint on "${extra[@]}")

paid="the pool's own address (the pool runs with --payout)"
[ -z "$payout" ] || paid=$payout
echo "ycash-miner: lolMiner ${LOLMINER_VERSION:-?}, Equihash 192,7 (personalization $PERS), pool $pool, worker $worker, paid to $paid"
echo "ycash-miner: lolMiner keeps its 1% developer fee: about 1% of the time it mines for its developer"
if [ "${MINER_DRY_RUN:-}" = 1 ]; then
  printf '%q ' "${cmd[@]}"; echo
  exit 0
fi

restarts=0
while :; do
  rc=0
  "${cmd[@]}" || rc=$?
  if [ "$rc" = 42 ] && [ "$restarts" -lt 20 ]; then
    restarts=$((restarts + 1))
    echo "ycash-miner: lolMiner's watchdog asked for a restart ($restarts/20)" >&2
    sleep "${RESTART_DELAY:-10}"
    continue
  fi
  echo "ycash-miner: lolMiner exited with $rc" >&2
  exit "$rc"
done
