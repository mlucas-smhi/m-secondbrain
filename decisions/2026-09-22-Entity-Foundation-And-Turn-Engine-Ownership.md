---
type: decision
status: adopted
importance: high
created: 2026-09-22
updated: 2026-09-22
confidence: 1.0
---

# Entity foundation and Turn Engine ownership

## Decision

Adopt the initial 19-family coverage map and principles in
[Entity foundation](../docs/entity-foundation.md) as the starting point for 2's
detailed entity-definition exercise.

Build a best-effort comprehensive foundation up front, while allowing entities
and vocabulary to expand through data and automatic validation. Fix integrity,
identity, security, provenance, and temporal rules, not the limits of what 2
can learn. Routine classification must not create a human approval bottleneck.

Tasks/commitments, decisions, bookings/transactions, and interactions/threads
(families 15–18) belong to the Turn Engine. Memory holds linked context and
references, not a competing operational source of truth. External providers
remain authoritative evidence of actual execution outcomes.

Task IDs persist across phone, SMS, email, and other channels. Interactions have
their own IDs and link to stable task/thread IDs. Conversations can resume
existing work or touch multiple tasks. Read live operational state before
acting and update memory projections after confirmed changes.

## Reasoning

2 should retain meaningful particulars about people naturally, retrieve linked
context, and help move ongoing work forward wherever the conversation resumes.
A rigid exhaustive schema would constrain learning; ungoverned labels would
fragment meaning. A versioned extensible registry balances both concerns.

## Boundaries

This adopts a design baseline, not a finalized ontology, database migration,
or deployed feature. Detailed definitions, machine-readable registry, and
acceptance tests remain to be completed. The Git-note taxonomy is unchanged.
The earlier fixed-edge-only design is replaced as a future design direction;
existing runtime tool allowlists remain enforced until deliberately updated.

## Validation

Use the fresh onboarding test plus cross-channel task continuity scenarios.
Inspect actual stored records and authoritative task transitions, not only
the agent's verbal claims. No commit, deployment, or data reset is implied by
recording this agreement.
