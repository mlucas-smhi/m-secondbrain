# Scenario baseline seed — source complete, extraction partial

## Scope and submission

Loaded the primary synthetic `ea-memory-cookoff.v1` fixture into the previously
empty group `ea_memory_cookoff_v1` on the isolated Graphiti cook-off app. No agent
connection, real memories, LiteGraph or routing changed. No answer-key document,
foreign canary, or later Morgan vegan/hiking test writes were ingested.

All 23 records used native JSON episodes, the original fixture clock
`2026-10-05T10:00:00-05:00`, and the shared extraction guidance validated in the
earlier paragraph test. That earlier test was text; this fixture is JSON. The
model, ontology and deployed image were unchanged. The source is a snapshot,
not a reconstructed historical stream. No explicit episode UUIDs were supplied.

Submission intent and queue acknowledgments were journaled privately before
readback. No writes were retried. The public synthetic
`scenario-seed-receipt.json` records generated IDs and source/guidance hashes.
Do not rerun this seed in the same group: names are not native idempotency keys.

The known idle database-client error occurred before ingestion. Only isolated
revision `graphiti-cookoff-mcp--0000001` was restarted to recover. It remains an
open reliability issue; there was no restart while the seed queue was active.

## Verification

- 23 unique episodes persisted; all stored bodies exactly match the manifest.
- Completion observed at 263 seconds for the sequential batch, not a measured
  per-episode or single-save latency.
- Native provenance returned 34 nodes and 55 relationships.
- Eight fresh-session retrieval probes completed in 0.382–0.702 seconds.
- All 55 edges were additionally read by ID, including their custom attributes.
- Eighteen offline tests pass. These are not scenario-level agent passes.

Preserved examples: both Alex identities and roles; Robin's vegetarian
restriction; Northstar review time, location and two reschedules; Monday flight
time-zone offsets; school start and arrival target; Harbor cancellation; July
Asia plan versus June quote; vendor reschedule; both unselected hotel candidates.
Some are node attributes, not edge facts: agents need node and fact retrieval.

Structured-record gaps found despite complete original episode retention:

- Airport exit's 30-minute buffer is missing (60-minute drive survives).
- Dinner ingredients and unconfirmed vegetarian substitution are missing.
- Dive hold deadline and $350-per-person price are missing.
- Cross-channel task/thread IDs and unsent email draft are missing; the return
  flight was typed Project and the task did not survive as a distinct
  TaskReference in the provenance readback.
- Calendar cache freshness and work-only coverage are missing.
- Pacific budget survives, but the $1,700 base estimates are missing.
- Some duplicate relationships are present (including partnership directions
  and repeated Project Lantern participation). No automatic deduplication repair
  was made.

These are source-to-graph coverage/classification failures, not merely slow
searches. Raw episodes retain the details, but that is not a successful
structured extraction. Do not claim the baseline is fully ready for apples-to-
apples agent scoring, and do not silently patch test answers into the graph.

## Test boundaries and next step

Keep this first import as evidence. Address general type classification and
attribute/qualifier coverage, then repeat in a new group with the same primary
facts before agent comparison. Do not connect or modify an agent automatically.

Scenario 11 deliberately requires a new write after baseline. Scenario 13 needs
server-enforced tenant permissions and a separately scoped canary; native group
IDs and this instance-wide credential are not authorization. Scenario 14 needs
an isolated failure/lost-response harness. Neither 13 nor 14 is made ready by
seeding. The shared fixture also contains scenario 16's source facts; no expected
answers for any scenario were ingested.
