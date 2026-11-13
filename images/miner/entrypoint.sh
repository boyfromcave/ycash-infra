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
#   MINIZ_URL, MINIZ_SHA256  miniZ's official download (https; miniz.cc serves it from a query URL,
#               ?sdm_process_download=1&download_id=<n>) and the SHA-256 of that archive, as miniz.cc's
#               download page lists it. miniZ mines 192,7 on Nvidia with CUDA, lolMiner with OpenCL.
#   MINER_ARGS  optional extra miner options, space separated (no pool, user, password or algorithm options).
#   MINER_UNTIL optional, a burst's end (epoch seconds; the fleet sets it on every burst miner). At that
#               time the miner is stopped and the container ends its own rental: it destroys its Vast
#               instance with the per-instance key Vast puts in every container (CONTAINER_API_KEY,
#               CONTAINER_ID; scoped to that one instance, never ours), or stops it if destroy is
#               refused, then exits 0. Without that key it just exits; the fleet's expire destroys it.
#   MINER_DRY_RUN=1  print what would be downloaded and run, then exit (no download, no GPU).
#   MINER_DIAG=1     download and check the miner, print the GPU and pool checks below, then exit:
#                    0 with a usable GPU, 70 without (no mining).
#   MINER_MANIFEST   the manifest (default /opt/ycash-miner/miners.conf).
#   MINER_CACHE      where the verified download is kept across restarts (default ~/.cache/ycash-miner).
#   RESTART_DELAY    seconds before a watchdog restart (default 10).
# Before mining it prints what the container sees: nvidia-smi's GPUs, the driver version and which of
# its libraries the container runtime mounted, the OpenCL ICD and platforms (clinfo), every OpenCL
# start-up step a miner takes (cl-probe: context, compile, run; with the driver libraries that failed
# to load), the miner's own device list (lolMiner --list-devices, miniZ --cuda-info) and the pool's
# address and reachability. With
# no usable GPU it exits 70 instead of idling on a rented machine, so Vast shows it exited and the
# fleet gives it back. (lolMiner mines 192,7 on Nvidia through OpenCL: images/miner/Dockerfile.)
# lolMiner's exit code 42 (a GPU hung, --watchdog exit) restarts it here, at most 20 times; any other
# lolMiner exit ends the container, so the fleet reconcile replaces the machine. miniZ has no such
# code: any exit restarts it, at most 20 times.
# Exit codes of its own: 64 bad configuration, 65 checksum mismatch, 69 download failed, 70 no usable
# GPU; 0 at the end of a burst (MINER_UNTIL).
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
url_re='^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._~%/+-]*(\?[A-Za-z0-9._~%=&+-]*)?$'
[[ $url =~ $url_re ]] || die "$miner: the download URL must be https:// (got '$url')"
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

until=${MINER_UNTIL:-}
[ -z "$until" ] || [[ $until =~ ^[0-9]{9,11}$ ]] || die "MINER_UNTIL: a time in epoch seconds"

