#!/bin/bash
# Testnet seed: first-boot setup (cloud-init runcmd, once per instance). Written by
# infra/testnet-seeds/nodes; the settings are in /opt/ycash-seed/seed.env beside it.
#
# In plain words: this turns a fresh Ubuntu machine into a Ycash testnet seed. It installs Docker,
# finds the seed's own data disk (formatting it only if it has never been used), optionally fills
# an empty disk with the published copy of the early testnet history, and starts the node so that
# it restarts by itself after a crash or a reboot. Nothing on the disk is ever deleted here.
#
# Idempotent: rerunning it changes nothing that is already in place.
set -euo pipefail
# shellcheck source=/dev/null
. /opt/ycash-seed/seed.env
D=/srv/ycash-data          # the data volume's mount point
N="$D/node"                # the node's datadir (/var/lib/ycash in the container)
UID_NODE=2001              # the image's user (contrib/docker/ycashd/Dockerfile: useradd --uid 2001)
log() { echo "ycash-seed: $*"; }
retry() { local n=0; until "$@"; do n=$((n + 1)); [ "$n" -ge 30 ] && return 1; sleep 10; done; }

# 1. Packages (Ubuntu 24.04: docker.io, the compose v2 plugin). Retried: the network can need a
#    moment after boot.
export DEBIAN_FRONTEND=noninteractive
retry apt-get update -q
retry apt-get install -y -q --no-install-recommends docker.io docker-compose-v2 jq curl python3 ca-certificates

# 2. The data volume: attached after the instance starts, so wait for it. On Nitro instances it is
#    an NVMe device whose serial is the volume id; older types name it /dev/xvdf.
dev=""
for _ in $(seq 1 180); do
  for c in "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLUME_ID//-/}" /dev/xvdf /dev/sdf; do
    [ -b "$c" ] && { dev=$(readlink -f "$c"); break 2; }
  done
  sleep 5
done
[ -n "$dev" ] || { log "data volume $VOLUME_ID never appeared"; exit 1; }
# Format only a device with no signature at all; anything already on it is kept.
if ! blkid -p "$dev" >/dev/null 2>&1; then
  log "formatting the new data volume $VOLUME_ID ($dev)"
  mkfs.ext4 -q -L ycash-data "$dev"
fi
uuid=$(blkid -s UUID -o value "$dev")
mkdir -p "$D"
grep -q "UUID=$uuid " /etc/fstab || echo "UUID=$uuid $D ext4 defaults,nofail,noatime 0 2" >> /etc/fstab
mountpoint -q "$D" || mount "$D"
# Docker starts only with the volume mounted, so a missing volume never becomes an empty datadir
# on the root disk.
mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=%s\n' "$D" > /etc/systemd/system/docker.service.d/ycash-data.conf
systemctl daemon-reload
systemctl enable --now docker

# 3. Swap on the root volume (headroom for a 2 GiB instance during the first sync).
if [ "${SWAP_MB:-0}" -gt 0 ] && [ ! -e /swapfile ]; then
  fallocate -l "${SWAP_MB}M" /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
  swapon /swapfile
fi

# 4. The node's RPC credential: made once per data volume, kept on it, never leaves the machine.
#    RPC listens on 127.0.0.1 only.
mkdir -p "$N"
if [ ! -s "$D/rpc.env" ]; then
  umask 077
  printf 'YCASHD_RPC_USER=seed\nYCASHD_RPC_PASSWORD=%s\n' "$(openssl rand -hex 24)" > "$D/rpc.env"
  umask 022
fi

# 5. Optional: the prefix bootstrap, on an empty datadir only (prefix-restore.sh refuses anything
#    else and verifies every byte against the pinned SHA256SUMS; frame.py checks the blocks again).
LOADBLOCK=""
if [ "${PREFIX_ENABLED:-0}" = 1 ] && [ ! -e "$N/prefix/IMPORTED" ]; then
  export DATADIR="$N" PREFIX_BASE_URL PREFIX_SUMS_SHA256 PREFIX_LAST_HEIGHT
  retry sh /opt/ycash-seed/prefix-restore.sh
  if [ -e "$N/prefix/VERIFIED" ] && [ ! -e "$N/prefix/FRAMED" ]; then
    rm -rf "$N/prefix/load"
    python3 -I /opt/ycash-seed/frame.py --prefix "$N/prefix" --out "$N/prefix/load" --magic "$PREFIX_MAGIC"
    touch "$N/prefix/FRAMED"
  fi
  if [ -e "$N/prefix/FRAMED" ]; then
    for f in "$N"/prefix/load/*.dat; do
      [ -e "$f" ] && LOADBLOCK="$LOADBLOCK -loadblock=/var/lib/ycash/prefix/load/${f##*/}"
    done
  fi
fi
chown -R "$UID_NODE:$UID_NODE" "$N"

# 6. The node: the image's own entrypoint writes ycash.conf from these variables
#    (contrib/docker/ycashd/README.md in the node trees). Host networking, so peers' addresses reach
#    ycashd as they are; only P2P is open in the security group.
args="-dnsseed=0 -externalip=$EXTERNAL_IP"
for a in $ADDNODES; do args="$args -addnode=$a"; done
[ -n "${EXTRA_ARGS:-}" ] && args="$args $EXTRA_ARGS"
cat > /opt/ycash-seed/node.env.base <<ENV
YCASHD_NETWORK=testnet
YCASHD_INSIGHT=0
YCASHD_LISTEN=1
YCASHD_RPC_BIND=127.0.0.1
YCASHD_RPC_ALLOWIP=127.0.0.1
YCASHD_RPC_THREADS=4
YCASHD_RPC_WORKQUEUE=16
ENV
{ cat /opt/ycash-seed/node.env.base; echo "YCASHD_EXTRA_ARGS=$args$LOADBLOCK"; } > /opt/ycash-seed/node.env
echo "YCASHD_EXTRA_ARGS=$args" >> /opt/ycash-seed/node.env.base

cat > /opt/ycash-seed/compose.yaml <<YAML
name: ycash-seed
services:
  ycashd:
    image: $IMAGE
    container_name: ycashd
    restart: unless-stopped
    network_mode: host
    env_file: [$D/rpc.env, /opt/ycash-seed/node.env]
    volumes: ["$N:/var/lib/ycash"]
    stop_grace_period: 180s
    logging: { driver: json-file, options: { max-size: 50m, max-file: "4" } }
YAML
retry docker compose -f /opt/ycash-seed/compose.yaml pull -q
docker compose -f /opt/ycash-seed/compose.yaml up -d

# 7. After the prefix import: drop the -loadblock flags for the next start (prefix-done.sh).
if [ -n "$LOADBLOCK" ]; then
  cat > /etc/systemd/system/ycash-prefix-done.service <<UNIT
[Unit]
Description=Ycash seed: retire the prefix -loadblock files once imported
[Service]
Type=oneshot
ExecStart=/opt/ycash-seed/prefix-done.sh
UNIT
  cat > /etc/systemd/system/ycash-prefix-done.timer <<UNIT
[Unit]
Description=Ycash seed: check the prefix import every 10 minutes
[Timer]
OnBootSec=10min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now ycash-prefix-done.timer
fi
log "seed $SEED_NAME up: $IMAGE, external $EXTERNAL_IP:$P2P_PORT"
