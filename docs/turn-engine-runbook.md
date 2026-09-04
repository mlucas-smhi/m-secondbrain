# Turn engine operations runbook

## Current safety state

As of 2026-09-04, hosted execution of `advance_task`, `process_task_turn`, and
`wake_task` is intentionally disabled. Migration
`20260904183000_make_task_conflicts_non_retryable.sql` makes that safety state
reproducible while the incident is resolved.

## Normal deployment inputs

Required Edge Function environment values:

- `SUPABASE_URL` — supplied by Supabase.
- `SUPABASE_SERVICE_ROLE_KEY` — supplied to the trusted runtime by Supabase.
- `TURN_ENGINE_API_KEY` — a separately generated high-entropy shared secret.

Never store secret values in Git, n8n workflow JSON, screenshots, or this
runbook. n8n should reference a stored credential.

## Safe test order

Use a new task and a unique call ID for each distinct operation. Reuse the same
call ID only to test idempotent replay.

1. Create a task with `create-task`.
2. Process it once with `process-task`, choosing either `waiting_user` or
   `completed`.
3. If paused, wake it once with `wake-task` and a matching trigger type.
4. Confirm the task snapshot and ordered event history.
5. Stop after the expected response. Do not configure automatic retries while
   validating a new path.

Never call `wait-for-user` on a `new` task. It requires `running`. Prefer the
atomic `process-task` endpoint, which starts and pauses the task in one
transaction.

## Caller identification

Postgres sees PostgREST as an internal connection, so `pg_stat_activity` alone
cannot identify the original internet client. Use this order:

1. In Supabase Unified Logs, select **API Gateway**.
2. Search the incident window for:
   - `/rest/v1/rpc/advance_task`
   - `/rest/v1/rpc/process_task_turn`
   - `/rest/v1/rpc/wake_task`
3. Inspect source IP, user agent, request ID, JWT role/key type, and referrer.
4. Compare the fingerprint with n8n executions, Edge Function logs, browser
   testers, and local scripts.
5. If historical metadata is insufficient, deploy a non-mutating diagnostic
   gate that records request metadata and rejects processing. Keep the real
   transition RPCs disabled while collecting that single probe.

## Emergency containment

The following SQL is the containment currently active in hosted Supabase:

```sql
revoke execute on function public.advance_task(
  uuid, text, text, text, text, jsonb, text, jsonb, uuid
) from public, anon, authenticated, service_role;

revoke execute on function public.process_task_turn(
  uuid, text, text, text, text, text, text, text
) from public, anon, authenticated, service_role;

revoke execute on function public.wake_task(
  uuid, text, text, jsonb, text
) from public, anon, authenticated, service_role;
```

This preserves task and event data while stopping those function bodies from
executing. Existing callers may receive permission errors until they stop.

If database resources remain exhausted after containment, restart the Supabase
project while the revocations remain active. A restart terminates current
connections but does not stop a caller from reconnecting; the permission gate
is what prevents renewed task processing.

## Verification after containment

- Refresh Unified Logs and compare event timestamps, not the total row count.
- Old rows may continue appearing while the logging pipeline drains.
- Confirm no new stale-state or permission errors arrive after the containment
  or restart timestamp.
- Confirm database CPU and connection utilization return toward baseline.
- Check that n8n has no running or repeatedly created executions.

## Restoring service

Do not restore access until all of the following are true:

- The caller or credential path has been identified and disabled or corrected.
- Automatic retries are bounded and use backoff.
- A stale-state response is treated as terminal for that delivery, not retried.
- The workflow cannot route an error back into its own trigger.
- A controlled local test passes.
- A single hosted canary is ready with monitoring open.

Restore only the intended server role:

```sql
grant execute on function public.advance_task(
  uuid, text, text, text, text, jsonb, text, jsonb, uuid
) to service_role;

grant execute on function public.process_task_turn(
  uuid, text, text, text, text, text, text, text
) to service_role;

grant execute on function public.wake_task(
  uuid, text, text, jsonb, text
) to service_role;
```

Do not grant either function to `public`, `anon`, or `authenticated`.

After restoration, send one canary request and verify exactly the expected task
events before allowing automated traffic.

## Required hardening before restoration

- Cap retries at a small explicit number.
- Use exponential backoff with jitter for transient failures.
- Never retry HTTP 400, 403, 409, or 422 responses automatically.
- Reuse the same `call_id` for a retry of the same delivery.
- Generate a new `call_id` only for a genuinely new transition.
- Add a workflow-level execution timeout and concurrency limit.
- Log caller identity, endpoint, task ID, call ID, outcome, and request ID.
- Alert on abnormal RPC rate, stale-state rate, or database CPU.
