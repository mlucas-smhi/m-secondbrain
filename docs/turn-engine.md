# Turn engine architecture

## Purpose

The turn engine gives Alfred durable, deterministic task state across calls,
callbacks, user decisions, timers, and external events. Supabase owns task
state and transition integrity. n8n connects asynchronous systems and wakes a
task when its dependency is satisfied. ElevenLabs supplies the conversational
and outbound-call interface.

This document describes the system as implemented on 2026-09-07. It is not a
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
replays. The restoration and dispatch outbox pass 70 local assertions.
Restoration also passed one monitored hosted canary covering a new wake and a
same-call-ID replay. No ElevenLabs call was placed during the canary.

The **Dispatch Task Actions** n8n workflow is published on a 30-second
schedule. A hosted outbound-call canary completed with clear bidirectional
audio after the ElevenLabs agent input and output formats were set to
`ulaw_8000`. The signed `elevenlabs-post-call` receiver is deployed and has
successfully moved a hosted `waiting_external` task to `ready`. The agent-level
legacy n8n webhook override was removed so the agent inherits the workspace
Supabase receiver.

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
             -----------------------------------------
             |               |                       |
             v               v                       v
       public.tasks    public.task_events    public.task_dispatches
       current state   append-only history   durable side-effect queue
             |
             v
       public.task_steps <-> public.task_step_dependencies
       leased work units     explicit execution graph

Paused dependency -> n8n webhook -> wake-task -> task becomes ready

Task decision -> enqueue-dispatch -> n8n worker -> external provider
                                      |
                               complete or retry
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
- `20260905160000_add_task_dispatch_outbox.sql`
- `20260905161000_recover_stale_task_dispatches.sql`
- `20260908160000_add_task_execution_graph.sql`

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
| `create-task-plan` | Atomically create a thread, task, execution graph, decisions, and closure records. |
| `claim-task-step` | Lease the next runnable dependency-safe work step. |
| `complete-task-step` | Complete a step using its active claim token. |
| `fail-task-step` | Record an error and requeue or terminally fail the claimed step. |
| `resolve-task-decision` | Resolve a declared option and satisfy its gate atomically. |
| `enqueue-dispatch` | Idempotently record an external side-effect intent. |
| `claim-dispatch` | Lease the next due intent to one worker. |
| `complete-dispatch` | Record successful provider delivery. |
| `retry-dispatch` | Delay a failed attempt or mark exhausted work failed. |
| `elevenlabs-post-call` | Verify a signed post-call transcript and wake its task. |

`process-task` is the preferred deterministic turn endpoint. Narrow endpoints
remain useful for controlled testing and specialized orchestration.

Every mutation requires a caller-owned `call_id`. A retry must reuse the same
ID. A distinct ID represents a distinct operation and can create a new event.

### n8n

The current n8n project contains the published **Wake Task** workflow
(`xDPbVm9ngGIeuhJB`). Its path is:

```text
Webhook --immediate 2xx--> sender
    |
    v
Supabase wake-task -> replayed == false -> continue task orchestration
                   -> replayed == true  -> stop
```

n8n is the integration and waiting layer, not the task state machine. It should
react to one trigger and make a bounded number of calls. It must not poll a
state transition in a tight loop. The webhook should acknowledge immediately,
and the outbound-call branch must run only when `replayed` is `false`.

The wake workflow has a one-minute execution timeout. Node-level retries are
disabled and errors stop the workflow.

The published **Dispatch Task Actions** workflow (`9hKGWXWH8btLiaUg`) runs
every 30 seconds. It claims at most one dispatch, routes by dispatch type,
calls the provider, and records completion or a bounded retry. Its
`elevenlabs.outbound_call` route has passed a hosted bidirectional audio
canary.

The dispatch worker claims one row, performs exactly the declared side effect,
then completes it or schedules a bounded retry. Claims are exclusive. A claim
older than five minutes is abandoned; the next claim operation either returns
it to the queue or marks it failed when its attempt budget is exhausted.

