# 2026-09-04 runaway turn RPC incident

## Status

Resolved and restored. The initiating client and immediate database caller are
identified. Hosted turn processing was restored to `service_role` only on
2026-09-05 after the non-retryable conflict fix, delivery replay gate, local
tests, and a monitored hosted canary passed.

## Summary

During full pause/wake/callback testing, hosted PostgreSQL CPU became saturated
by repeated PostgREST RPC calls. The calls repeatedly attempted incompatible
task transitions and generated SQLSTATE `40001` errors:

- `stale task state: expected running, found new`
- `stale task state: expected new, found completed`

The first one-hour view showed approximately 359,000 errors; the 24-hour view
later showed approximately 6.6 million Postgres log entries. The volume
exhausted database/PostgREST resources and affected project performance.

API Gateway evidence shows only three failing requests to
`/rest/v1/rpc/advance_task`, at 11:26:05, 11:28:19, and 11:29:16. Each returned
HTTP 504 and identified its client as
`Deno/2.1.4 (variant; SupabaseEdgeRuntime/1.74.3)`. This rules out millions of
independent HTTP calls and points to database-layer retry behavior.

## Impact

- Hosted database CPU was pegged.
- PostgREST exhausted its connection pool and restarted during the incident.
- Normal hosted turn processing became unreliable.
- Supabase displayed a resource-exhaustion warning.
- No evidence indicated task or event data loss.

## Caller attribution

- An n8n Cloud client initiated the test through
  `/functions/v1/create-task` at 11:24:50. Supabase identified the client as
  `node`, from an AWS address in Ashburn, Virginia.
- The immediate callers of the three failing `advance_task` requests were
  Supabase Edge Runtime instances, as shown by their Deno/SupabaseEdgeRuntime
  user agent.
- The API Gateway records had no authenticated Supabase user attached.

The available logs identify the systems in the call chain, but do not expose
which Edge Function produced each timed-out outbound RPC request.

## What was ruled out

- n8n showed no active execution corresponding to the continuing database
  traffic at the time it was inspected.
- Edge Function logs did not show matching continuing invocations.
- The repository's shared RPC helper performs one `fetch` per call and contains
  no polling loop.
- The database had no task trigger capable of recursively invoking the RPC.
- Terminating individual PostgREST sessions did not help; the caller caused new
  sessions to be used.
- Deleting an accidentally created extra Supabase secret API key did not stop
  the traffic, so it was not the credential used by the caller.

These observations rule out a high-frequency n8n HTTP retry loop as the direct
source of the millions of database errors.

## Containment timeline

Times are America/Chicago on 2026-09-04.

- Before 12:27 — repeated stale-state errors saturated the project.
- 12:27:15 — execution was revoked from `advance_task` and
  `process_task_turn` for `public`, `anon`, `authenticated`, and `service_role`.
- 12:27:15 — permission-denied entries confirmed the revocation reached active
  callers.
- 12:29:10 — the Supabase project/database received a fast shutdown and
  terminated existing connections during restart.
- After restart — no newer stale-state results appeared. The historical log
  backlog subsequently drained to no results.

## Restored permission state

Migration `20260905113000_restore_turn_engine_service_role.sql` restores
`advance_task`, `process_task_turn`, `wake_task`, and `wake_task_delivery` only
to `service_role`. `public`, `anon`, and `authenticated` remain denied. Stored
task snapshots and events remained intact throughout containment.

See `docs/turn-engine-runbook.md` for the exact containment and restoration SQL.

## Root cause

`advance_task` raises SQLSTATE `40001` for deterministic stale task state.
PostgreSQL reserves `40001` for `serialization_failure`, a transient condition
that database clients and transaction infrastructure may retry automatically.
The stale states were permanent for each request, so retries could never
succeed. Three timed-out RPC requests therefore amplified into millions of
database attempts.

This conclusion is supported by the three-request API Gateway count, the Edge
Runtime user agent, the HTTP 504 outcomes, and the much larger Postgres error
count. The exact component performing the automatic retry remains to be proven,
but the incorrect retryable SQLSTATE is the amplification trigger.

## Follow-up work

- [x] Replace SQLSTATE `40001` for stale task state with a non-retryable
  application error and preserve its HTTP 409 mapping at the Edge Function
  boundary.
- [x] Make wake delivery replays explicit so integration side effects can be
  gated atomically.
- [x] Configure the n8n webhook to acknowledge immediately, disable node
  retries, gate the ElevenLabs branch to new deliveries, and cap executions at
  one minute.
- [x] Restore transition execution only to `service_role` after 51 local
  assertions and a monitored hosted new-delivery/replay canary passed.
- Identify the exact Edge Function behind each of the three timed-out requests.
- Add bounded retries, backoff, non-retryable conflict handling, and workflow
  concurrency limits.
- Add request-rate and database-resource alerting.
- Represent the final RPC permission state in a new migration.
- Run local tests, then one monitored hosted canary.
- Restore only `service_role` execution after the exit criteria are met.

## Lessons so far

- Idempotent database operations do not protect against unlimited calls with
  changing call IDs or permanently invalid expected states.
- A database restart clears connections but does not remove the source of
  repeated requests.
- Revoking a narrow function permission is a fast, data-preserving circuit
  breaker.
- Log timestamps—not the visible volume of buffered rows—determine whether an
  incident is still active.
