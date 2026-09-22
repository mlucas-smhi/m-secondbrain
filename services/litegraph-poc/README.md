# LiteGraph memory POC

This deployment keeps LiteGraph REST and LiteGraph MCP private inside one Azure
Container App. Only an authenticated Caddy gateway is exposed publicly.

The current deployment is an **ephemeral SQLite transport POC** and must remain
at one replica. Azure Files is used only for generated configuration. SQLite
blocked on Azure Files/SMB during validation, so the database deliberately uses
container-local storage and will be lost when the replica is replaced. Do not
load real or sensitive memory. Persistent deployment requires PostgreSQL.

The public MCP endpoint is `https://<fqdn>/mcp`. `/rpc`, `/events`, REST port
8701, TCP port 8703, and WebSocket port 8704 are not exposed.

The scoped voice-agent facade is exposed at
`https://<fqdn>/memory-mcp` behind the same bearer-token gateway. It publishes
`memory_search`, `memory_get`, and append-only `memory_store`; tenant and graph
scope are server-bound. If ephemeral SQLite starts empty, the facade recreates
that fixed tenant and graph automatically. It cannot restore lost memories.

## Deploy

Choose a globally unique lowercase storage-account name (3-24 characters):

```bash
cd services/litegraph-poc
STORAGE_ACCOUNT_NAME=<unique-name> ./deploy.sh
```

The script prints the MCP URL and stores the complete authorization header on
the existing voice canary as the unused `mcp-authorization` secret. It does not
change that app's revision, environment variables, or phone routing.

Do not enable the Realtime canary until an explicit
`MCP_ALLOWED_TOOLS` set has been chosen and synthetic data has been loaded.
