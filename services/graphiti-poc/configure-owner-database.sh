#!/usr/bin/env bash
# Additive bootstrap ONLY. Never formats disks or replaces the cook-off database.
set -euo pipefail
umask 077
[[ "${DB_PASSWORD:-}" =~ ^[a-f0-9]{64}$ ]] || exit 2
[[ "${FALKORDB_IMAGE:-}" =~ ^falkordb/falkordb-server@sha256:[a-f0-9]{64}$ ]] || exit 2
mountpoint -q /srv/graphiti
test "$(findmnt -n -o LABEL /srv/graphiti)" = graphiti-data
docker inspect graphiti-falkordb >/dev/null
if docker inspect eleven-owner-falkordb >/dev/null 2>&1 || test -e /srv/graphiti/eleven-owner; then
    echo 'Owner database already exists; refusing replacement.'
    exit 3
fi
test -n "${TLS_CA_B64:-}"
test -n "${TLS_CERT_B64:-}"
test -n "${TLS_KEY_B64:-}"
mkdir -p /srv/graphiti/eleven-owner/{data,config}
printf '%s' "$TLS_CA_B64" | base64 -d > /srv/graphiti/eleven-owner/config/ca.pem
printf '%s' "$TLS_CERT_B64" | base64 -d > /srv/graphiti/eleven-owner/config/server.pem
printf '%s' "$TLS_KEY_B64" | base64 -d > /srv/graphiti/eleven-owner/config/server.key
openssl verify -CAfile /srv/graphiti/eleven-owner/config/ca.pem /srv/graphiti/eleven-owner/config/server.pem >/dev/null
printf '%s\n' 'bind 0.0.0.0' 'protected-mode yes' 'port 0' 'tls-port 6380' \
    'tls-cert-file /etc/owner/server.pem' 'tls-key-file /etc/owner/server.key' \
    'tls-ca-cert-file /etc/owner/ca.pem' 'tls-auth-clients no' \
    'loadmodule /var/lib/falkordb/bin/falkordb.so' \
    'dir /var/lib/falkordb/data' 'appendonly yes' 'appendfsync everysec' \
    'save 300 1' 'maxmemory 768mb' 'maxmemory-policy noeviction' \
    "requirepass $DB_PASSWORD" > /srv/graphiti/eleven-owner/config/redis.conf
chown -R 10001:10001 /srv/graphiti/eleven-owner
chmod 700 /srv/graphiti/eleven-owner /srv/graphiti/eleven-owner/{data,config}
chmod 400 /srv/graphiti/eleven-owner/config/*
docker run -d --name eleven-owner-falkordb --restart unless-stopped \
    --memory=1536m --memory-swap=1536m --cpus=1 --cap-drop=ALL \
    --security-opt no-new-privileges --user 10001:10001 --entrypoint redis-server \
    --log-opt max-size=10m --log-opt max-file=3 \
    -p 10.42.4.4:6380:6380 \
    -v /srv/graphiti/eleven-owner/data:/var/lib/falkordb/data \
    -v /srv/graphiti/eleven-owner/config:/etc/owner:ro \
    "$FALKORDB_IMAGE" /etc/owner/redis.conf >/dev/null
echo 'Separate owner database started; verification remains required.'
