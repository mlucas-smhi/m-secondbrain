# Entity and operational-reference foundation

Version: 0.1
Agreed: 2026-09-22
Status: adopted design baseline; not a claim of deployed capability.

## Purpose and scope

Give 2 a broad, extensible understanding of people and their world while
preserving authoritative operational state in the Turn Engine. The foundation
must support natural capture, entity resolution, connected retrieval, and
continuity across communication channels without routine approval queues.

This is a coverage map for the detailed entity-definition exercise, not an
exhaustive ontology or finalized database schema. Families may be consolidated
or subdivided through versioned definitions. Git repository note types remain
governed separately by `_system/taxonomy.md`.

## Agreed starting families

| # | Family | Examples and boundaries |
| --- | --- | --- |
| 1 | People | Friends, relatives, colleagues, contacts, providers. CEO, partner, and customer are roles/relationships, not separate person families. |
| 2 | Animals | Pets and individually meaningful animals, including care relationships and needs. |
| 3 | Organizations and groups | Companies, nonprofits, governments, schools, teams, departments, clubs, households. Formal/informal distinctions belong in definitions. |
| 4 | Places | Countries, cities, addresses, buildings, venues, rooms, natural locations. Support containment; distinguish a business from its location. |
| 5 | Projects and initiatives | Bounded efforts, outcomes, participants, milestones, subprojects, dependencies. Reference operational tasks rather than duplicating their state. |
| 6 | Events and occasions | Meetings, dinners, appointments, conferences, birthdays. Distinguish a recurring series/occasion from an individual occurrence. |
| 7 | Activities and interests | Hiking, skiing, photography, volunteering, gadgets. An interest differs from a scheduled activity occurrence. |
| 8 | Topics and fields | AI, maritime operations, architecture, finance, environmentalism. Subjects of attention or expertise, not necessarily hobbies. |
| 9 | Goals and desired outcomes | Learning a language, relocating, launching a business. A goal can motivate multiple projects. |
| 10 | Routines and workflows | Repeatable personal patterns and procedures. Distinguish a definition from an execution instance. |
| 11 | Products, possessions, and assets | Equipment, devices, vehicles, property, collectibles. Distinguish a product model from a particular owned item. |
| 12 | Services and offerings | Subscriptions, insurance plans, maintenance, travel services. Distinguish an offering from its provider. |
| 13 | Content and documents | Books, films, music, articles, contracts, reports, notes. May be interests, evidence, or working material. |
| 14 | Accounts and communication endpoints | Phone numbers, email addresses, messaging/loyalty accounts, integrations. Explicit ownership and verification; no credentials in conversational memory. |
| 15 | Tasks and commitments | Turn Engine-owned operational work and promises. Graph holds linked context/references. |
| 16 | Decisions | Turn Engine-owned decisions, approvals, supersession, and resulting actions. Graph connects rationale and affected entities. |
| 17 | Bookings and transactions | Turn Engine-owned requests and execution/reconciliation state; external providers confirm actual outcomes. |
| 18 | Interactions and threads | Turn Engine-owned channel events, participants, continuity, and pending work. Graph connects sources and context. |
| 19 | Facts and observations | Sourced assertions about entities: preferences, constraints, circumstances, uncertainty, and temporal validity. |

Not every particular warrants a new entity. A fact such as "prefers quiet
restaurants" can remain attached to a person. A shared concept such as skiing
can be an entity when connecting people through that interest is useful.

## What is fixed versus extensible

Fix the integrity contract: stable IDs, workspace ownership, authorization,
provenance, uncertainty, lifecycle, and temporal semantics. Do not hard-code
every possible hobby, organization subtype, or human relationship as a struct.

Maintain a versioned, machine-readable definition registry with a human-readable
guide and examples/tests. Each definition should establish meaning, aliases,
boundaries, useful properties, and typical relationship endpoints. Typical
pairings guide interpretation; they should not prohibit legitimate new facts.

New entities can be created during conversation after identity resolution.
New concepts, subtypes, and relationship meanings can be registered through
automatic validation. Routine expansion must not require M or an operator to
approve a queue. Check existing definitions, normalize confident synonyms, and
retain distinctions where equivalence is uncertain. Vocabulary changes cannot
grant permissions or authorize external actions.

Store a usable sourced fact immediately even when precise classification is
unsettled. A successful save should trigger durable background refinement for
classification, equivalent-term discovery, and indexing; failed work retries.
The original record remains retrievable throughout. Refinement must preserve
provenance and must not silently merge people or equate merely related terms.
This background process is a requirement, not an existing implementation.

