# Conversational capture — staged, NOT deployed

The current production POC still uses direct graph writes. This implementation
separates natural-language capture from graph formatting, but must not be enabled
until the real-model evaluation and scoped rollout checks pass.

## Flow and semantics

Verified voice session -> `memory_capture` -> committed PostgreSQL inbox ->
background extraction -> independently resolved facts -> existing LiteGraph
transaction/SaveReceipt -> per-fact result -> `memory_capture_status`.

`captured` acknowledges only the durable inbox. It does not mean the extraction
is complete or that every fact is saved. `complete` means all extracted units
were saved/already known or explicitly ignored. It is not mathematical proof of
extraction coverage. `partial`/`needs_attention` retain unresolved units. These
states must never be described as fully saved. The original capture is retained
even when extraction itself fails, so no rejected graph payload loses the input.

The schema requires plain content, explicit context, session/thread references,
and an idempotency key. A single passage can be 24,000 characters. The worker
extracts up to 64 independent units, preserves negations and explicit corrections,
and selects bounded source-segment indices so code copies exact evidence rather
than asking the model to regenerate quotations. It searches/reads before
resolving entities and prepares one atomic graph fact at a time. This is internal
batch decomposition: the caller need not speak one fact at a time.

The resolver has separate strict-schema `prepare_relationship` and
`prepare_attribute` tools. Code compiles these semantic proposals into local keys,
object/value fields, source evidence and the existing validated graph bundle.
The model never chooses local endpoint keys or source/idempotency bookkeeping.
Exact-name candidates must be read before creating a new namesake; this does not
automatically merge people by name. Qualifiers remain in assertion content while
activities become reusable relationship endpoints. A separate bounded semantic
review checks proposed caller clarifications; it cannot bypass write validation.

The writer batches up to three entity-name searches in one model turn and reads
up to three candidate contexts per name in code. Only contexts actually supplied
to the model count as read. More candidates require explicit reads; truncated
entity searches cannot authorize creating a new entity. Exact-name Entity records
rank ahead of their own facts so a long character sheet does not hide its owner.
Storage envelopes and duplicate edge representations are removed from model
context, while IDs, fact meaning, evidence, validity and provenance remain.
Composite trips/events are decomposed into participants, destination and timing,
not collapsed into a single person-to-person prose assertion. Extraction supplies
semantic event components; code expands them into independent work items with
required predicate/endpoint shapes. A related fact that merely mentions the month
cannot substitute for an `event_timing` literal attribute, including through the
`already_known` shortcut. Unknown sourced
predicates still remain pending classification; this does not expand permissions.

Before releasing a new proposal or accepting an already-known fact, a separate
model check compares the structured assertion (including direction) with the
requested unit and original source. Rejection stays in the internal repair loop;
review failure cannot authorize a write. This is probabilistic semantic defense,
not proof of entailment, and adds processing time. Schema, owner scope, receipts,
and required event-component checks remain deterministic backend enforcement.

With capture enabled, `memory_search` also returns a separate `pending_captures`
section from the scoped PostgreSQL inbox. It works across sessions before the
worker finishes. These are original caller passages, NOT finalized graph facts.
Results retain full passages (including corrections and negations), processing
state, source session/thread and capture time. Completed captures are excluded;
partial/failed captures remain available without pretending they succeeded.
Recall is bounded recent keyword matching, not semantic search: at most ten
matches and a 32,000-character source budget, with `has_more_matches` when limited.
The voice contract distinguishes caller-source recall from committed graph save.

One leased job runs per configured owner, in capture order. Claiming is serialized
with a PostgreSQL transaction advisory lock. Checkpoints are fenced by lease token
and expiration. Each graph payload is persisted before graph I/O; restart after a
commit replays the same source/key/payload and retrieves the receipt. A transient
error never regenerates an uncertain write. Rejected payloads have a bounded repair
budget. Independent units continue despite one unresolved detail. Each job has at
most three attempts; each resolver attempt has at most ten model tool steps,
plus at most one semantic/clarification-review request per step. All of this runs in the
background, not inside a blocking voice tool invocation.

