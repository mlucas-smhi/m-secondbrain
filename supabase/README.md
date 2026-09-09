# Turn engine

> **Operational notice (2026-09-05):** Hosted turn processing is restored only
> to `service_role`. External callers must use the authenticated Edge Functions.
> The safe canary procedure is in
> [`../docs/turn-engine-runbook.md`](../docs/turn-engine-runbook.md). Architecture
> and incident details are in
> [`../docs/turn-engine.md`](../docs/turn-engine.md) and
> [`../docs/incidents/2026-09-04-runaway-turn-rpc.md`](../docs/incidents/2026-09-04-runaway-turn-rpc.md).

The turn engine stores the current task snapshot in `public.tasks` and its
append-only history in `public.task_events`.

All task progress should go through `public.advance_task`. The function:

- locks one task for the duration of the turn;
- optionally rejects stale callers with `p_expected_status`;
- treats a repeated non-null `p_call_id` as an idempotent replay;
- validates the lifecycle transition and allowed patch fields;
- updates the task and appends its event in the same transaction.

Task creation goes through `public.create_task`, which atomically creates the
initial `new` snapshot and its `task.created` provenance event. A creation
`call_id` is globally unique so retries cannot create duplicate tasks.

Only `service_role` can execute the function. Never expose that credential to a
client. A trusted worker or server function should call the RPC.

## Example

```sql
select * from public.advance_task(
  p_task_id := '00000000-0000-0000-0000-000000000000',
  p_event_type := 'turn.completed',
  p_actor := 'alfred',
  p_call_id := 'provider-call-id',
  p_expected_status := 'running',
  p_patch := '{
    "status": "waiting_user",
    "pending_question": "Which date works for you?",
    "resume_condition": "User supplies a date"
  }'::jsonb,
  p_outcome := 'needs_input'
);
```

The supported lifecycle is:

```text
new -> ready | running | cancelled | failed
ready -> running | cancelled | failed
running -> ready | waiting_user | waiting_external | retry_scheduled
        | completed | failed | cancelled
waiting_user -> ready | running | cancelled | failed
waiting_external -> ready | running | retry_scheduled | cancelled | failed
retry_scheduled -> ready | running | cancelled | failed
completed | failed | cancelled -> terminal
```

Run the database checks with a running local Supabase stack:

```sh
supabase test db supabase/tests/turn_engine.sql
```

## First automated turn

`functions/run-task-turn` is the first HTTP runner. It accepts a task ID and a
caller-owned idempotency key, then advances that task from `new` or `ready` to
`running`. It intentionally performs no AI reasoning, scheduling, or external
action yet.

The endpoints authenticate callers with a dedicated `X-Turn-Engine-Key`
header. The Supabase service-role credential remains inside the Edge Function
runtime and must never be given to an external caller.

```text
X-Turn-Engine-Key: YOUR_TURN_ENGINE_API_KEY
Content-Type: application/json
```

JWT verification is disabled at the Supabase gateway because these are
machine-to-machine endpoints. Every handler calls the shared key guard before
reading its request body or touching the database.

```json
{
  "task_id": "00000000-0000-0000-0000-000000000000",
  "call_id": "unique-id-for-this-request",
  "expected_status": "new"
}
```

`functions/wait-for-user` pauses a running task with a durable question:

```json
{
  "task_id": "00000000-0000-0000-0000-000000000000",
  "call_id": "unique-wait-request-id",
  "question": "Which date works for you?",
  "resume_condition": "User supplies a date"
}
```

`functions/resume-task` records the answer on an immutable event, clears the
waiting fields, and moves the task to `ready`:

```json
{
  "task_id": "00000000-0000-0000-0000-000000000000",
  "call_id": "unique-answer-request-id",
  "answer": "November 10"
}
```

Call `run-task-turn` again with `"expected_status": "ready"` to begin the next
turn.

`functions/complete-task` closes a running task and preserves a result summary
on its immutable completion event:

```json
{
  "task_id": "00000000-0000-0000-0000-000000000000",
  "call_id": "unique-completion-request-id",
  "result": "The requested work is complete."
}
```

Completion sets `completed_at` automatically and clears any remaining action or
waiting fields. A completed task is terminal and cannot be reopened.

## Deterministic decision router

`functions/decide-task-turn` provides one orchestration endpoint for finishing
a running turn. The caller must explicitly choose one of two outcomes; this
function does not ask a model to make the decision.

Pause for input:

