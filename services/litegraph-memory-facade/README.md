# LiteGraph memory MCP facade

Scoped MCP facade for voice agents. It exposes `memory_search`, `memory_get`,
and append-only `memory_store`, binds all requests to one configured tenant and
graph, and calls the private LiteGraph REST service with bounded timeouts.

An opt-in **conversational capture** path is implemented but not deployed. It
replaces public graph writes with a durable PostgreSQL inbox and a background
fact writer. See [CONVERSATIONAL_CAPTURE.md](CONVERSATIONAL_CAPTURE.md) for
semantics, configuration, tests, limitations and the remaining rollout gates.

## Entity graph mode — implemented locally, opt-in

`GRAPH_MEMORY_ENABLED=true` selects a different `memory_store` schema: bounded
entity/fact bundles instead of prose memory nodes. It requires trusted deployment
values `MEMORY_WORKSPACE_ID` and `MEMORY_OWNER_REF`. This remains a single-owner
POC behind the existing authenticated gateway, **not** a multi-user policy engine.
Do not expose the facade directly or share its credential across actors.

The configured graph must be explicitly provisioned with matching `Data`:

```json
{
  "memory_schema_version": "entity-memory.v1",
  "workspace_id": "<trusted workspace ID>",
  "owner_ref": "<trusted owner reference>"
}
```

The runtime does not create missing scopes in this mode. Reads refuse legacy
`memory-v1` records rather than silently hiding them. Do not flip the flag on
the live legacy graph; migrate explicitly or provision a separate clean graph
after the authorized reset gates. No existing records are rewritten here.

### Save and recall contract

- `entity_registry.v1.json` defines all 19 baseline families and an initial
  predicate vocabulary. This is the executable starting registry, not the
  completed exhaustive entity-definition exercise.
- Each new entity gets a source/bundle-scoped ID. Subsequent saves must reuse
  `existing_id`. Names/phonetics only generate candidates, never automatic merges.
  Resolved `observed_name` aliases are retained in assertions, without blind
  entity upserts. Search expands those aliases across the resolved subject.
- The writer creates Entity nodes, sourced Fact nodes, `has_fact`/`object`
  links, and typed relationship edges in **one serializable transaction**.
  Literal facts stay attached to their subject rather than inventing an entity
  for every attribute.
- A SaveReceipt is committed in that same transaction. An identical source/key
  retry returns that receipt; different content under the same key is rejected.
  Timeouts only count as saved if a matching receipt can be read back. There is
  no fallback to partial writes or raw graph mutations.
- Provenance, capture time, validity, confidence, owner, workspace, compartment,
  and sensitivity accompany each assertion. All graph-mode records are private
  level 3. Source excerpts/references are **agent-reported**, not independently
  checked against a trusted transcript yet.
- Corrections append a fact and supersession edge. Current retrieval suppresses
  old assertions at the correction's effective time and does not resurrect them
  when the replacement expires. Competing corrections are reported, not silently
  resolved. Historical direct reads report `is_current` separately.
- `memory_get` on an Entity traverses actual links in both directions and returns
  current facts, relationships, related entities, and pending classifications.
  Broken references fail visibly. Reads are bounded, non-snapshot enumeration
  (up to 10,000 records per collection), not indexed or semantic search. Capacity
  overflow fails instead of returning misleading empty/partial results.
- Unknown well-formed predicates retain a searchable sourced assertion with
  `classification_status=pending`; they do not silently become approved registry
  entries. Automated refinement and its durable queue are **not implemented**.
- Families 15–18 cannot be created by this memory tool. A future trusted Turn
  Engine adapter must supply authoritative operational references and updates.
- Health reports the selected mode; it does not attest to database durability.

### Rollout gates still required

1. Finish PostgreSQL role/privilege compatibility and TLS tests, preserve the
   source snapshot, and complete the durable migration. See
   `../litegraph-poc/DURABLE_STORAGE.md`.
2. Provision the graph's trusted metadata. Preserve or explicitly migrate old
   data; do not reinterpret old note IDs as new entity IDs.
3. Deploy the matching voice contract (`MEMORY_SCHEMA_MODE=entity-memory.v1`)
   with trusted call/thread references. The local voice implementation includes
   the graph instructions and regression tests; it is not activated by building
   this facade. Deploy both together, then run a live synthetic call.
4. Add durable source-event ingestion, extraction/capture jobs, retry/coverage
   accounting, and registry refinement. This change does not guarantee that
   every important spoken fact triggers a tool call or survives a dropped call.
5. Add indexed/semantic retrieval and full authorization enforcement before
   multi-user deployment. Never use a remembered operational status to execute
   work without consulting the Turn Engine.
6. Only then run the scoped fresh-onboarding/reset test; no reset is included.

### Tests

From this directory, run `PYTHONPATH=. python -m unittest discover -s tests -v`.
The real-server suite is opt-in via `LITEGRAPH_TEST_ENDPOINT=http://127.0.0.1:PORT`.
It refuses remote hosts and only accepts the disposable fixture's synthetic
credential. `tests/litegraph.synthetic.json` contains deliberately public test
credentials: **never deploy it or publish its port beyond localhost**.

`tests/durability_probe.py seed ENDPOINT` writes a fixed synthetic bundle.
Replace only the test LiteGraph container, keeping the separate PostgreSQL
database, then run `tests/durability_probe.py verify NEW_ENDPOINT`. Verification
is read-only and checks the original receipt, IDs, facts, and edges.

## Recoverable tool failures

Known tool validation failures return a successful JSON-RPC envelope containing
`result.isError=true` and matching text/structuredContent with `status=rejected`,
an allowlisted `error_code`, correction guidance, and a `retry_action`.
Unknown tools and malformed protocol requests remain JSON-RPC errors. This
follows the [MCP tool error distinction](https://modelcontextprotocol.io/specification/2025-06-18/server/tools#error-handling).

Rejections are not service outages. Scope/authority failures stop rather than
inviting a bypass. Backend failures return `status=unavailable` and leave a save
unconfirmed: retry the identical payload/key once to recover any committed
receipt. Never switch keys merely to escape a timeout. After an explicit
validation rejection, correct the supported representation with a new key.
An idempotency conflict requires checking the prior result first.

Logs contain allowlisted rejection codes or exception class names, not raw
exceptions, tool arguments, dates, facts, or credentials. The voice prompt gives
date/entity-link examples but does not assert which input caused a past failure.
Tests exercise a rejected date followed by a corrected save, employment links,
descriptive trips/reporting relationships, error redaction, and unknown tools.
These tests do not establish that the model will correct every real-call save.

## Legacy mode (default; not the graph deployment)

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
