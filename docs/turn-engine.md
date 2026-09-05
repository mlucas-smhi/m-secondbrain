# Turn engine architecture

## Purpose

The turn engine gives Alfred durable, deterministic task state across calls,
callbacks, user decisions, timers, and external events. Supabase owns task
state and transition integrity. n8n connects asynchronous systems and wakes a
task when its dependency is satisfied. ElevenLabs supplies the conversational
and outbound-call interface.

This document describes the system as implemented on 2026-09-04. It is not a
claim that every planned automation is production-ready.

## Current hosted status

Hosted turn processing was restored on 2026-09-05 after the 2026-09-04 runaway
RPC incident. These database functions are executable through the API only by
`service_role`:

- `public.advance_task`
- `public.process_task_turn`
- `public.wake_task`
- `public.wake_task_delivery`

`public`, `anon`, and `authenticated` remain denied. Deterministic task-state
conflicts use non-retryable SQLSTATE `PT409`, and the Edge Function maps them
to HTTP 409. A delivery-aware wrapper atomically identifies idempotent wake
replays. The restoration passed 51 local assertions and one monitored hosted
canary covering a new wake and a same-call-ID replay. No ElevenLabs call was
placed during the canary.

## Components

```text
Authorized caller
       |
       | POST + X-Turn-Engine-Key
       v
Supabase Edge Functions
       |
       | service-role RPC call
       v
PostgREST -> PostgreSQL functions
                    |
             -----------------
             |               |
             v               v
       public.tasks    public.task_events
       current state   append-only history

Paused dependency -> n8n webhook -> wake-task -> task becomes ready
                                      |
                                      +-> optional ElevenLabs callback
```

### Supabase

Hosted project reference: `apozwrkkomowdaocwfmm`.

`public.tasks` is the current task snapshot. `public.task_events` is the
immutable transition and provenance history. Database functions lock the task,
validate transitions, update its snapshot, and append the corresponding event
in a transaction.

The migration history is in `supabase/migrations/`:

- `20260903010000_add_turn_engine.sql`
- `20260903190000_add_create_task.sql`
- `20260903200000_add_process_task_turn.sql`
- `20260903230000_add_wake_task.sql`
- `20260904183000_make_task_conflicts_non_retryable.sql`
- `20260905100000_add_wake_task_delivery.sql`
- `20260905113000_restore_turn_engine_service_role.sql`

### Edge Functions

All endpoints accept `POST` JSON and require:

```text
X-Turn-Engine-Key: <TURN_ENGINE_API_KEY value>
Content-Type: application/json
```

`TURN_ENGINE_API_KEY` is a Supabase Edge Function environment secret. It is
not a Supabase API key and its value must never be committed. The Edge Function
runtime retains `SUPABASE_SERVICE_ROLE_KEY` and uses it for database RPCs.

Implemented endpoints:

| Function | Responsibility |
| --- | --- |
| `create-task` | Atomically create a `new` task and `task.created` event. |
| `run-task-turn` | Move a `new` or `ready` task to `running`. |
| `wait-for-user` | Move a `running` task to `waiting_user`. |
| `resume-task` | Record an answer and move `waiting_user` to `ready`. |
| `complete-task` | Complete a `running` task. |
| `decide-task-turn` | Deterministically pause or complete a running turn. |
| `process-task` | Start and decide a turn atomically in one RPC. |
| `wake-task` | Resume a paused task from a user, external, or timer trigger. |

`process-task` is the preferred deterministic turn endpoint. Narrow endpoints
remain useful for controlled testing and specialized orchestration.

Every mutation requires a caller-owned `call_id`. A retry must reuse the same
ID. A distinct ID represents a distinct operation and can create a new event.

### n8n

The current n8n project contains the published **Wake Task** workflow
(`xDPbVm9ngGIeuhJB`). Its intended path is:

```text
Webhook --immediate 2xx--> sender
    |
    v
Supabase wake-task -> replayed == false -> optional ElevenLabs outbound call
                   -> replayed == true  -> stop
```

n8n is the integration and waiting layer, not the task state machine. It should
react to one trigger and make a bounded number of calls. It must not poll a
state transition in a tight loop. The webhook should acknowledge immediately,
and the outbound-call branch must run only when `replayed` is `false`.

The published workflow implements that shape and has a one-minute execution
timeout. Node-level retries are disabled and errors stop the workflow.

### ElevenLabs

ElevenLabs is the voice interaction layer. A configured agent and assigned
phone number can make callbacks after n8n receives a wake event. Provider IDs,
phone numbers, credentials, and secrets belong in provider configuration or a
secret manager, not in repository documentation.

## Task lifecycle

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

Typical pause and resume:

```text
new -> running -> waiting_user
                       |
                 user response
                       v
                    ready -> running -> completed
```

## Trust boundaries

- External callers receive only the dedicated turn-engine key.
- The Supabase service-role key stays inside trusted server runtimes.
- Direct browser/client access to database RPCs is unsupported.
- Database functions are `SECURITY INVOKER` and executable only by explicitly
  granted roles.
- Call IDs provide idempotency but do not replace caller-side retry limits.
- GitHub remains the canonical durable knowledge store; Supabase stores live
  orchestration state and event history.

## Verification

With the local Supabase stack running:

```sh
supabase test db supabase/tests/turn_engine.sql
```

The current database test suite contains 42 assertions. Hosted testing must
remain disabled until containment is deliberately lifted according to the
operations runbook.
