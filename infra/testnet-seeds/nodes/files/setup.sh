#!/bin/bash
# Seed host: first-boot setup (cloud-init runcmd, once per instance). Written by
# infra/testnet-seeds/nodes; the host's settings are in /opt/ycash-seed/seed.env beside it.
#
# In plain words: this turns a fresh Ubuntu machine into a seed host. It installs Docker, finds the
# host's own data disk (formatting it only if it has never been used) and installs `seedctl`, the
# tool that runs each network. It then restarts every network this disk already carries, at the
# version it last ran. A brand new disk carries none: the deploy workflow starts the networks
# (seedctl sync). Nothing on the disk is ever deleted here.
#
# Idempotent: rerunning it changes nothing that is already in place.
set -euo pipefail
# shellcheck source=/dev/null
. /opt/ycash-seed/seed.env
D=/srv/ycash-data          # the data volume's mount point
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

# 3. Swap on the root volume (headroom for several nodes during a first sync or an import).
if [ "${SWAP_MB:-0}" -gt 0 ] && [ ! -e /swapfile ]; then
  fallocate -l "${SWAP_MB}M" /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
  swapon /swapfile
fi

# 4. seedctl, and the two units that call it: at boot (restart what the disk carries) and every
#    10 minutes (retire the prefix -loadblock flags once a network has imported it).
install -m 0755 /opt/ycash-seed/seedctl /usr/local/sbin/seedctl
cat > /etc/systemd/system/ycash-seed-boot.service <<UNIT
[Unit]
Description=Ycash seed: start every network this host's data volume carries
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/seedctl boot
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/ycash-seed-prefix.service <<UNIT
[Unit]
Description=Ycash seed: retire the prefix -loadblock files of every network that has imported it
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/seedctl prefix-check
UNIT
cat > /etc/systemd/system/ycash-seed-prefix.timer <<UNIT
[Unit]
Description=Ycash seed: check the prefix imports every 10 minutes
[Timer]
OnBootSec=10min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable ycash-seed-boot.service
systemctl enable --now ycash-seed-prefix.timer
/usr/local/sbin/seedctl boot
log "host $SEED_NAME ready, external address $EXTERNAL_IP"