The planned task-runner workflow claims `task_steps`, not parent tasks. Each
step has a stable type and idempotency key plus an opaque claim token, bounded
lease, and attempt budget. A step is runnable only after all explicit
prerequisites complete. The parent `tasks` row remains the goal-level summary;
step outputs and events provide the execution detail.

Research workers return the versioned `research.v1` envelope: a summary,
normalized options, one recommendation tied to an option key, cited sources,
and optional constraints and caveats. The completion transaction validates this
contract before changing the step to `completed`, so malformed research cannot
unlock a briefing, decision request, or execution step.

Research evidence comes from a provider-neutral tool layer. `tool_adapters`
register configured MCP, API, native, or browser adapters by capability without
storing credentials. `task_step_tool_requirements` declares the exact capability
and authority mode a step may use. `task_step_tool_runs` records bounded request
metadata, external run IDs, evidence metadata, and an external result reference.
OpenAI compares and explains this evidence; it is not treated as the inventory
system of record. Atomic plans may include `tool_requirements`, keyed to their
declared steps. Those requirements are validated and inserted in the same
transaction as the thread, task, dependencies, and decision gates, and they are
returned in replay-safe plan snapshots.

The first adapter implementation is a stateless MCP v2 Streamable HTTP server
over Duffel. Its tool names and inputs are canonical travel operations rather
than provider-specific contracts. It exposes read-only hotel discovery plus
flight place suggestion, flight search, and offer refresh. It has no quote,
hold, order, booking, cancellation, payment, or messaging capability.

Workers resolve a step's declared capability with
`resolve_task_step_tool_adapter`. Resolution is scoped to the task workspace,
requires an active adapter, and uses explicit selection priority. A preferred
adapter pins a step when truly required; otherwise disabling one adapter causes
the next active provider for that capability to be selected without changing
the task, graph, or n8n routing contract.

RouteStack is implemented as a second flight-discovery adapter. Its sandbox
partner key and secret remain in Supabase; the adapter performs HMAC token
exchange and JWT renewal internally. It presents the same canonical flight
tool names as Duffel and intentionally omits RouteStack's checkout, order,
booking, payment, revalidation, and cancellation surface.

Both flight adapters return `travel.flight_search.v1`: a bounded list of
offers with normalized price, duration, stops, seat availability, fare brand,
and flight segments. Raw provider responses, credentials, and opaque booking
tokens are excluded from the worker-facing result. Provider-specific execution
references belong in protected tool-run storage when transactional operations
are added later.

Initiator identity, scoped authority, approvals, and closure recipients are
stored separately from conversational context. Memory is referenced through
provider-neutral `task_memory_refs`; GitHub can remain one provider during the
transition but is not part of the execution schema.

### ElevenLabs

ElevenLabs is the voice interaction layer. A configured agent and assigned
phone number can make callbacks after n8n receives a wake event. Provider IDs,
phone numbers, credentials, and secrets belong in provider configuration or a
secret manager, not in repository documentation.

Outbound calls include the task ID in conversation dynamic variables. After
analysis completes, ElevenLabs sends a signed `post_call_transcription` event
to `elevenlabs-post-call`. The Edge Function verifies the HMAC signature over
the raw body, restricts delivery to the configured agent, and wakes the task
with an idempotency key derived from the conversation ID. It stores a bounded
transcript and analysis summary but omits raw telephony metadata and phone
numbers.

The function requires two additional Edge Function secrets/config values:

```text
ELEVENLABS_WEBHOOK_SECRET=<generated webhook signing secret>
ELEVENLABS_AGENT_ID=<expected agent ID>
```

Configure the ElevenLabs workspace webhook URL as:

```text
https://apozwrkkomowdaocwfmm.supabase.co/functions/v1/elevenlabs-post-call
```

Enable `post_call_transcription`; audio delivery is not required. A callback
that represents an answer should use dynamic variable
`trigger_type=user_response`; other values map to `external_event`.

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

The current database test suite contains 126 assertions. Hosted transition
access is restored only to `service_role`; follow the operations runbook for
hosted canaries.
