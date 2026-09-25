# 11 private baseline / 12 clean onboarding

**Superseded design record.** The user rejected the keypad-first approach below
before deployment. `OWNER_CODE_MODE` must remain disabled. Ordinary recognized
owner calls must not start with a code challenge. Follow
[PHASE1-BASELINE.md](PHASE1-BASELINE.md) for the current migration and activation
plan. The older requirements below are retained only as implementation history,
not current rollout authorization or prerequisites.

## Approved boundaries

- 11 receives M's GitHub knowledge baseline in a separate private workspace,
  tenant and graph. Default imports to level 3 / owner_private.
- 12 starts with empty memory and a separate workspace/tenant/credential. The
  user will create 12. Do not duplicate M's personalization into its prompt.
- Same phone number used for testing does not collapse workspace identity.
- Guests and conferences must have no access to 11's private memory tools/data.
- Keep the existing opening and joining behavior. Preserve GitHub and the
  synthetic native test graph for rollback. Do not modify 2.
- Keep native MCP record operations. No extraction-model billing dependency is
  introduced for this baseline preparation.

## Authentication decision — temporary per-call code

The bridge currently sends caller_is_owner for personalization and always
connects the configured agent. This is not owner authentication. Do not attach
real data to that shared static MCP connection and rely on prompt instructions.

M selected code verification until speaker verification has been evaluated.
The code unlocks the baseline private owner session, not only exceptional
sensitive requests. This replaces the proposed manual approval per call.
Local code verification is implemented in `bridge/owner_code.py` and connected
to the bridge behind `OWNER_CODE_MODE=sms`; it is not enabled live yet.

Implementation requirements:

- Use a short-lived, single-use code delivered to the owner's previously
  verified destination. Never accept a replacement destination from tool
  arguments or use incoming caller ID as the destination authority.
- Bind the pending challenge and resulting grant to the exact active private
  call, owner and workspace. A code for one call cannot authorize another.
- Verify through a trusted backend, not an LLM's interpretation of an answer.
- Bound attempts and resend frequency; a resend must not reset failed attempts.
- An expired, rejected, ambiguous or unavailable verification stays locked.
- Do not log codes, return them in tool results, or save them to conversational
  memory. Keypad entry happens in Twilio Gather before any ElevenLabs stream;
  Twilio request/Verify logs remain provider-controlled sensitive records.
- Unlock only the owner's existing authorized scope. The code cannot grant
  another tenant, higher clearance, or conference disclosure rights.
- Expiry, hangup, revocation or joining a conference invalidates the grant.
- Use Twilio Verify for managed SMS issuance/checking. The adapter checks the
  stored verification SID, approved status, fixed destination and service SID.
  No SMS has been sent during local tests.

A caller's asserted identity, known number, conversation text, or voice-match
observation is insufficient by itself. Getting the voiceprint service running
does not automatically replace this gate; its acceptance policy needs testing.

Contextual story challenges are a separately discussed future sensitive-request
step-up. They are not implemented and are not a shortcut around this code gate.

## Implemented POC gate and deployment prerequisites

- Only the registered owner number is eligible for code delivery; Twilio call
  state is independently fetched before issuance and checking. Other numbers
  receive no code and route to the memory-free agent.
- Challenges last 5 minutes, permit 3 checks, and produce an opaque single-use
  stream ticket bound to the exact Call SID. Neither code nor ticket is sent
  into an LLM prompt. Conference sessions cannot consume a private ticket.
- A private session lasts at most 30 minutes after code approval. At expiry,
  both sockets close; do not reuse its private context as a guest session.
- Hangup closes the private context and revokes the ticket. Conference handoff
  creates a fresh memory-free agent session; it never transfers conversation
  history or the owner ticket. Recovery requires a new verification.
- 60-second send cooldown, 3 sends/hour, 5 failed checks/15 minutes per configured
  owner. Repeated webhook delivery does not resend or reset attempts. Uncertain
  outcomes fail closed. Concurrent owner challenges are blocked.
- All gate state is in process memory: one worker and one replica only. Restart
  revokes access and loses local rate-limit history. Configure provider-side
  abuse limits too. Do not scale this implementation before a durable store.
- Abandoned challenges may temporarily block a new owner call. Reused pending
  Verify SIDs are rejected rather than transferring a code to another call.
- Both agent configurations must require authentication. Private-agent direct
  phone routes, public share links, custom prompt/agent overrides and automatic
  transfers must not bypass the bridge. Audit these before enabling live.
- The guest/conference configuration must have no MCP connections, private
  knowledge base, private inline context, or tools/workflows that retrieve or
  transfer into private memory. A different agent ID alone is not sufficient.

The configured private agent pins the owner/workspace; runtime variables are
informational, never permission inputs. For 12 use a separate credential and
scope and an independent gate. This is not a general multi-tenant auth service.

Twilio references: [Verify checks](https://www.twilio.com/docs/verify/api/verification-check)
and [DTMF Gather](https://www.twilio.com/docs/voice/twiml/gather).

The resulting authorization must be bound to the authenticated actor, workspace,
live private session and expiry. End/revocation/join must remove access. Guest
and conference contexts must not inherit the private transcript or credentials.
Per-session enforcement must also cover alternate entry paths such as agent
preview/widget connections, not only the Twilio bridge.

## Baseline preview

Read-only GitHub fetch resolved origin/main to
`5849d29e38af4514d2b3b489076639db82dd594b`.

21 committed Markdown sources: 8 people, 2 animals, 2 projects, 1 event,
2 historical decisions, 6 orientation/reference documents.

Run from repository root:

```sh
PYTHONPATH=services/voice-bridge python3 -m bridge.memory_seed --repo . --ref origin/main
PYTHONPATH=services/voice-bridge python3 -m unittest discover -s services/voice-bridge/tests -p test_memory_seed.py -v
```

This command inventories provenance and review flags; it does not normalize
facts, upload content, or mutate any graph. It excludes instructions, templates,
service code, security policies, hidden files, and uncommitted changes. Output
contains metadata, not memory bodies. Symlink knowledge sources are rejected.

Before importing, resolve overlapping orientation/entity notes and wikilinks;
do not turn authoring examples or placeholders into entities/facts. Preserve
historical decisions as history, not current instructions. Recorded timestamps
are provenance, not evidence that a plan is current. Keep unknown dates unknown.
Give entities stable scope-specific references and preserve source revision/path
and exact assertion meaning. Import retries must not duplicate or overwrite
newer conversational additions.

## Activation gates

1. Implement and test owner-session authorization without changing the opening.
2. Provision distinct scoped native credentials; never reuse an admin credential.
3. Test reads, searches, exact-ID access and writes across both tenant boundaries.
4. Test unknown/guest/conference, expired/revoked grants and alternate entry paths.
5. Review the entity mapping and import privately; verify counts and sample facts.
6. Attach only through the protected session path and test a private owner call.
7. When the user supplies 12's agent, configure empty onboarding and prove its
   retrieval and writes cannot cross into 11's scope (and vice versa).

Graph-scoped credentials protect tenants. They do not implement finer disclosure
levels for multiple people sharing one tenant. That remains separately gated.
