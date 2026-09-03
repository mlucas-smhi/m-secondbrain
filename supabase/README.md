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
