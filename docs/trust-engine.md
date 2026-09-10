# Trust engine POC

## Boundary

The trust engine is the authorization boundary for 11. The language model may
classify intent and supply context, but it cannot grant authority or override a
decision.

```text
11 / worker
     |
     | actor + session + action + purpose
     v
security-check
     |
     +-- versioned policy (Git source, deployed snapshot)
     +-- actors, roles, sessions and grants (Supabase)
     +-- presence and identity evidence (Supabase session state)
     v
ALLOW | ALLOW_WITH_CONSTRAINTS | DENY | CHALLENGE
CONFIRM | REDACT | DEFER | ESCALATE
```

Supabase owns operational identity, authority, sessions, grants, and audit.
LiteGraph will own conversational relationships and recall. A future Memory
Gateway must call this trust boundary before querying LiteGraph and must filter
unauthorized data before it enters an LLM context.

## POC rules

- Deny unknown actions and inactive identities.
- Challenge when authentication assurance is insufficient.
- Require both clearance and compartment membership.
- Treat `read`, `use`, `disclose`, and `write` as distinct permissions.
- Private information is owner-only in the POC.
- Defer spoken disclosure when an unknown person is present.
- Require a matching, unexpired grant for confirmation-gated actions.
- A task grant is narrow, expiring, constrained, and never inherited from the
  session that created the task.
- Record every result with reason codes, policy version, and policy hash.

## Memory-provider seam

The Memory Gateway contract is provider-neutral:

```text
get_context(authorized request)
search(authorized request)
propose(candidate memory)
supersede(old memory, new memory)
forget(memory id)
```

Git may supply curated POC records. Replacing that adapter with LiteGraph must
not change callers, authorization policy, or stable Supabase references.

The POC endpoint is `functions/memory-context`. It accepts an authenticated
session, subject, query, purpose, and requested permission. The Git adapter
finds candidate synthetic records inside the trusted service; the endpoint
calls `security_check` for every candidate and returns only authorized fields.
Denied records contribute neither content nor identifying metadata to the
response. `DEFER` or `CHALLENGE` may be returned as handling guidance only when
no authorized context is available.
