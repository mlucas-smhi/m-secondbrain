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