Retrieval must combine entity links with meaning-based search so an exact
canonical relationship label is not a prerequisite for finding a fact.
Human clarification is for consequential unresolved identity/meaning, not
routine schema maintenance. Destructive merges, deletion, permissions, and
external actions remain separately controlled.

## Character-sheet capture standard

Proactively retain directly stated, important particulars: dietary needs,
interests, hobbies, role, location, significant circumstances, relationships,
communication preferences, recurring habits, and practical constraints.
No "remember this" command is required.

Preserve exact meaning and attribution: vegan is not vegetarian; enjoys skiing
does not mean expert skier; likes gadgets does not imply wealth. Do not infer
motives, diagnoses, or unstated traits. Apply sensitivity policy to all facts.

Usually discard activity debris such as "he emailed me last week." Retain the
substance when it establishes a durable fact, decision, commitment, or task.
"He prefers email" is a durable preference. Planned changes need their timing.

Separate when a fact was recorded from when it was true. Corrections retain
history and supersession; current-state retrieval must not present superseded
facts as current. Temporal behavior requires explicit implementation.

## Turn Engine ownership: families 15–18

These families are authoritative operational records, not independently edited
memory copies. Use stable Turn Engine references in the graph. The Turn Engine
governs task transitions, approvals, deadlines, dependencies, decisions, and
provider reconciliation. Provider evidence establishes whether an external
booking/payment/action actually completed.

Memory informs action; the Turn Engine governs action and its state.

For an in-flight task raised during any call/message:

1. Resolve the user's reference using conversation and authorized memory.
2. Read the task's live Turn Engine state; remembered status is not current truth.
3. Discuss decisions using relevant preferences, constraints, and prior context.
4. Submit the authorized change through the Turn Engine's controlled interface.
5. After confirmation, update the linked memory projection/context with source
   references and the reason for the change. A projection failure must not undo
   or conceal the authoritative operational outcome; reconcile it separately.

Clarify when multiple tasks plausibly match. If execution is already underway,
the Turn Engine must determine whether a requested change can still apply.
Do not promise a change before confirmation.

## Cross-channel identity and continuity

- The task ID belongs to the work, not the channel or conversation. It remains
  the same across phone, SMS, email, and other supported media.
- Threads also have stable IDs. Switching channels alone does not replace the
  thread or create a replacement task.
- Each discrete interaction gets its own interaction ID, channel/provider
  metadata, and links to the relevant thread and task IDs.
- A new conversation may attach to existing work; one interaction may concern
  multiple tasks. Do not assume task, thread, and interaction are one-to-one.
- Recognition across channels requires verified identity and authorization,
  not merely a familiar name or access to a task ID.
- Stable references are preserved across projections and retries; retries must
  not create duplicate tasks or replay an already completed external action.

## Definition exercise and acceptance

For each family, define identity, boundaries, subtypes, attributes versus
separate facts, relationships/direction/synonyms, time, evidence, sensitivity,
and lifecycle. Include examples, counterexamples, and questions 2 must answer.

Acceptance scenarios include:

- A casual dietary/hobby/location detail survives a new call without a save command.
- Spoken-name variants resolve to the right person; ambiguous people stay distinct.
- A changed residence returns the current location while retaining history.
- A new concept is usable before background refinement finishes.
- A phone request, SMS decision, and email confirmation retain the same task ID.
- A recalled task status is refreshed before advice/action; rejected or failed
  transitions are not announced as successful.
- A later detail about Andrew augments the same identity and appears in a
  retrieved recap, without fabricating missing facts or completed checkpoints.

## Implementation boundary

Local implementation checkpoint, 2026-09-22: the facade now has an opt-in
entity-memory mode with the initial 19-family registry, transactional entity,
fact, and edge writes, idempotent receipts, scoped identity references, temporal
supersession, and graph-linked context retrieval. This mode is not deployed.
See `services/litegraph-memory-facade/README.md` for exact boundaries and tests.
The PostgreSQL migration is gated on the runtime schema-creation permission
decision documented in `services/litegraph-poc/DURABLE_STORAGE.md`.

The currently deployed POC's facade stores memory nodes and performs bounded
keyword/alias matching, with initial entity-reference work in local code.
Semantic retrieval, automatic capture/refinement, the exhaustive definitions,
and complete Turn Engine integration remain implementation work. Durable storage and the fresh onboarding/reset
test are also pending. This document does not authorize a production reset or
claim that any of those capabilities were deployed by recording the decision.
