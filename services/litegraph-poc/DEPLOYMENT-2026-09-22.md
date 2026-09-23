# Clean entity-memory cutover — 2026-09-22 (America/Chicago)

**Follow-up:** M subsequently authorized a full fresh-code/onboarding reset.
See [fresh onboarding record](../gpt-live-poc/FRESH-ONBOARDING-2026-09-22.md)
for the current scope/revisions. The preserved-onboarding state below describes
the initial cutover, not the subsequent reset.

User explicitly selected a clean graph with the previous memories archived.
This was **not** an onboarding or identity reset. Existing verified phone,
onboarding progress, thread context, invite state, and authentication settings
were preserved. No personal facts were seeded into the new graph.

## Live deployment

Azure resource group: `rg-eleven-gptlive-poc`.

| Component | Revision / image |
| --- | --- |
| Memory app | `litegraph-memory-poc--entity-pg-20260922` |
| Voice app | `eleven-gptlive-poc--entity-contract-20260922` |
| LiteGraph | `ca773a2b28d9acr.azurecr.io/litegraph-two@sha256:6e2efe2535ed513527a942576ffe9a0344b6c40ca9b3b3251bf2a8ee2936c520` |
| Facade | `ca773a2b28d9acr.azurecr.io/litegraph-memory-facade@sha256:42cedc0e42c976752571bc2bfdf960447882431bf2466dbaa293384e703e5d4f` |
| Voice | `ca773a2b28d9acr.azurecr.io/eleven-gptlive-poc@sha256:9db26dfba2def7fa8b7149a306e4021c27863aba438d717308279698b96bed04` |

Memory images were built from `e2b8efd`. The voice image includes the pending
working-tree onboarding/resume, opening, and entity-contract changes; this
record does not claim those changes were committed or pushed by the agent.
The deployment architecture is Linux AMD64. Model `gpt-realtime` and voice
`sage` were unchanged.

The server runs the pinned LiteGraph 9 source with the existing-schema startup
patch. Its database is the isolated `litegraph_two_poc` schema and restricted
role in the existing Supabase project. The connection comes from Azure secret
`litegraph-postgres`, with hostname/CA verification enabled. The server loads
`/data/litegraph-entity-v9.json`; the old configuration file was not overwritten.

The facade has `GRAPH_MEMORY_ENABLED=true` and explicit owner/workspace scope.
The voice app has `MEMORY_SCHEMA_MODE=entity-memory.v1`. Its existing environment
entries, including caller verification and secret references, were compared
with the pre-deployment snapshot and preserved.

## Archive and rollback boundary

The fresh, consistent legacy SQLite snapshot is stored in Azure Files:

- Storage account: `stlitegraphmbrain`
- Share: `litegraph`
- Path: `backups/pre-entity-cutover-e2b8efd.db`
- SHA-256: `1a9a17c86313ba6196a4fdfac9805b6365b753d618b68fbdf745d47e6a4ccb0e`

Server/share/download hashes matched. SQLite integrity check returned `ok`.
The archive contains private data and credentials: never commit or publish it.
The earlier `backups/pre-durable-20260922.db` was also retained.

Previous revisions were memory `--0000006` and voice `--0000050`.
**Reactivating the old memory revision alone is not a data restore:** its
SQLite file was container-local. A rollback requires an explicit restore from
the verified archive and a matching legacy voice/facade contract. Preserve any
new PostgreSQL memories before doing that. Do not delete the new graph/schema
or reset onboarding as part of an application rollback.

Durable PostgreSQL storage does not by itself establish a backup/restore or
disaster-recovery guarantee; a PostgreSQL restore drill remains separate work.

## Checks completed

- 41 voice-service tests passed, including entity-contract and trusted-context
  gating. OpenAI Docs informed alignment of the Realtime tool instructions.
- The AMD64 LiteGraph image wrote a synthetic bundle against the restricted
  hosted database; a replacement local container recalled the same receipt,
  IDs, three facts, and eight edges. This fixture is in a separate test tenant.
- A new owner-scoped graph was created with zero nodes and zero edges, then
  successfully read by the Azure server after the provisioning container exited.
- Both intended Azure revisions reported healthy with 100% traffic.
- Both public health endpoints returned HTTP 200.
- Public authenticated MCP initialization and tool discovery succeeded.
- The advertised `memory_store` schema contains entities, facts, source refs,
  and idempotency keys; search uses the entity graph contract.
- Public memory search succeeded with no matches before the first call.
- Unauthenticated public memory access returned HTTP 401.

The voice health response still uses the historical label
`litegraph-mcp-read-only`; do not use that string as proof of tool permissions.
The authenticated MCP catalog and session configuration are the checks above.

## Still requires real-call acceptance

1. Explain meaningful particulars about a person naturally, without a save
   instruction. Confirm entity/fact/relationship records and a save receipt.
2. End the call and call again. Ask what was discussed; check the recalled IDs
   and particulars against the database, not only the spoken answer.
3. Add or correct a fact and verify the same entity is reused and provenance /
   supersession is preserved.

Automatic capture still depends on model tool use. There is no durable
transcript-extraction queue or completeness guarantee. Successful deployment
must not be described as a successful real-call save/recall test.
