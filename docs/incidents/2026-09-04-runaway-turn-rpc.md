# 2026-09-04 runaway turn RPC incident

## Status

Contained. Root caller not yet identified. Hosted turn processing remains
partially disabled pending investigation and hardening.

## Summary

During full pause/wake/callback testing, hosted PostgreSQL CPU became saturated
by repeated PostgREST RPC calls. The calls repeatedly attempted incompatible
task transitions and generated SQLSTATE `40001` errors:

- `stale task state: expected running, found new`
- `stale task state: expected new, found completed`

The error count reached approximately 359,000 in the one-hour log window. The
volume exhausted database/PostgREST resources and affected project performance.

## Impact

- Hosted database CPU was pegged.
- PostgREST exhausted its connection pool and restarted during the incident.
- Normal hosted turn processing became unreliable.
- Supabase displayed a resource-exhaustion warning.
- No evidence indicated task or event data loss.

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

These observations narrow the investigation but do not conclusively identify
the source.

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

## Active containment

The hosted database currently differs from migration-declared permissions:

- `advance_task`: API execution disabled, including `service_role`.
- `process_task_turn`: API execution disabled, including `service_role`.
- Stored task snapshots and events remain intact.

See `docs/turn-engine-runbook.md` for the exact containment and restoration SQL.

## Likely failure pattern

A caller repeatedly treated deterministic state conflicts as retryable. Because
requests used incompatible expected states, successful or previously completed
transitions could not satisfy later attempts. SQLSTATE `40001` mapped to HTTP
409 in the Edge Function helper, but some caller or direct RPC path continued
at extremely high frequency without bounded retries or backoff.

This is an inference from the observed errors and request rate. The original
caller remains unconfirmed.

## Follow-up work

- Correlate API Gateway request metadata with the incident window.
- Identify and disable the originating client or credential.
- Add a safe diagnostic gate if historical logs are insufficient.
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