```json
{
  "task_id": "00000000-0000-0000-0000-000000000000",
  "call_id": "unique-decision-request-id",
  "outcome": "waiting_user",
  "question": "Which date works for you?",
  "resume_condition": "User supplies a date"
}
```

Complete the task:

```json
{
  "task_id": "00000000-0000-0000-0000-000000000000",
  "call_id": "unique-decision-request-id",
  "outcome": "completed",
  "result": "The requested work is complete."
}
```

The outcome-specific functions remain available as narrow building blocks, but
new orchestration code should normally call `decide-task-turn`.

## Durable task-step graph

Parent tasks describe goals. Executable work lives in `task_steps`, with
ordering in `task_step_dependencies`. A scheduled n8n worker claims one
runnable step through `functions/claim-task-step`:

```json
{
  "worker_id": "n8n-task-runner",
  "lease_seconds": 300,
  "supported_step_types": ["test.noop", "elevenlabs.outbound_call"]
}
```

The response contains `step: null` when the queue is idle. A claimed step
includes an opaque `claim_token`; only that token may complete the step before
its lease expires. Claims increment the bounded attempt count. Expired work is
returned to `ready`, or marked `failed` after its attempt budget is exhausted.
The capability allowlist is applied before locking, so a worker cannot lease a
step type for which it has no handler.

`research.travel` completions use the provider-neutral `research.v1` contract:

```json
{
  "schema_version": "research.v1",
  "summary": "The Langham best fits the location preference.",
  "options": [
    {
      "key": "langham",
      "label": "Langham",
      "summary": "Closest option to the meeting.",
      "attributes": { "strength": "location" }
    }
  ],
  "recommendation": {
    "option_key": "langham",
    "rationale": "Location is the controlling preference."
  },
  "sources": [
    { "key": "langham-site", "title": "Langham New York", "url": "https://example.com/langham" }
  ],
  "constraints": { "city": "New York" },
  "caveats": []
}
```

Option and source keys must be unique, and the recommendation must reference a
declared option. The database validates the contract before completing the step
or unlocking its dependents.

Travel inventory and other external evidence are accessed through replaceable
`tool_adapters`. Steps declare capability requirements such as
`travel.hotel.search` with an explicit `read`, `hold`, or `execute` mode. Tool
runs retain idempotency and provenance while large raw provider responses remain
behind provider-neutral external references. Adapter records contain credential
references only—never API keys or MCP secrets.

`create-task-plan` accepts a top-level `tool_requirements` array. Each item names
an existing `step_key`, a capability, an authority `access_mode`, optional
constraints, and an optional `preferred_adapter_key`. Omitting the preferred
adapter keeps the plan portable; resolution can occur when the worker runs.
Call `resolve_task_step_tool_adapter(step_id, capability)` at execution time;
the task and worker route on canonical capabilities, not provider names. Active
adapters are selected by `selection_priority`, and disabling one allows another
adapter with the same capability to take over without editing the task graph.

Task initiators, scoped authority grants, approvals, closure recipients, and
provider-neutral memory references have dedicated tables. Repository paths are
not embedded in the execution model.

Decisions are first-class records with declared options and a linked gate.
`functions/resolve-task-decision` records the selected option and rationale,
satisfies the gate in the same transaction, and makes every dependency-safe
downstream step eligible for a future claim.

`functions/create-task-plan` is the atomic ingestion boundary for this model.
Its request includes a caller-owned `call_id` and a structured `plan` containing
the thread, parent task, steps, dependencies, decisions, participants, and
closure recipients. References between graph objects use stable keys inside
the request. An invalid reference or cycle rolls back the entire plan; replaying
the same `call_id` returns the original snapshot without creating duplicates.

## Task creation

`functions/create-task` replaces manual inserts into `public.tasks`. It creates
both the task and its first audit event in one request:

```json
{
  "task_type": "research",
  "goal": "Compare three possible destinations",
  "call_id": "unique-creation-request-id",
  "context": {
    "traveler": "Michael"
  },
  "priority": 3
}
```

`context` is optional and defaults to `{}`. `priority` is optional and ranges
from `1` (highest) through `5` (lowest), defaulting to `3`.

## Atomic turn processing

`functions/process-task` is the preferred orchestration endpoint. It starts a
`new` or `ready` task and applies its explicit decision in one database
transaction. The paired events use `:started` and `:decision` suffixes on the
caller-provided `call_id`, and the decision event links back to its start event.

One request can pause for input:

```json
{
  "task_id": "00000000-0000-0000-0000-000000000000",
  "call_id": "unique-turn-request-id",
  "expected_status": "new",
  "outcome": "waiting_user",
  "question": "Which date works for you?",
  "resume_condition": "User supplies a date"
}
```

