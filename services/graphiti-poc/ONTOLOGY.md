# Executive-assistant entity and relationship definitions

Status: **v1.1 deployed to the isolated Azure Graphiti app** on 2026-10-01.
The native runtime loads 21 entity and 31 relationship models. The initial v1
deployment used commit `2a68f8c`; v1.1 changes are awaiting commit. See
[initial evidence](ONTOLOGY-ROLLOUT-2026-10-01.md) and the
[v1.1 extraction repair](SCENARIO-EXTRACTION-FIX-2026-10-01.md). No ElevenLabs
agent has been connected or switched.

`ontology.json` is the source of truth for `ea-graphiti.v1.1`. It maps every family
and predicate in LiteGraph's `entity-foundation.v1.1`; it does not migrate data.

## Representation

| Existing family | Graphiti entity types |
| --- | --- |
| Person, Animal, Organization, Place | Same names |
| Project, Activity, Topic, Goal, Routine | Same names |
| Event | Event; Trip for travel plans |
| Asset, Service, Content, Endpoint | Same names |
| Task, Decision, Transaction | TaskReference, DecisionReference, TransactionReference |
| Interaction | InteractionReference; ThreadReference for persistent cross-channel context |
| Fact | Native sourced assertions/episode provenance; not a standalone entity type |
| Explicit extension | Preference, linked to the holder |

This produces 21 entity types, 31 relationships and 53 distinct endpoint-type
pairs. A role is not a person subtype. The same Person can have any number of
supported relationships; no one-partner, one-employer or one-child cardinality
constraint is imposed. In particular, partnership does not establish marriage,
exclusivity, or parenthood of a partner's children.

### Relationships

- People/family: PartnerOf, ParentOf, SiblingOf, FriendOf, RelatedTo, ReportsTo.
- Work/location: WorksFor, CollaboratesWith, CollaboratesWithPeopleIn, LivesIn,
  LocatedAt, Provides.
- Personal context: CaresFor, Enjoys, HasDietaryPreference,
  HasCommunicationPreference, Prefers, UsesEndpoint, Owns, FollowsRoutine.
- Plans/work: ParticipatesIn, HasDestination, PartOf, SupportsGoal,
  AwaitsDecision, AssignedTo, DependsOn, InThread, ContextFor, MentionedIn.
- Controlled vocabulary fallback: UnclassifiedRelation for supported connections
  without a precise definition. Native Graphiti can still emit other predicates;
  this is not a hard allowlist or a durable classification/review queue.

ParentOf runs parent -> child; ReportsTo runs employee -> manager; WorksFor runs
person -> organization. PartnerOf/SiblingOf/FriendOf have symmetric meaning:
one edge can represent the relationship, and recall must consider both endpoint
directions. The native schema does not enforce inverse-edge deduplication.

### Attributes versus edges

Use an edge when the fact meaningfully connects two identifiable concepts:
person -> employer, parent -> child, person -> hiking, person -> vegetarian.
Use attributes for details: employment role, relationship anniversary, explicit
time zone, event arrival target, reported state and supplied external references.
Not every number, adjective, street string or passing remark becomes a node.

Version 1.1 adds explicit fields for event constraints/prices/holds, trip cost
estimates, transaction departure/arrival/logistics, task communication state,
and source-snapshot coverage/freshness. These facts cannot rely on summaries:
the pinned core may append only edge facts to a short summary rather than
summarize the full episode. Attribute extraction sees the episode but needs a
declared field. No summary/core patch or generic whole-transcript field was added.

The synthetic fixture converter supplies native type hints for primary entities
and relationship endpoints. `meeting` maps to Event, `booking` to
TransactionReference, `record` to Content, and `interaction` to
InteractionReference. The original family, facts, fields and relationships are
retained. A task to change a reservation must not resolve to that reservation or
the overall trip; supplied task/thread IDs remain on their own reference.

Important preferences get explicit concepts and edges, while other attributes
may still be in node properties. Retrieval must use both native node search and
fact-edge search; neither alone is a complete record. Summaries are helpful but
not proof that required edges were written.