## Scope and disclosure

This remains the existing **single-owner POC**, not production multi-tenancy.
Workspace/owner/graph come from deployment settings, not tool arguments. The
existing bearer gateway and voice verification gate stay mandatory. Do not share
that bearer credential with other users. No public Supabase table/RPC is created.
The queue lives in the existing restricted `litegraph_two_poc` schema and has no
PUBLIC grants. Runtime SQL is parameterized and scoped. No credentials or capture
text is logged. Secret-pattern rejection is defense in depth, not complete DLP.

Capture is still requested by the conversation model, not an independently
recorded/transcribed full call. It can omit content before calling the tool. The
worker's evidence check establishes fidelity to that capture, not the original
audio. Never represent this as guaranteed exhaustive recording. Structured
extraction still needs real-model coverage/contradiction evals.

Raw captured passages and plans currently remain in the private queue for POC
debugging/recovery. No automatic deletion/retention policy has been enabled.
Clarifications can be captured as new passages, but automatic reconciliation of
the earlier unresolved queue item is not yet implemented; do not claim it closed.
Global state counts expose backlog beyond the ten most recent status records.
Durable onboarding-topic checkpoint writes remain a separate unfinished feature.

## Activation (do NOT skip the evaluation gate)

1. Run the disposable PostgreSQL tests and `tests/eval_capture.py`. The latter
   calls Responses API with synthetic data and a local queue. Set
   `LITEGRAPH_TEST_ENDPOINT` to a disposable localhost LiteGraph 9 server to test
   actual writes and fresh-reader recall; otherwise it uses an in-memory double.
   It must never point to a live owner's graph. Set the evaluation and deployment
   writer explicitly to `gpt-4.1-2025-04-14` for the tested configuration. Enabling
   capture without `MEMORY_WRITER_MODEL` fails startup; there is no silent fallback
   to the unqualified mini model. This is separate from the realtime voice model.
2. Apply `memory_facade/capture.sql` as the existing restricted DB role, creating
   only the new queue table/index. Preserve all graph tables and memories.
3. Bind `MEMORY_CAPTURE_DSN` as a secret using verify-full TLS and the supplied
   Supabase CA. Bind `MEMORY_WRITER_API_KEY` privately from the authorized API
   project; do not place keys in source, CLI arguments or logs.
4. Deploy facade with `GRAPH_MEMORY_ENABLED=true`, `MEMORY_CAPTURE_ENABLED=true`,
   existing graph/owner/workspace unchanged, and `MEMORY_WRITER_MODEL` configured.
   Direct `memory_store` is then hidden AND rejected externally; only the worker
   calls the existing graph writer internally. Missing DB readiness fails startup.
5. Deploy voice with `MEMORY_SCHEMA_MODE=conversational-capture.v1` and allowed
   tools `memory_search,memory_get,memory_capture,memory_capture_status,memory_orientation`.
   The opening gets a bounded backend orientation snapshot after caller resolution;
   unverified sessions get no memory snapshot/tools. Failure means "not checked",
   not "memory empty". Voice, greeting sequencing and VAD settings are unchanged.
6. Check both revision readiness/traffic, scopes, secret references, startup
   snapshot, and existing-memory fingerprints. Then a real call must confirm
   capture, background fact outcomes and recall on a later call.

Rollback: restore the prior images, voice mode/tool allowlist, and disable capture.
Keep the queue table and pending jobs; do not delete captures during rollback.

## Verification record (2026-09-23)

Local PostgreSQL regressions cover durable replay, conflicting retries, scope
isolation, credential rejection, concurrent claims, lease fencing, partial
failure, clarification and restart after graph commit. Resolver contract tests
use model doubles and do not prove model quality.

The initial actual-model evaluation was blocked before extraction by HTTP 429
`credit_balance_exhausted`. Billing was restored on 2026-09-23 and real Responses
calls now succeed. Synthetic tests are a bounded POC qualification, not proof of
exhaustive extraction or production readiness. Live-call verification remains required.

