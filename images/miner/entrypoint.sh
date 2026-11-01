#!/bin/bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# ycash-miner: download the selected miner from its official release, check its pinned SHA-256, and
# run it on Equihash 192,7 with Ycash's personalization against one stratum pool.
#
# In plain words: this is the start-up script inside the miner container. The container itself holds
# no mining program. When it starts, this script downloads the chosen miner (lolMiner unless told
# otherwise) from the place its author publishes it, checks that the download is byte for byte the
# version we pinned (its SHA-256 fingerprint), and refuses to run anything else. Then it reads where to
# mine (the pool), what to call this machine (the worker name) and, optionally, which address is
# paid, checks them, and starts mining. It refuses to start without a pool, and it never accepts or
# prints a password, key or token: the container runs on rented machines that others can inspect.
#
# Environment:
#   POOL_URL    required. The stratum pool, host:port or stratum+tcp://host:port (no user:password@).
#   WORKER      the worker name (letters, digits, . _ -; default ycash-miner).
#   PAYOUT      optional, a transparent address. yolo pays the stratum username unless the pool runs
#               with --payout, so: PAYOUT set -> the username is PAYOUT (WORKER is only logged);
#               PAYOUT unset -> the username is WORKER (the pool must run with --payout).
#   MINER       lolminer (default) or miniz. miniz is refused unless MINIZ_URL and MINIZ_SHA256 are
#               set (in the manifest or the environment).
#   MINIZ_URL, MINIZ_SHA256  miniZ's official download (https) and its SHA-256, once pinned.
#   MINER_ARGS  optional extra miner options, space separated (no pool, user, password or algorithm options).
#   MINER_DRY_RUN=1  print what would be downloaded and run, then exit (no download, no GPU).
#   MINER_MANIFEST   the manifest (default /opt/ycash-miner/miners.conf).
#   MINER_CACHE      where the verified download is kept across restarts (default ~/.cache/ycash-miner).
#   RESTART_DELAY    seconds before a watchdog restart (default 10).
# lolMiner's exit code 42 (a GPU hung, --watchdog exit) restarts it here, at most 20 times; any other
# exit ends the container, so the fleet reconcile replaces the machine.
# Exit codes of its own: 64 bad configuration, 65 checksum mismatch, 69 download failed.
set -euo pipefail

MANIFEST=${MINER_MANIFEST:-/opt/ycash-miner/miners.conf}
CACHE=${MINER_CACHE:-${HOME:-/tmp}/.cache/ycash-miner}
PERS=ZcashPoW   # ycash6 src/crypto/equihash.cpp: "ZcashPoW" || le32(192) || le32(7); the miners append N, K

die() { echo "ycash-miner: $*" >&2; exit "${2:-64}"; }
fail() { echo "ycash-miner: $1" >&2; exit "$2"; }

# the manifest: KEY=value lines, read without running a shell; the environment may set only MINIZ_*
conf() { # key -> value from the manifest ("" if absent)
  [ -r "$MANIFEST" ] || die "manifest $MANIFEST not found"
  sed -n "s/^$1=\\(.*\\)\$/\\1/p" "$MANIFEST" | tail -1
}

# ---- what to run ------------------------------------------------------------------------------------
miner=${MINER:-lolminer}
case "$miner" in
  lolminer)
    version=$(conf LOLMINER_VERSION); url=$(conf LOLMINER_URL); sha=$(conf LOLMINER_SHA256); exe=lolMiner ;;
  miniz)
    version=pinned; url=${MINIZ_URL:-$(conf MINIZ_URL)}; sha=${MINIZ_SHA256:-$(conf MINIZ_SHA256)}; exe=miniZ
    if [ -z "$url" ] || [ -z "$sha" ]; then
      die "MINER=miniz is off: MINIZ_URL and MINIZ_SHA256 are not pinned (enable it only after reading miniZ's Terms and confirming its 192,7 flags; images/miner/README.md)"
    fi ;;
  *) die "MINER must be lolminer or miniz" ;;
