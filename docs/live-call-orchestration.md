# Live call orchestration

## Goal

Allow 11 to handle concurrent private calls and, when policy permits, offer a
controlled live merge such as: "Curtis just called. Want me to patch him in?"

Calling 11 must continue to feel like a normal call. Conference machinery is
an implementation detail and must never place unrelated callers together by
default.

## Session model

One public phone number may have many simultaneous live sessions. Each incoming
or outgoing call creates an isolated session with its own instance of 11:

```text
session A: Michael + 11-A
session B: Curtis  + 11-B
```

A session may later become a private conference, but sessions are never merged
implicitly. The durable thread and task engine survive after the telephone
session ends; the live-call registry does not replace them.

## Responsibilities

```text
Twilio                 bridge/control plane          durable systems
------                 --------------------          ---------------
call legs        --->  live session registry   --->  threads/interactions
conference mixer --->  participant controller  --->  trust sessions/evidence
status callbacks --->  merge state machine      --->  decisions/audit
```

- Twilio owns telephone legs, dialing, conference mixing, and participant
  status events.
- The bridge owns session isolation, 11's media connection, participant labels,
  and provider-neutral call control.
- The trust engine decides whether an interruption, disclosure, invitation, or
  merge is allowed. A language model cannot grant this authority.
- The thread engine records why each person called, who is waiting, decisions,
  actions, and closure.

## Live registry

The first implementation needs an ephemeral registry with these logical
records. Supabase may back the POC, but the contract must not depend on Twilio
field names.

### `live_call_sessions`

- `id`
- `workspace_id`
- `provider`
- `provider_call_ref`
- `conversation_ref`
- `thread_id`
- `direction`
- `status`: `ringing | active | held | merging | ended | failed`
- `room_ref` (nullable)
- `started_at`, `ended_at`, `heartbeat_at`

### `live_call_participants`

- `id`
- `session_id`
- `provider_leg_ref`
- `participant_label`
- `actor_ref` (nullable until identified)
- `phone_ref` (protected/tokenized)
- `role`: `caller | owner | guest | agent`
- `identity_state`: `unknown | claimed | challenged | evidenced | verified`
- `joined_at`, `left_at`

### `live_call_merge_requests`

- `id`
- `requesting_session_id`
- `target_session_id`
- `requested_by_actor_ref`
- `target_actor_ref`
- `reason_summary`
- `status`: `proposed | offered | approved | denied | expired | executing |
  joined | failed | separated`
- `decision_id` and `policy_evaluation_id`
- `idempotency_key`
- `expires_at`, `created_at`, `resolved_at`

Provider Call SIDs and Stream SIDs are mappings on these records, not primary
business identifiers.

## Patch-in state machine

1. Curtis calls 11 and receives a new isolated session.
2. 11-B identifies Curtis, determines his purpose, and creates or associates a
   durable thread.
3. The control plane notices Michael has another active session.
4. Policy evaluates whether 11 may disclose Curtis's presence and interrupt
   Michael. If not, 11 takes a message or schedules follow-up.
5. If allowed, a merge request is created with a short expiry and a stable
   idempotency key.
6. 11-A says, "Curtis just called about the firewall quote. Want me to patch
   him in?"
7. Michael's explicit answer resolves the decision. Silence, ambiguity, tool
   failure, or timeout is not approval.
8. On approval, the bridge moves or dials the authorized participant legs into
   one private room. 11 remains as a participant.
9. Join callbacks must confirm all intended legs before 11 announces that the
   parties are connected.
10. Leave callbacks update both live sessions and their durable interactions.

## Privacy and trust invariants

- Private and isolated is the default for every new call.
- Caller identity, the reason for calling, and even the fact that a person is
  present may be sensitive disclosures checked by policy.
- Both the requester and target session must be bound to the same workspace
  before a merge can be considered.
- Joining a call is a separate permission from calling, reading context, or
  executing a task.
- Voice evidence is calculated from an isolated participant leg, never mixed
  conference audio.
- A voice `MATCH` is supporting evidence only; it does not authorize a merge.
- Every merge command is idempotent, expires, and is reconciled against Twilio
  status callbacks.
- No active session may be selected merely because it is the only in-memory
  audio buffer. Verification and call-control tools require a session-bound,
  short-lived capability once concurrency is enabled.
- A failed bridge, agent, trust check, or callback leaves callers separated.

## 11 tool boundary

11 should receive narrow tools rather than raw Twilio access:

- `get_live_call_context`
- `propose_call_merge`
- `answer_call_merge`
- `separate_call_participant`

The bridge resolves provider references and performs Twilio operations only
after the trust engine authorizes the exact action. Tool responses distinguish
`proposed`, `approved`, `joined`, and `failed`; an accepted proposal is not
reported as a completed connection.

## Delivery sequence

1. Add the live registry and signed Twilio status-callback ingestion.
2. Prove two simultaneous calls remain isolated and receive distinct 11
   conversations.
3. Replace the single-active-buffer verification shortcut with session-bound
   capabilities.
4. Create a conference-first test route behind a feature flag.
5. Add a second allow-listed test participant and manually exercise an approved
   three-way join while 11 remains present.
6. Exercise denial, timeout, duplicate callback, participant hang-up, and
   partial-join failures.
7. Connect merge decisions and interaction summaries to durable threads.

No automatic interruption or production patch-in is enabled until the complete
failure matrix passes.
