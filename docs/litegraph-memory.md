# LiteGraph memory architecture

## Decision

LiteGraph is the conversational-memory provider for 11. Supabase remains the
authoritative operational store and identity/authorization boundary. Git
contains schemas, policy, fixtures, and deployment artifacts only.

This document defines the provider mapping only. LiteGraph is not installed or
provisioned during the voice-identity POC; that deployment decision follows the
go/no-go gate in `docs/voice-identity-poc.md`.

LiteGraph supports tenants, graphs, JSON node data, edges, vectors,
transactions, scoped credentials, and MCP. Those capabilities make it a useful
memory projection, but they do not replace the record-level trust decision made
by `security_check`.

## Isolation boundary

Each Supabase `workspace_id` maps to exactly one LiteGraph tenant. The tenant
contains one primary `memory` graph. LiteGraph GUIDs are provider details;
Supabase UUIDs and stable refs remain the public identifiers.

```text
Supabase workspace UUID -> LiteGraph tenant GUID
Supabase stable ref      -> node.data.external_ref
Supabase thread/task ID  -> reference node external_ref
```

11 does not receive a general LiteGraph bearer token or unrestricted native
MCP tools. It calls the policy-enforcing Memory Gateway. The gateway resolves
the authenticated workspace, searches only that tenant, authorizes every
candidate, and emits only safe fields. This is required because clearance,
compartment, purpose, requested permission, session presence, and temporary
grants are more specific than graph-scoped RBAC.

## Node vocabulary

| Label | Purpose | Authoritative owner |
| --- | --- | --- |
| `Person` | Stable actor reference and non-sensitive identity key | Supabase |
| `Organization` | Stable organization reference | Supabase |
| `ThreadRef` | Link to the interaction thread that explains why memory exists | Supabase |
| `TaskRef` | Link to the operational goal that produced or used memory | Supabase |
| `DecisionRef` | Link to a durable decision and its outcome | Supabase |
| `Episode` | Bounded conversational or event-derived context | LiteGraph projection |
| `Memory` | Individually governed fact, preference, commitment, or observation | Supabase metadata + LiteGraph content |

Facts and preferences are `Memory` nodes rather than bare properties on a
person. That gives every item its own provenance, sensitivity, validity,
confidence, lifecycle, and access metadata.

Required `Memory.data` fields follow `security/memory-contract.v1.json`:

```json
{
  "memory_ref": "memory:stable-id",
  "workspace_id": "supabase-workspace-uuid",
  "subject_ref": "person:stable-id",
  "owner_ref": "person:stable-id",
  "memory_type": "preference",
  "content": "Prefers location over loyalty points for NYC hotels.",
  "sensitivity_level": 1,
  "compartment": "travel",
  "source_ref": "interaction:stable-id",
  "source_actor_ref": "person:stable-id",
  "thread_ref": "thread:uuid",
  "task_ref": null,
  "confidence": 1.0,
  "valid_from": "2026-09-10T00:00:00Z",
  "valid_until": null,
  "status": "active",
  "supersedes": null,
  "schema_version": "memory.v1"
}
```

## Edge vocabulary

Edges express relationships without carrying the governed fact itself:

```text
(Memory)-[:ABOUT]->(Person|Organization|ThreadRef|TaskRef)
(Memory)-[:SOURCED_FROM]->(Episode|ThreadRef|DecisionRef)
(Memory)-[:PROVIDED_BY]->(Person)
(Memory)-[:SUPERSEDES]->(Memory)
(Episode)-[:PART_OF]->(ThreadRef)
(TaskRef)-[:PART_OF]->(ThreadRef)
(DecisionRef)-[:PART_OF]->(ThreadRef)
```

Application code uses a fixed edge vocabulary. The LLM may propose new
relationships but cannot invent production edge types during a read or write.

## Write and supersession path

Conversation-derived content starts as a candidate. 11 never writes an active
memory directly.

```text
interaction/task outcome
        -> Supabase memory candidate + provenance
        -> deterministic validation / optional approval
        -> durable projection event
        -> LiteGraph transaction
        -> projection receipt stored in Supabase
```

Corrections create a new memory. The old node becomes `superseded`, remains
available for historical explanation, and points to the replacement. Normal
retrieval returns only active memories whose validity window includes now.
Deletion policy may require hard deletion from both systems; a tombstone must
not retain the deleted sensitive content.

## Read path

```text
actor + authenticated session + subject + query + purpose
        -> coarse action authorization
        -> provider search inside the workspace tenant
        -> per-candidate security_check
        -> ranking of authorized candidates only
        -> bounded MemoryContext returned to 11
```

The gateway must not reveal denied record counts, labels, sources, references,
or snippets. `DEFER` and `CHALLENGE` are handling instructions, not evidence
about the hidden memory.

## Initial LiteGraph surface

The adapter uses LiteGraph REST/SDK operations internally. The first release is
read-only from 11's perspective:

- search active memories within one tenant;
- fetch a bounded authorized context;
- traverse only the fixed edge vocabulary;
- return stable external refs and safe fields.

Mutation MCP tools, arbitrary graph queries, bulk export/import, credential
administration, and cross-tenant traversal are not exposed to 11. Projection
writes use a separate service credential and graph transaction.

## Portability and exit

Supabase stores provider-neutral memory refs and projection receipts. Regular
JSONL exports provide recovery and provider migration, but exported sensitive
data must follow the same encryption, retention, and deletion policy. Removing
LiteGraph must require only a new `MemoryProvider`, not changes to tasks,
threads, policy, or ElevenLabs tools.
