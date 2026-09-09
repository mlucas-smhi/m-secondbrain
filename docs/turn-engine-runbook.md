# Turn engine operations runbook

## Current safety state

As of 2026-09-05, hosted execution is restored only to `service_role` by
`20260905113000_restore_turn_engine_service_role.sql`. `public`, `anon`, and
`authenticated` cannot execute the transition RPCs. The preceding containment
migration remains in history and documents the reproducible circuit breaker.

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

## Dispatch worker rules

Run outbound side effects in a workflow separate from **Wake Task**:

1. Call `claim-dispatch` with a stable worker ID.
2. Stop successfully when the response contains `dispatch: null`.
3. Route only recognized `dispatch_type` values to their provider node.
4. On provider success, call `complete-dispatch` with the same worker ID.
5. On a transient provider error, call `retry-dispatch` once with a bounded
   delay. Do not add an n8n node retry around that request.
6. Treat 400, 401, 403, 404, 409, and 422 as terminal configuration or state
   errors requiring inspection, not automatic retry.

Each claim is a five-minute lease. If a workflow crashes, a later claim
recovers the abandoned row. Recovery increments the attempt count when another
worker claims it; a row at `max_attempts` becomes `failed`.

## Task-step worker rules

The task layer claims executable steps rather than parent tasks:

1. Call `claim-task-step` with a stable worker ID, bounded lease, and a non-empty
   `supported_step_types` capability allowlist.
2. Stop successfully when the response contains `step: null`.
3. Route exactly once on the returned `step_type`.
4. Pass the opaque `claim_token` when completing the step.
5. Pass that token to `fail-task-step` when a handler fails; it records the
   error and applies the step's attempt budget.
6. Reuse the same completion or failure idempotency key if the response is lost.
7. Never claim another step inside the same workflow execution.

For `research.travel`, complete the step only with a valid `research.v1`
envelope. Preserve factual evidence in `sources`, use stable keys for options,
and make `recommendation.option_key` reference one of those options. Provider
responses may be retained inside option attributes when useful, but the durable
contract must not depend on a provider-specific response shape.

Dependencies are satisfied only by completed prerequisite steps. An expired
lease is recovered on the next claim and consumes the existing attempt; the
step is failed when its attempt budget is exhausted. A worker must not continue
after its lease expires, and external effects must still go through the durable
dispatch outbox.

## Tool adapter rules

Research workers resolve declared capabilities through active `tool_adapters`.
Prefer structured MCP or API inventory over open-web discovery. Keep credentials
in n8n or a secret manager; database adapter rows contain only `credential_ref`.

Every tool invocation must create a `task_step_tool_runs` record with a stable
idempotency key. Store bounded request/evidence metadata in Postgres and put
large or provider-specific payloads behind `result_ref`. A `read` requirement
never authorizes a hold, reservation, purchase, cancellation, or message.
OpenAI may rank and explain tool evidence, but it must not fabricate inventory
or expand the step's declared tool authority.

After claiming a step, call `begin-task-step-tool-run` with its `step_id`, active
`claim_token`, declared capability, canonical operation, stable idempotency key,
and a bounded `request_summary`. The response contains the durable tool-run ID
and the currently selected adapter. Replaying the same input returns the same
run; reusing the key with different input is rejected. Pass that run ID into the
provider search as `tool_run_id`. Successful protected-result storage marks the
tool run completed and returns only its opaque `tool-result:<uuid>` reference.
If a replayed begin call returns a completed run, call
`read-task-step-tool-result` with the active claim and its `result_ref`; never
repeat the provider search. The read endpoint returns canonical evidence only,
marks expired results explicitly, and never returns protected provider handles.

Call `resolve_task_step_tool_adapter(step_id, capability)` immediately before a
tool run. Do not branch on provider names in the task workflow. The returned
adapter supplies transport/configuration and an external `credential_ref`;
provider adapters must implement the same canonical operation names and input
contracts. Use `selection_priority` to choose the default. Disable a degraded
provider to fail over new resolutions; use `preferred_adapter_id` only when a
task has a genuine provider constraint.

Flight search results must conform to `travel.flight_search.v1`. Do not pass
raw inventory payloads, provider credentials, fare-source codes, or other
opaque booking tokens to an LLM or general n8n branch. Persist transactional
references separately when a later approved execution flow needs them.

Pass the current `task_step_tool_runs.id` as `tool_run_id` when invoking flight
search. The adapter stores provider execution handles in the service-role-only
`task_step_tool_results` table and returns a `tool-result:<uuid>` reference.
Treat `valid_until` as a hard boundary: re-search or revalidate after expiry.
Never unlock an approval or reservation step from a result with missing ISO
currency, non-positive price, incomplete segments, broken segment continuity,
or invalid timestamps.

The initial travel adapter is `functions/duffel-travel-mcp`, a stateless MCP v2
Streamable HTTP server. It exposes canonical, read-only hotel and flight
discovery tools. Flight search creates Duffel offer-request search records but
cannot create an order or payment. Configure these Edge Function secrets before deploy:

```text
DUFFEL_ACCESS_TOKEN=<Duffel test or live access token>
TRAVEL_MCP_API_KEY=<separate high-entropy MCP client key>
TRAVEL_MCP_ALLOWED_ORIGINS=https://seacormarine.app.n8n.cloud
```

The n8n MCP client sends `Authorization: Bearer <TRAVEL_MCP_API_KEY>` to:

```text
https://apozwrkkomowdaocwfmm.supabase.co/functions/v1/duffel-travel-mcp
```

Do not reuse the Duffel token as the MCP client key. Quote, hold, order,
booking, cancellation, and payment operations are intentionally not exposed.

The RouteStack sandbox adapter is `functions/routestack-travel-mcp`. Configure
`ROUTESTACK_BASE_URL`, `ROUTESTACK_API_KEY`, and `ROUTESTACK_API_SECRET` in
Supabase. It performs the documented HMAC partner-token exchange internally
and renews the short-lived JWT before expiry or once after a 401. n8n continues
to authenticate with `TRAVEL_MCP_API_KEY`. The adapter exposes read-only flight,
hotel, and car location/search operations. Hotel and car searches return
canonical `travel.hotel_search.v1` and `travel.car_search.v1` packets. Pass the
current `task_step_tool_runs.id` as `tool_run_id` to store provider execution
handles behind a `tool-result:` reference. RouteStack's revalidation, checkout,
order, booking, payment, and
cancellation operations are not registered.

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

grant execute on function public.wake_task_delivery(
  uuid, text, text, jsonb, text
) to service_role;
```

Do not grant any transition function to `public`, `anon`, or `authenticated`.

After restoration, send one canary request and verify exactly the expected task
events before allowing automated traffic.

Restoration completed on 2026-09-05. The hosted canary task
`a7cb2494-de5f-40d1-bc1a-0fb418f65135` produced one new wake with
`replayed: false`; the same `call_id` then returned `replayed: true`. n8n routed
the first response to its true branch and the replay to its false branch.
ElevenLabs was not invoked, and temporary pinned test data was removed before
the corrected workflow version was published.

## Required hardening before restoration

- Cap retries at a small explicit number.
- Use exponential backoff with jitter for transient failures.
- Never retry HTTP 400, 403, 409, or 422 responses automatically.
- Reuse the same `call_id` for a retry of the same delivery.
- Generate a new `call_id` only for a genuinely new transition.
- Add a workflow-level execution timeout and concurrency limit.
- Log caller identity, endpoint, task ID, call ID, outcome, and request ID.
- Alert on abnormal RPC rate, stale-state rate, or database CPU.
