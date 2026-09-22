# LiteGraph memory MCP facade

Scoped MCP facade for voice agents. It exposes `memory_search`, `memory_get`,
and append-only `memory_store`, binds all requests to one configured tenant and
graph, and calls the private LiteGraph REST service with bounded timeouts.

`memory_store` creates atomic `memory-v1` nodes only. It defaults to owner-only
`level_3` sensitivity, requires confidence and source provenance, uses a
deterministic GUID to make identical writes idempotent, and supports corrections
through `supersedes_memory_id`. It does not expose arbitrary node updates,
deletes, edges, tenant enumeration, or graph administration.

This POC performs bounded keyword ranking over at most 1,000 nodes. Replace that
implementation with indexed/vector retrieval before production scale.