All custom fields are optional: unknown stays absent. Dates are strings on
purpose so "July 2027" or "May 12, year unknown" does not become a fabricated
timestamp. Graphiti's native validity/provenance fields remain native; custom
attributes do not shadow them. Confirm DST/locale arithmetic separately.

## Native integration, not a middleware writer

The Docker build runs `compile_ontology.py`, which:

1. Validates fields, family coverage and relationship endpoint references.
2. Generates the native `models/entity_types.py` and `models/edge_types.py`
   Pydantic registries in the image, replacing upstream's sample domain models.
3. Preserves upstream server/provider settings and writes `config/ea-config.json`
   (JSON is valid YAML for the native loader).
4. Combines every relationship for the same ordered type pair in one map entry.
   Repeated native entries otherwise overwrite each other.

The explicit `--config` path selects the domain configuration. Merely editing a
description for a registered built-in name would not work: upstream prefers its
registered class, including its original description and attributes. The smoke
test checks the **actual loaded classes**, not only JSON syntax.

No graphiti-core, MCP tool handler, ingestion queue, search algorithm or gateway
payload transformation is changed. Record this as a **custom domain schema on
native Graphiti**, not an untouched-default comparison.

`extraction_rules` and `extraction-guidance.txt` are shared guidance for the
ingestion caller, via native `custom_extraction_instructions`; they are not a
native global config setting. `extraction.py` builds native `add_memory`
arguments for the isolated evaluation caller and combines both policies without
altering the source paragraph. It performs no network calls or graph rewrites.
The supplement makes meaningful personal traits eligible for domain concepts
and preserves source qualifiers in edge facts for later attribute extraction.
It contains no acceptance-case answers. Type/field descriptions are active in
the deployed image; the supplement applies only to requests that pass it.
No agent prompt or live-call ingestion is changed by adding these files.

## Authority and expansion limits

The ontology describes knowledge, not authorization. Endpoint ownership,
caller identity, sensitivity checks, tenant boundaries and Turn Engine actions
need trusted application enforcement. Native MCP's group IDs and extraction
instructions do not provide those controls.

Operational types carry supplied IDs as references only. Without an ID, a
mention remains unbound context. An extracted ID is still not independently
verified. Do not infer reservations, completed payments, approvals or task state
transitions from intentions. Consult the actual Turn Engine before execution.

Similarly, avoiding secret capture is an instruction here, not a content filter.
Keep this deployment synthetic-only until authorization/filtering controls exist.
Graphiti's entity resolution and schema-guided extraction are probabilistic;
offline model validation does not prove identity resolution, exhaustive capture,
accurate corrections, or correct relationships from real speech.

## Validation and activation gates

Offline tests:

```sh
python3 services/graphiti-poc/compile_ontology.py
python3 -m unittest discover -s services/graphiti-poc/tests -v
docker run --rm --network none \
  --mount type=bind,src="$PWD/services/graphiti-poc",dst=/domain,readonly \
  --entrypoint python graphiti-cookoff-local:3c427640 \
  /domain/tests/native_ontology_smoke.py
```

The final command uses the previously built pinned native image and an ephemeral
source copy. It makes no API or database requests and touches no live memory.

`ontology-acceptance.json` contains eight explicitly synthetic extraction tests:
multi-role person, later-added child, boss direction, same-name ambiguity,
dietary correction, conditional communication, unbooked trip and cross-channel
engine references. It is an **evaluation plan**, not a passed test suite. Submit
only each case's episode strings; keep checks/must_not out of ingestion.

Deployment completed; baseline was partial and the first guided comparison
recovered all expected details. Next gates: test later additions and corrections,
repeat with varied wording, use fresh synthetic groups; verify actual nodes/edges,
identity reuse, temporal correction and native provenance for each case; verify
recall in a new session. Do not reinterpret or silently rebuild the previous
canary. Keep 11, Eleven.a, 2 and LiteGraph unchanged until an explicit agent
activation step. Schema changes alone do not backfill existing data.
