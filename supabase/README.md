# Turn engine

> **Operational notice (2026-09-04):** Hosted execution of `advance_task` and
> `process_task_turn` is temporarily revoked following a runaway RPC incident.
> Do not use hosted turn-processing endpoints until the restoration checklist
> in [`../docs/turn-engine-runbook.md`](../docs/turn-engine-runbook.md) is
> complete. Architecture and incident details are in
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