The first run incorrectly substituted the caller for a named third person.
Subsequent local fixes clarify pronoun grounding, validate proposals against JSON
Schema before graph writes, and block graph-formatting questions from being
returned as caller clarifications. The evaluation now asserts subject names as
well as fact coverage and exercises the bounded retry cycle.

Prompt-only repairs passed the original paragraph once, but failed on a variant
with swimming before work, repeated gluten avoidance, corrected residence, and
an ambiguous Sam. That failure motivated the semantic-tool compiler above.
The first semantic-tool run was interrupted by network loss and lease expiry;
it is not quality evidence. Subsequent mini-model tests still produced unnecessary
clarifications and mishandled an unresolved referent, so `gpt-4.1-mini` has NOT
qualified for activation. The pinned `gpt-4.1-2025-04-14` comparison passed both
synthetic five-fact paragraphs and later-session correction/addition checks;
no live model setting has changed.

The evaluation asserts each clear fact's subject, one entity for the named person,
corrected current residence **link**, preserved activity qualifier, activity edge,
fresh-reader recall, deduplication, and unresolved ambiguous identity. Historical
wording that mentions the old city is not itself a failure; a wrong current link is.
`CAPTURE_EVAL_CASE=variant` selects the second synthetic paragraph.
`CAPTURE_EVAL_FOLLOWUP=1` adds a new-session correction and hobby, asserting prior
residence supersession, existing-person reuse, unchanged-diet deduplication and
fresh-reader recall. `CAPTURE_EVAL_RELATIONSHIPS=1` exercises partner/anniversary,
boss/employer, shared trip participants/destination/month and dietary negation.
That richer test initially exposed a missing Event: the writer stored the trip
as person-to-person prose. Prompt-only splitting still omitted links. Code-driven
event expansion exposed a reversed reporting link and an overly broad already-known
shortcut, motivating semantic review and required component checks. The richer
test now requires nine distinct graph facts, including both trip participants,
destination and a literal timing attribute. It accepts a correct inverse `boss_of`
relation, not only `reports_to`; semantic direction is what matters. The latest
passing richer run saved all nine with 30 model requests in 41.2 seconds.

Before the additional semantic-review safeguard, five-fact processing fell from
23–30 model requests to 11–14 requests. Those runs took 17.6–30.1 seconds;
the original unbatched run took 61.3 seconds
including repairs, so these are not clean paired latency benchmarks. Removing
storage envelopes reduced one original-case input from 78,311 to 40,425 tokens;
the latest variant used 24,001 input tokens. Follow-up runs took 9.1–10.1 seconds
for two new facts and one already-known fact. These are synthetic local-backend
measurements, NOT production timing or a finished latency target. Graph processing
is asynchronous; durable capture acknowledgement and pending recall do not wait
for these model calls. Two additional semantic-review probes run after the reported
paragraph processing time. Exact metrics and synthetic tool traces are opt-in.

With semantic review enabled, the latest original paragraph passed at 22 requests,
66,465 input tokens and 30.7 seconds. Its later-call correction/addition passed at
15 requests and 19.0 seconds. The final variant passed at 18 requests, 30,765 input
tokens and 23.4 seconds. Review is deliberately included in these numbers:
the earlier 11–14-request figures are optimization-stage results, not current
end-to-end performance claims. Further throughput work is still needed.

Local regressions pass 91 facade tests (including all three real LiteGraph 9
checks) and 52 voice tests. They include pending recall across reopened sessions,
scope isolation, result bounds, failed/partial visibility, current-fact lookup,
and no promotion of pending source to completed graph memory. Model-double tests
do not substitute for real-model quality gates.

No live deployment, queue migration, credential changes, or personal-memory
writes were performed for this feature. Existing deployed behavior is unchanged.

OpenAI Docs informed the explicit tool-call/output loop and Structured Outputs
contract: https://developers.openai.com/api/docs/guides/function-calling
