#!/usr/bin/env bash
# Run only on the dedicated synthetic cook-off VM. No credential output.
set -euo pipefail
umask 077
mountpoint -q /srv/graphiti
test "$(findmnt -n -o LABEL /srv/graphiti)" = graphiti-data
export REDISCLI_AUTH
REDISCLI_AUTH="$(sed -n 's/^requirepass //p' /srv/graphiti/config/redis.conf)"
test ${#REDISCLI_AUTH} -eq 64
redis() { docker exec -e REDISCLI_AUTH graphiti-falkordb redis-cli --raw "$@"; }
for attempt in $(seq 1 30); do
    if [[ "$(redis ping 2>/dev/null || true)" == PONG ]]; then break; fi
    sleep 1
done
[[ "$(redis ping)" == PONG ]]
docker exec graphiti-falkordb redis-cli ping | grep -q NOAUTH
redis GRAPH.QUERY graphiti_storage_canary "MERGE (n:PersistenceProbe {id:'azure-storage-canary-v1'}) SET n.value='persists-across-restart'" >/dev/null
redis SAVE >/dev/null
test -s /srv/graphiti/data/dump.rdb
docker restart graphiti-falkordb >/dev/null
for attempt in $(seq 1 30); do
    if [[ "$(redis ping 2>/dev/null || true)" == PONG ]]; then break; fi
    sleep 1
done
redis GRAPH.QUERY graphiti_storage_canary 'MATCH (n:PersistenceProbe) RETURN n.value' | grep -q persists-across-restart
echo 'PASS: password required; canary survives database container restart on managed disk'

# Test an RDB restore in a second unnetworked container. Leave the checkpoint
# on the dedicated disk for evidence; it is not an off-VM backup.
restore_dir="$(mktemp -d /srv/graphiti/restore-check-XXXXXXXX)"
cp /srv/graphiti/data/dump.rdb "$restore_dir/dump.rdb"
chown 10001:10001 "$restore_dir" "$restore_dir/dump.rdb"
image="$(docker inspect graphiti-falkordb --format '{{.Config.Image}}')"
restore_name="graphiti-restore-check-$(date +%s)"
cleanup() { docker rm -f "$restore_name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run -d --name "$restore_name" --network none --user 10001:10001 \
    --entrypoint redis-server \
    -v "$restore_dir:/var/lib/falkordb/data" \
    -v /srv/graphiti/config/redis.conf:/etc/graphiti/redis.conf:ro \
    "$image" /etc/graphiti/redis.conf --appendonly no --save '' >/dev/null
for attempt in $(seq 1 30); do
    if [[ "$(docker exec -e REDISCLI_AUTH "$restore_name" redis-cli ping 2>/dev/null || true)" == PONG ]]; then break; fi
    sleep 1
done
docker exec -e REDISCLI_AUTH "$restore_name" redis-cli --raw GRAPH.QUERY graphiti_storage_canary \
    'MATCH (n:PersistenceProbe) RETURN n.value' | grep -q persists-across-restart
echo 'PASS: RDB checkpoint restored and queried in an isolated second container'
echo 'RDB checksum:'
sha256sum "$restore_dir/dump.rdb"
echo 'Mounted data filesystem:'
findmnt -n -o SOURCE,TARGET,FSTYPE /srv/graphiti