esac
[[ $url =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._~%/+-]*$ ]] || die "$miner: the download URL must be https:// (got '$url')"
[[ $sha =~ ^[0-9a-f]{64}$ ]] || die "$miner: the pinned SHA-256 must be 64 lowercase hex characters"

# ---- the pool, the worker, the payout -----------------------------------------------------------------
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
      -p|--pool|-u|--user|--pass|--dualpool|--dualuser|--dualpass|-a|--algo|--pers|-c|--coin|--config|--json|--profile|--watchdogscript|--apihost|--apiport|--tls|--socks5|--dns-over-https|--url|--par|--smart-pers|--run|--telemetry)
        die "MINER_ARGS: $a is set by this entrypoint or not allowed" ;;
    esac
  done
fi

# ---- download and check -------------------------------------------------------------------------------
bin=$CACHE/$miner-$sha/$exe
case "$miner" in
  lolminer)
    cmd=("$bin" --algo EQUI192_7 --pers "$PERS" --pool "$pool" --user "$user" --tls off
         --dns-over-https 0 --apiport 0 --watchdog exit --nocolor --timeprint on "${extra[@]}") ;;
  miniz)
    # miniZ's form as its documentation gives it (not run here): --url=<user>@<host>:<port> --par=N,K --pers=<string>
    cmd=("$bin" "--url=$user@$pool" "--par=192,7" "--pers=$PERS" "${extra[@]}") ;;
esac

paid="the pool's own address (the pool runs with --payout)"
[ -z "$payout" ] || paid=$payout
echo "ycash-miner: $miner $version from $url (SHA-256 $sha), Equihash 192,7 (personalization $PERS), pool $pool, worker $worker, paid to $paid"
echo "ycash-miner: the miner is downloaded from its official release and checked, never shipped in this image; it keeps its developer fee"
if [ "${MINER_DRY_RUN:-}" = 1 ]; then
  printf '%q ' "${cmd[@]}"; echo
  exit 0
fi

fetch() {
  local dir=$CACHE/$miner-$sha tmp got
  if [ -x "$bin" ] && [ -f "$dir/.verified" ] && [ "$(sha256sum < "$dir/download" | cut -d' ' -f1)" = "$sha" ]; then
    echo "ycash-miner: using the verified download in $dir"; return 0
  fi
  rm -rf "$dir"; mkdir -p "$dir"
  tmp=$dir/download
  echo "ycash-miner: downloading $url"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 5 --connect-timeout 20 --max-time 600 -o "$tmp" "$url"; then
    rm -rf "$dir"
    fail "could not download $miner from $url (no network, or the release moved); nothing was run" 69
  fi
  got=$(sha256sum < "$tmp" | cut -d' ' -f1)
  if [ "$got" != "$sha" ]; then
    rm -rf "$dir"
    fail "SHA-256 mismatch for $url: got $got, pinned $sha; refusing to run it" 65
  fi
  case "$url" in
    *.tar.gz | *.tgz)
      mkdir -p "$dir/x"
      tar -xzf "$tmp" -C "$dir/x" --no-same-owner --no-same-permissions || fail "$miner: the archive does not unpack" 65
      found=$(find "$dir/x" -type f -name "$exe" | head -1)
      [ -n "$found" ] || fail "$miner: no $exe in the archive" 65
      mv "$found" "$bin" ;;
    *) cp "$tmp" "$bin" ;;
  esac
  chmod 0755 "$bin"
  rm -rf "$dir/x"
  touch "$dir/.verified"
  echo "ycash-miner: $miner verified (SHA-256 $sha)"
}
fetch

restarts=0
while :; do
  rc=0
  "${cmd[@]}" || rc=$?
  if [ "$miner" = lolminer ] && [ "$rc" = 42 ] && [ "$restarts" -lt 20 ]; then
    restarts=$((restarts + 1))
    echo "ycash-miner: lolMiner's watchdog asked for a restart ($restarts/20)" >&2
    sleep "${RESTART_DELAY:-10}"
    continue
  fi
  echo "ycash-miner: $miner exited with $rc" >&2
  exit "$rc"
done