extra=()
if [ -n "${MINER_ARGS:-}" ]; then
  read -r -a extra <<< "$MINER_ARGS"
  for a in "${extra[@]}"; do
    [[ $a =~ ^[A-Za-z0-9=,._:/*-]+$ ]] || die "MINER_ARGS: unexpected characters in '$a'"
    case "${a%%=*}" in
      -p|--pool|-u|--user|--pass|--dualpool|--dualuser|--dualpass|-a|--algo|--pers|-c|--coin|--config|--json|--profile|--watchdogscript|--apihost|--apiport|--tls|--socks5|--dns-over-https|--url|--par|--smart-pers|--run|--telemetry|--url2|--server|--port|--worker|--socks|--read-config|--write-config|--donate)
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
    # miniZ's own documentation (miniz.cc/usage, and its FAQ "How to mine Ycash (YEC)?"):
    # --url=<user>@<host>:<port>, --par=192,7 --pers=ZcashPoW; --telemetry=0 turns its local API
    # (default port 20000) off, as --apiport 0 does for lolMiner; --nocolour as its --help spells it
    cmd=("$bin" "--url=$user@$pool" "--par=192,7" "--pers=$PERS" "--telemetry=0" "--nocolour" "${extra[@]}") ;;
esac

paid="the pool's own address (the pool runs with --payout)"
[ -z "$payout" ] || paid=$payout
echo "ycash-miner: $miner $version from $url (SHA-256 $sha), Equihash 192,7 (personalization $PERS), pool $pool, worker $worker, paid to $paid"
echo "ycash-miner: the miner is downloaded from its official release and checked, never shipped in this image; it keeps its developer fee"
[ -z "$until" ] || echo "ycash-miner: a burst miner: it stops and ends its rental at $(date -u -d "@$until" '+%Y-%m-%d %H:%M UTC')"
haskey=no
if [ -n "${CONTAINER_API_KEY:-}" ] && [[ ${CONTAINER_ID:-} =~ ^[0-9]{1,12}$ ]]; then haskey=yes; fi
echo "ycash-miner: Vast's per-instance key present: $haskey (the miner itself runs without it)"
if [ "${MINER_DRY_RUN:-}" = 1 ]; then
  printf '%q ' "${cmd[@]}"; echo
  exit 0
fi

# ---- the end of a burst ---------------------------------------------------------------------------------
# Vast gives every container a key scoped to its own instance (CONTAINER_API_KEY, with CONTAINER_ID):
# it can stop or destroy that instance and nothing else. It is Vast's, not ours, and never printed,
# and the miner runs without it in its environment (env -u): the closed-source miner never needs it.
VAST_API=https://console.vast.ai/api/v0/instances
vast_self() { # METHOD BODY -> calls the Vast API on this instance with its own key; true on HTTP 2xx
  printf 'header = "Authorization: Bearer %s"\n' "$CONTAINER_API_KEY" |
    curl -fsS -K - --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 60 -X "$1" \
      -H 'Content-Type: application/json' -d "$2" -o /dev/null "$VAST_API/$CONTAINER_ID/" 2>/dev/null
}
burst_over() {
  echo "ycash-miner: the burst is over ($(date -u -d "@$until" '+%Y-%m-%d %H:%M UTC')): mining stopped"
  if [[ ${CONTAINER_ID:-} =~ ^[0-9]{1,12}$ ]] && [ -n "${CONTAINER_API_KEY:-}" ]; then
    if vast_self DELETE '{}'; then
      echo "ycash-miner: this machine's rental is ended (instance destroyed with its own key)"
    elif vast_self PUT '{"state": "stopped"}'; then
      echo "ycash-miner: destroy refused; the instance is stopped (no GPU charge; the fleet's expire destroys it)"
    else
      echo "ycash-miner: Vast refused both destroy and stop; exiting (the fleet's expire destroys the instance)" >&2
    fi
  else
    echo "ycash-miner: no per-instance Vast key in this container; exiting (the fleet's expire destroys the instance)"
  fi
  exit 0
}
past_until() { [ -n "$until" ] && [ "$(date +%s)" -ge "$until" ]; }
if past_until; then burst_over; fi

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
  # a gzip archive (by its first bytes: miniz.cc's download URL has no file name), else the binary itself
  if [ "$(head -c 2 "$tmp" | od -An -tx1 | tr -d ' \n')" = 1f8b ]; then
    mkdir -p "$dir/x"
    tar -xzf "$tmp" -C "$dir/x" --no-same-owner --no-same-permissions || fail "$miner: the archive does not unpack" 65
    found=$(find "$dir/x" -type f -name "$exe" | head -1)
    [ -n "$found" ] || fail "$miner: no $exe in the archive" 65
    # miniZ ships its binary's own checksum beside it ("SHA256 (miniZ) = <hex>"): check that too
    sumfile=$(find "$dir/x" -type f -name "$exe.sha256sum" | head -1)
    if [ -n "$sumfile" ]; then
      want=$(sed -n "s/^SHA256 ($exe) = \([0-9a-f]\{64\}\)\$/\1/p" "$sumfile" | head -1)
      [ -n "$want" ] && [ "$(sha256sum < "$found" | cut -d' ' -f1)" = "$want" ] ||
        fail "$miner: $exe does not match the checksum file in its archive" 65
    fi
    mv "$found" "$bin"
  else
    cp "$tmp" "$bin"
  fi
  chmod 0755 "$bin"
  rm -rf "$dir/x"
  touch "$dir/.verified"
  echo "ycash-miner: $miner verified (SHA-256 $sha)"
}
fetch

# ---- what the container sees: GPUs, OpenCL, the miner's devices, the pool --------------------------------
say() { sed "s/^/ycash-miner: $1/"; }
driver_check() { # the driver and what of it the container runtime mounted; prints only, never fatal
  local ver lib path out
  ver=$(sed -n 's/.*Kernel Module[^0-9]*\([0-9][0-9.]*\).*/\1/p' /proc/driver/nvidia/version 2>/dev/null | head -1)
  if [ -z "$ver" ] && command -v nvidia-smi >/dev/null 2>&1; then
    ver=$(timeout 30 nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1) || true
  fi
  echo "ycash-miner: driver version: ${ver:-unknown}"
  out=$(awk '$5 ~ /nvidia|cuda|OpenCL/ {print $5}' /proc/self/mountinfo 2>/dev/null | sed 's#.*/##' | sort -u | tr '\n' ' ')
  echo "ycash-miner: mounted by the runtime: ${out:-nothing}"
  out=$(ldconfig -p 2>/dev/null | awk '$1 ~ /^lib(nvidia|cuda|OpenCL)/ {print $1}' | sort -u | tr '\n' ' ')
  echo "ycash-miner: linker cache: ${out:-none}"
  # the libraries NVIDIA's OpenCL needs to compile and run a kernel; gpucomp is the shared compiler
  # of newer drivers (NVIDIA Container Toolkit 1.14.0 added it to the compute libraries), compiler the
  # older drivers' one, so one of the two is expected
  out=
  for lib in libcuda.so.1 libnvidia-opencl.so.1 libnvidia-ptxjitcompiler.so.1 libnvidia-nvvm.so.4 \
             "libnvidia-gpucomp.so.${ver:-?}" "libnvidia-compiler.so.${ver:-?}"; do
    if ldconfig -p 2>/dev/null | awk -v l="$lib" '$1 == l {f=1} END {exit !f}' ||
       [ -e "/usr/lib/x86_64-linux-gnu/$lib" ]; then out+="$lib=yes "; else out+="$lib=NO "; fi
  done
  echo "ycash-miner: driver libraries: $out"
  path=$(ldconfig -p 2>/dev/null | awk '$1 == "libnvidia-opencl.so.1" {print $NF; exit}')
  if [ -n "$path" ]; then
    out=$(ldd "$path" 2>&1 | grep -E 'not found|error' | tr -s ' \t' ' ' | tr '\n' ';') || true
    echo "ycash-miner: ldd libnvidia-opencl.so.1: ${out:-every dependency resolves}"
  fi
  for f in /etc/OpenCL/vendors/*.icd; do
    [ -e "$f" ] && echo "ycash-miner: ICD $f: $(tr -d '\n' < "$f")"
  done
  echo "ycash-miner: OCL_ICD_VENDORS=${OCL_ICD_VENDORS:-unset} OCL_ICD_FILENAMES=${OCL_ICD_FILENAMES:-unset} LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-unset}"
  if command -v clinfo >/dev/null 2>&1; then
    timeout 60 clinfo -l 2>&1 | say "clinfo: " || true
    timeout 60 clinfo 2>&1 | grep -E '^ *(Platform (Name|Version)|Device (Name|Version)|Driver Version|Device OpenCL C Version|Global memory size|Device PCI bus info)' |
      tr -s ' ' | say "clinfo: " || true
  fi
  if command -v cl-probe >/dev/null 2>&1; then
    if ! timeout 120 cl-probe 2>&1 | say "cl-probe: "; then :; fi
    # the libraries the OpenCL start-up asked the dynamic linker for and did not get
    out=$(LD_DEBUG=libs timeout 120 cl-probe 2>&1 >/dev/null | awk '
      /find library=/ { sub(/.*find library=/, ""); sub(/ .*/, ""); want[$0] = 1 }
      /calling init:/ { n = split($NF, a, "/"); got[a[n]] = 1 }
      END { for (l in want) if (!(l in got)) printf "%s ", l }') || true
    echo "ycash-miner: cl-probe: libraries asked for and not loaded: ${out:-none}"
  fi
}
gpu_check() { # prints the listings; true when a GPU the miner can use is there
  local smi=-1 ocl=-1 out
  echo "ycash-miner: NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-unset} NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES:-unset}"
  out=$(find /dev -maxdepth 1 -name 'nvidia*' 2>/dev/null | sort | tr '\n' ' ')
  echo "ycash-miner: device nodes: ${out:-none}"
  if command -v nvidia-smi >/dev/null 2>&1; then
    out=$(timeout 60 nvidia-smi -L 2>&1) || true
    printf '%s\n' "$out" | sed 's/ (UUID: [^)]*)//' | say "nvidia-smi: "
    smi=$(printf '%s\n' "$out" | grep -c '^GPU [0-9]' || true)
  else
    echo "ycash-miner: nvidia-smi: not in the container (the NVIDIA runtime mounts it with the utility capability)"
  fi
  driver_check
  case "$miner" in
    lolminer)
      out=$(timeout 120 env -u CONTAINER_API_KEY -u CONTAINER_ID "$bin" --list-devices --nocolor 2>&1) || true
      printf '%s\n' "$out" | grep -v '^[|+]' | say "lolMiner --list-devices: "
      if printf '%s\n' "$out" | grep -q 'No OpenCL driver or GPUs detected'; then
        ocl=0
      elif [[ $out =~ Number\ of\ OpenCL\ supported\ GPUs:\ ([0-9]+) ]]; then
        ocl=${BASH_REMATCH[1]}
      fi
      # Equihash 192,7 on Nvidia is an OpenCL solver in lolMiner: CUDA alone is not enough. An Nvidia
      # card lolMiner can drive with OpenCL is listed with "Drivers: Cuda, OpenCL"
      if [ "$ocl" -ge 1 ] || printf '%s\n' "$out" | grep -q 'Drivers: *Cuda, OpenCL' ||
         { [ "$ocl" = -1 ] && [ "$smi" -ge 1 ]; }; then return 0; fi
      echo "ycash-miner: lolMiner sees no OpenCL GPU (nvidia-smi: $smi GPU(s), lolMiner OpenCL: $ocl); miniZ (MINER=miniz) mines 192,7 with CUDA" >&2
      return 1 ;;
    miniz)
      out=$(timeout 120 env -u CONTAINER_API_KEY -u CONTAINER_ID "$bin" --cuda-info --nocolour 2>&1) || true
      printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^ *$' | say "miniZ --cuda-info: "
      if printf '%s\n' "$out" | grep -q 'dlopen "libcuda.so.1" failed'; then
        echo "ycash-miner: miniZ cannot load the CUDA driver (libcuda.so.1)" >&2
        return 1
      fi ;;
  esac
  [ "$smi" -ge 1 ] || { echo "ycash-miner: no GPU (nvidia-smi: $smi)" >&2; return 1; }
}
pool_check() { # prints where the pool's name points and whether its port answers; never fatal
  local host=${pool%:*} addrs
  addrs=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ') || true
  if [ -z "$addrs" ]; then
    echo "ycash-miner: pool $pool: the name does not resolve here (lolMiner keeps retrying)" >&2
    return 0
  fi
  echo "ycash-miner: pool $pool resolves to $addrs"
  if timeout 10 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$host" "${pool##*:}" 2>/dev/null; then
    echo "ycash-miner: pool $pool: the stratum port accepts connections"
  else
    echo "ycash-miner: pool $pool: no TCP connection within 10 s (lolMiner keeps retrying)" >&2
  fi
}
gpu_ok=0
gpu_check || gpu_ok=$?
pool_check
if [ "$gpu_ok" != 0 ]; then
  fail "no usable GPU in this container: not mining (exit 70, so the rental shows exited and is given back)" 70
fi
echo "ycash-miner: a usable GPU is there"
if [ "${MINER_DIAG:-}" = 1 ]; then echo "ycash-miner: MINER_DIAG=1: checks only, not mining"; exit 0; fi

restarts=0
while :; do
  rc=0
  if [ -n "$until" ]; then
    left=$(( until - $(date +%s) ))
    [ "$left" -gt 0 ] || burst_over
    timeout --signal=TERM --kill-after=30 "$left" env -u CONTAINER_API_KEY -u CONTAINER_ID "${cmd[@]}" || rc=$?
    if past_until; then burst_over; fi
  else
    env -u CONTAINER_API_KEY -u CONTAINER_ID "${cmd[@]}" || rc=$?
  fi
  if { [ "$miner" = lolminer ] && [ "$rc" = 42 ]; } || { [ "$miner" = miniz ] && [ "$rc" != 0 ]; }; then
    [ "$restarts" -lt 20 ] || { echo "ycash-miner: $miner exited with $rc after 20 restarts" >&2; exit "$rc"; }
    restarts=$((restarts + 1))
    echo "ycash-miner: $miner exited with $rc: restart $restarts/20" >&2
    sleep "${RESTART_DELAY:-10}"
    continue
  fi
  echo "ycash-miner: $miner exited with $rc" >&2
  exit "$rc"
done
