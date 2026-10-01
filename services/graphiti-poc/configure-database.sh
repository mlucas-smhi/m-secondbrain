#!/usr/bin/env bash
# Invoked on ONLY the new dedicated VM by managed Run Command.
# Credentials arrive as protected parameters; never enable shell tracing.
set -euo pipefail
umask 077
[[ "${DB_PASSWORD:-}" =~ ^[a-f0-9]{64}$ ]] || { echo 'Expected 64-character hex password'; exit 2; }
[[ "${FALKORDB_IMAGE:-}" =~ ^falkordb/falkordb-server@sha256:[a-f0-9]{64}$ ]] || exit 2
[[ "${DB_PRIVATE_IP:-}" =~ ^10\.42\.4\.[0-9]+$ ]] || exit 2
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq docker.io
systemctl enable --now docker
if docker container inspect graphiti-falkordb >/dev/null 2>&1; then
    echo 'Container already exists; refusing implicit replacement or credential rotation.'
    exit 3
fi

device=/dev/disk/azure/scsi1/lun0
test -b "$device"
filesystem="$(blkid -s TYPE -o value "$device" || true)"
if [[ -z "$filesystem" ]]; then
    # Refuse any partition table/signature rather than formatting unknown data.
    test -z "$(wipefs --no-act --noheadings --output TYPE "$device")"
    mkfs.ext4 -L graphiti-data "$device"
else
    [[ "$filesystem" == ext4 ]]
    [[ "$(blkid -s LABEL -o value "$device")" == graphiti-data ]]
fi
mkdir -p /srv/graphiti
grep -q '^LABEL=graphiti-data ' /etc/fstab || printf '%s\n' 'LABEL=graphiti-data /srv/graphiti ext4 defaults 0 2' >> /etc/fstab
mountpoint -q /srv/graphiti || mount /srv/graphiti
mkdir -p /srv/graphiti/data /srv/graphiti/config
docker pull "$FALKORDB_IMAGE"
# Explicit entrypoint: upstream run.sh ignores positional config arguments and
# disables protected mode. Use our config instead, as an unprivileged UID.
printf '%s\n' \
    'bind 0.0.0.0' 'protected-mode yes' 'port 6379' \
    'loadmodule /var/lib/falkordb/bin/falkordb.so' \
    'dir /var/lib/falkordb/data' 'appendonly yes' 'appendfsync everysec' \
    'save 300 1' 'maxmemory 5gb' 'maxmemory-policy noeviction' \
    "requirepass $DB_PASSWORD" > /srv/graphiti/config/redis.conf
chown 10001:10001 /srv/graphiti/data /srv/graphiti/config/redis.conf
chmod 400 /srv/graphiti/config/redis.conf
docker run -d --name graphiti-falkordb --restart unless-stopped \
    --user 10001:10001 --entrypoint redis-server \
    --log-opt max-size=10m --log-opt max-file=3 \
    -p "${DB_PRIVATE_IP}:6379:6379" \
    -v /srv/graphiti/data:/var/lib/falkordb/data \
    -v /srv/graphiti/config/redis.conf:/etc/graphiti/redis.conf:ro \
    "$FALKORDB_IMAGE" /etc/graphiti/redis.conf
echo 'Database started; authenticated ping and persistence readback still required.'
