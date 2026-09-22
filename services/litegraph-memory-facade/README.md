# LiteGraph memory MCP facade

Scoped MCP facade for voice agents. It exposes `memory_search`, `memory_get`,
and append-only `memory_store`, binds all requests to one configured tenant and
graph, and calls the private LiteGraph REST service with bounded timeouts.

Because the current POC uses ephemeral LiteGraph storage, the facade
idempotently recreates its one configured tenant and graph when a replacement
replica starts empty. This restores the authorized scope, not lost memories;
persistent memory still requires PostgreSQL or another durable LiteGraph store.

`memory_store` creates atomic `memory-v1` nodes only. It defaults to owner-only
`level_3` sensitivity, requires confidence and source provenance, uses a
deterministic GUID to make identical writes idempotent, and supports corrections
through `supersedes_memory_id`. It does not expose arbitrary node updates,
deletes, edges, tenant enumeration, or graph administration.

This POC performs bounded keyword ranking over at most 1,000 nodes. Replace that
implementation with indexed/vector retrieval before production scale.

## Entity resolution

Search includes lightweight English phonetic candidates (not semantic search
or automatic identity merges). `match_kind=phonetic_candidate` requires the
agent to resolve identity using retrieved and conversational context.
For resolved entity facts, `memory_store` accepts `entity_memory_id` plus
`entity_name`. The referenced memory must be in this configured graph and
support that name. Linked facts retain a stable entity ID, canonical name,
observed subject, alias, and reference provenance. Search expands confirmed
aliases across facts sharing that ID. Same-name people with different anchors
remain distinct; agents must reuse an existing entity anchor.

Legacy notes remain unchanged and searchable as candidates. Repair a legacy
split by appending a resolved fact with `supersedes_memory_id`; this release
does not rewrite or silently merge existing data. The model is responsible
for contextual disambiguation: the facade validates references, not whether
two people truly are the same. This remains a single-authorized-graph POC.