Or complete the work:

```json
{
  "task_id": "00000000-0000-0000-0000-000000000000",
  "call_id": "unique-turn-request-id",
  "expected_status": "ready",
  "outcome": "completed",
  "result": "The requested work is complete."
}
```

If either transition fails, the entire turn rolls back. Retrying the same
`call_id` returns the original outcome without adding events.

## Universal wake endpoint

`functions/wake-task` is the single resume door for n8n, callbacks, timers,
and later inbound-call adapters:

```json
{
  "task_id": "00000000-0000-0000-0000-000000000000",
  "trigger_type": "user_response",
  "call_id": "unique-trigger-request-id",
  "data": {
    "answer": "Friday"
  }
}
```

Supported trigger/status pairs are:

- `user_response` -> `waiting_user`
- `external_event` -> `waiting_external`
- `scheduled_time` -> a due `retry_scheduled` task

Successful wakes clear the waiting fields and move the task to `ready`. The
trigger payload is preserved on the immutable event. Callers must reuse the
same `call_id` when retrying a delivery; replays do not add another event.
The HTTP response also includes `replayed`. Integration workflows must only
perform downstream side effects, such as placing an outbound call, when that
value is `false`.

Example first-delivery response:

```json
{
  "outcome": "ready",
  "trigger_type": "user_response",
  "replayed": false,
  "task": {}
}
```

An idempotent replay returns `outcome: "replayed"` and `replayed: true`.

## Durable side-effect dispatch

External actions are stored in `public.task_dispatches` before a worker calls
a provider. The four dispatch Edge Functions use the same authenticated
headers as the turn endpoints.

POST an idempotent intent to `enqueue-dispatch`:

```json
{
  "task_id": "00000000-0000-0000-0000-000000000000",
  "dispatch_type": "elevenlabs.outbound_call",
  "dedupe_key": "task-turn-7-callback",
  "payload": { "to_number": "+15555550100" },
  "max_attempts": 3
}
```

The same task and `dedupe_key` return the original row without replacing it.
A worker POSTs `{ "worker_id": "n8n-dispatcher" }` to `claim-dispatch`. It
receives `dispatch: null` or one exclusive five-minute lease. The same worker
then calls `complete-dispatch` with a JSON `result`, or `retry-dispatch` with
an `error` and `delay_seconds` between 1 and 3600.

Attempts are capped at `max_attempts` (1–10). The next claim recovers an
abandoned lease; exhausted work becomes `failed` instead of looping.

## Read-only Duffel MCP adapter

`functions/duffel-travel-mcp` is a stateless MCP v2 Streamable HTTP endpoint
implementing canonical travel-discovery operations over Duffel. It exposes
hotel suggestions/search/details/rates and flight place suggestions/search/
offer details. Every tool is commercially read-only and idempotent; quote,
hold, order, booking, cancellation, and payment operations are absent.

`functions/routestack-travel-mcp` is a second implementation of the canonical
flight discovery contract. It exchanges the configured RouteStack sandbox key
and secret for a short-lived partner JWT inside Supabase, renews before expiry,
and retries authentication once after a 401. n8n receives neither partner
credential. Revalidation, checkout, order, booking, payment, and cancellation
operations are not exposed.

Set `DUFFEL_ACCESS_TOKEN`, a separate `TRAVEL_MCP_API_KEY`, and an allowlist in
`TRAVEL_MCP_ALLOWED_ORIGINS`. MCP clients authenticate with the latter as a
Bearer token. Provider results are timestamped and bounded before returning to
the client. Never commit either secret.

## ElevenLabs post-call delivery

`elevenlabs-post-call` receives a `post_call_transcription` webhook after call
analysis completes. It does not use `X-Turn-Engine-Key`: it authenticates the
provider by verifying the `ElevenLabs-Signature` HMAC over the unmodified
request body. Configure these Edge Function values before deployment:

```text
ELEVENLABS_WEBHOOK_SECRET=<generated webhook signing secret>
ELEVENLABS_AGENT_ID=<expected agent ID>
```

The outbound call must include `task_id` in
`conversation_initiation_client_data.dynamic_variables`. Set
`trigger_type=user_response` when the call is collecting a user answer;
otherwise the receiver treats the callback as `external_event`.

The receiver derives its idempotent call ID from the ElevenLabs conversation
ID. Replays and deterministic task-state conflicts receive HTTP 200 so
provider retries cannot create a hot loop. Transient database failures return
5xx and remain retryable.
