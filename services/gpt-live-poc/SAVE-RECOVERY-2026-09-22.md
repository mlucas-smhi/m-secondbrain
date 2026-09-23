# Save errors and onboarding instruction continuity

Deployed 2026-09-22 America/Chicago, after the first fresh onboarding call.
No memory, identity, invite, or onboarding reset was performed. No personal
facts were inserted as a repair. Missing facts still require supported capture.

## Current revisions

- Memory: `litegraph-memory-poc--endpoint-repair-20260922`
  - Facade image: `ca773a2b28d9acr.azurecr.io/litegraph-memory-facade@sha256:c24a0d79ca3f03c1db0475ac2599c66f1c92a7440843860d470813611c3a32d7`
- Voice: `eleven-gptlive-poc--endpoint-repair-20260922`
  - Image: `ca773a2b28d9acr.azurecr.io/eleven-gptlive-poc@sha256:c0c18c0cace9d672568f45f55ddfc5a4f6f247ba937b23b7d180107522cb23ea`
- Previous voice: `eleven-gptlive-poc--agenda-recovery-20260922`
- Previous memory: `litegraph-memory-poc--save-recovery-20260922`

Built from the uncommitted working tree; the agent did not commit or push Git.
Both final revisions were healthy with 100% traffic and public health HTTP 200.
Effective environment values/secret references, volume configuration, and other
memory-app container images matched the pre-deployment snapshot. Azure CLI
added an empty value alongside the unchanged database secretRef; comparison
normalized that representation without changing the secret.

## Verified behavior

- Validation failures return actionable MCP `isError` results, not protocol
  failures. Backend errors preserve uncertain-commit/idempotent-retry semantics.
- A public missing-fields save probe was rejected before graph access/mutation
  and returned `invalid_graph_fields` plus `correct_arguments` guidance.
- A read-only fingerprint of sampled existing memory results was unchanged.
- 49 voice tests passed; 49 facade tests passed. Three optional real-LiteGraph
  integration tests were skipped in this run (no disposable server configured).
- Synthetic regressions cover anniversary date correction, employment links,
  trip/reporting relationships, scope preservation, redaction, unsupported
  local-tool routing, and first-time/returning post-tool instruction continuity.
- Git whitespace checks passed.

OpenAI Docs confirmed response-level instructions replace the session's
instructions for that response. Post-tool responses now include the full active
instructions plus their immediate direction; successful verification updates
that snapshot. The seven-topic itinerary remains intact, with explicit
assistant-led transitions and bounded recovery after save errors.

References: [Realtime overrides](https://developers.openai.com/api/reference/resources/realtime/client-events),
[MCP tool errors](https://modelcontextprotocol.io/specification/2025-06-18/server/tools#error-handling).

## Remaining acceptance / limitations

The subsequent live call failed at 2026-09-23 03:46:31 UTC with
`invalid_fact_endpoints`. The follow-up budget was available, but the model did
not repair the request. Raw arguments were not retained, so this does not prove
which endpoint variant caused the rejection.

The endpoint-repair revision advertises object/value exclusivity using oneOf,
explains bundle-local keys vs existing entity UUIDs, and returns separate
unknown-subject/object, missing-target, and conflicting-target errors with a
safe fact index/field location. Post-tool instructions explicitly request one
corrective attempt for repairable rejection and never bypass scope errors.
The controller's existing response cap and event ordering are unchanged.
This is a bounded model instruction, not a new deterministic repair engine.

Public checks verified the advertised schema and deliberately rejected
conflicting-target, missing-target, and unknown-subject inputs. No transaction
or synthetic memory insertion was performed. Local fake-graph tests verify a
separate relationship/date bundle and idempotent replay. Both current revisions
are healthy at 100% traffic; configuration and sampled-memory fingerprints
match the pre-deployment snapshot.

A real call must demonstrate both corrective saves and guided topic transitions.
Earlier rejected arguments were not logged; the patch does not establish the
specific malformed field behind every prior failed save. Only safe rejection
codes and safe field locations are logged going forward. No raw arguments or
exception messages are logged.

There is still no advertised onboarding checkpoint writer. In-call coverage,
graph persistence, and durable topic completion are distinct. The prompt does
not claim a checkpoint was persisted when only a memory save succeeded.
