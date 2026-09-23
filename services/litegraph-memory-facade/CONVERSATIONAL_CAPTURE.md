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
and checks evidence excerpts against the captured text. It searches/reads before
resolving entities and prepares one atomic graph fact at a time. This is internal
batch decomposition: the caller need not speak one fact at a time.

One leased job runs per configured owner, in capture order. Claiming is serialized
with a PostgreSQL transaction advisory lock. Checkpoints are fenced by lease token
and expiration. Each graph payload is persisted before graph I/O; restart after a
commit replays the same source/key/payload and retrieves the receipt. A transient
error never regenerates an uncertain write. Rejected payloads have a bounded repair
budget. Independent units continue despite one unresolved detail. Each job has at
most three attempts; each resolver attempt has at most ten model tool steps.

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
   calls Responses API with synthetic data, local queue and an in-memory graph;
   it must never point to a live owner's graph. Current model is configurable
   (`gpt-4.1-mini` default), not a replacement of the voice model.
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

The actual model evaluation was blocked before extraction: the existing API
project returned HTTP 429 `credit_balance_exhausted`. No live deployment, queue
migration, credential changes, or personal-memory writes were performed for this
feature. Top up/check API billing, then rerun the evaluation before activating.

OpenAI Docs informed the explicit tool-call/output loop and Structured Outputs
contract: https://developers.openai.com/api/docs/guides/function-calling
