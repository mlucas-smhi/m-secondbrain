# Turn engine

The turn engine stores the current task snapshot in `public.tasks` and its
append-only history in `public.task_events`.

All task progress should go through `public.advance_task`. The function:

- locks one task for the duration of the turn;
- optionally rejects stale callers with `p_expected_status`;
- treats a repeated non-null `p_call_id` as an idempotent replay;
- validates the lifecycle transition and allowed patch fields;
- updates the task and appends its event in the same transaction.

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

The endpoint is internal: requests must use the service-role credential. Never
put that credential in a browser, mobile app, or other untrusted client.

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
