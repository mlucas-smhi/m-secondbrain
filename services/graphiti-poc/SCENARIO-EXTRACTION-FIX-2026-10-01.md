# Scenario extraction repair and second import

## Result and limits

The targeted extraction gaps from the first import are recovered in fresh group
`ea_memory_cookoff_v2`: 23 episodes, 34 nodes, 61 relationships, and 16/16 targeted
readback checks. This is **not** a pass of scenarios 1–16 or proof of exhaustive
extraction. No conversational agent was connected or changed. The first group
`ea_memory_cookoff_v1` remains intact for comparison.

See `scenario-seed-v2-receipt.json` for hashes, generated episode IDs, revision,
timing observations and named checks. `verify_scenario_readback.py` is evaluator
code only; it must never be included in ingestion or the agent prompt.

## Changes and cause

The pinned core's node-summary shortcut can append relationship facts without
summarizing the source episode. Node attribute extraction sees the episode but
cannot retain missing domain fields. Early extraction of linked entities also
misclassified booking/task/record references, with a task merged into a flight.

- Ontology `ea-graphiti.v1.1` adds event constraint/hold/price fields, transaction
  time/logistics fields, trip cost estimates, task communication-state fields,
  and snapshot coverage/freshness fields.
- Domain descriptions distinguish a transaction, task, trip and project.
- The fixture converter adds schema type hints for primary entities and linked
  endpoints, derived from existing fixture families. It keeps original facts,
  field values and relationship source/predicate/target tuples unchanged.
- Shared extraction guidance covers operational qualifiers and type boundaries.
- No native core, summary algorithm, tool handler or queue was patched. No
  manually constructed edges or expected answers were inserted.

The original fixture SHA is unchanged. Envelope/type hints, guidance and schema
changed together: this is a tested package of fixes, not a single-variable
attribution of improvement. All 23 stored episode bodies match the new manifest;
source facts/fields and relationship tuples were compared against the first
import. Morgan's vegan/hiking update and the foreign canary remain unseeded.

## Deployment and verification

- ACR build `cd1p`; image digest
  `sha256:6d48c72cdd363fac405ae30097a9467f5c202bbcdb7967f665b571a18e1c0ae3`.
- Isolated app `graphiti-cookoff-mcp`, ready revision
  `graphiti-cookoff-mcp--0000002`; existing gateway/secrets/models unchanged.
- Schema SHA: `670acfd5d672ba5dcf54f1989b35963d7bd9960c742a22e370d65dac88014415`.
- 23 offline tests pass. Network-disabled native loader validates all 21 entity
  and 31 edge models. Deployment health and native DB status passed after startup.
- Batch completion observed at 267.3 seconds; not single-write latency.
- All 61 relationships inspected by ID; eight fresh-session fact searches took
  0.361–0.721 seconds. Six fresh-session node searches retrieved the key repaired
  entities and their attributes; exact timings are in the receipt.

Recovered details include both travel buffers; time-zone offsets; menu contents
and unconfirmed substitution; dive hold deadline and per-person price; distinct
task/transaction IDs and task/thread references; draft indicator and pending
state; calendar synchronization/coverage/exclusions; cost components; and the
hotel interaction/thread IDs. Both Alex identities remain distinct.

## Retrieval and remaining caveats

Use native node search **and** fact search. Node attributes contain dates,
constraints, source freshness and costs that a fact-only result may not show.
This is entity-scoped retrieval, not permission to sweep the graph each turn.

The task's `communication_state` retained `email_draft` alongside channel labels,
not a fully normalized delivery-state record. The draft indication is present,
but it is not delivery verification. Some relationship duplicates and broad
reported-status labels remain. Summaries are lossy; do not treat a short summary
as exhaustive source evidence. Temporal corrections and repeated noisy speech
still need dedicated testing beyond this snapshot import.

The native idle DB-client/reconnect issue remains open. The initial check during
revision transition saw the previous connection failure; subsequent ready
revision checks passed. Do not claim deploying an image fixes idle recovery.

Scenarios 13 (tenant enforcement) and 14 (failure/ambiguous-write reconciliation)
still require separate controls/harnesses. Group IDs are not authorization.
Scenario 11 needs a real new save and cross-session read, not preseeded answers.
11, Eleven.a, 2, LiteGraph and all live routing remain unchanged. The next step
is an explicitly configured test-agent connection to v2, followed by chat tests.
