# Fresh onboarding POC — 2026-09-22 (America/Chicago)

After the clean-memory cutover, M explicitly requested the full first-time
experience: fresh memory, new code, and no resumed onboarding. This supersedes
the earlier decision to preserve the active onboarding state.

## Scope and preservation

The old POC actor was revoked, its phone identifier revoked/closed, its trust
sessions expired, its onboarding session marked `abandoned`, and its onboarding
thread marked `cancelled`. All these historical rows and their interactions
remain in the database. Old consumed invites were not reopened. The legacy
SQLite archive and previous PostgreSQL graphs were retained. No other users'
records were reset, and no historical rows were deleted.

The new invite is single-use, phone-bound, expires two hours after issuance,
and locks after five failures. The code is deliberately absent from this file.

## Identity reservation

`20260923030000_reserve_onboarding_identity.sql` adds optional paired
`provision_user_id` / `provision_workspace_id` reservations to trusted invites.
This lets the POC's fixed-scope facade point to the eventual user's empty graph
before the first call. Reservations are IDs, not provisioned identities or
authentication: code validation still performs all checks before creating the
user, workspace, actor, verified phone, onboarding thread, and trust session.
Existing unreserved invites keep their random-ID provisioning behavior.

The reservation fields remain behind the existing RLS/service authorization.
They are not accepted from the model or added to the public verification tool.
The migration changes only the two ID-allocation statements after successful
validation, with an exact-source guard. Other verification logic is preserved.
This is explicit POC provisioning, not automatic multi-tenant memory routing.

## New scope

- Invite: `7cc008ce-7db4-42b2-b520-a233bc709bc5`
- Reserved user: `294e60a6-c254-47f1-abdc-c316c75a04b8`
- Reserved workspace: `0457f7ed-8edf-49a2-a531-792b80e84721`
- LiteGraph tenant: `32522054-87a0-4a02-91c1-720d5d58e51c`
- LiteGraph graph: `258f114b-ea3e-4848-814d-dec8539c4451`

Both apps use revision suffix `fresh-onboarding-20260922`, with the same tested
image digests as the entity-memory cutover. Only invite/workspace and facade
scope pointers changed. Model, Sage voice, caller allowlist, prompt content,
and secret values were not changed by this reset.

The graph was provisioned with zero nodes and zero edges. The first call must
ask for a validation code. It must not greet the caller as a returning user or
have memory tools before verification. After successful verification, topic one
starts with an empty checkpoint and completed-topics list. Subsequent calls
should resolve the new verified identity and resume the new onboarding thread.

## Verification

### Subsequent opening recovery

The first calls reported a cut-off introduction followed by silence. Logs
showed one opening request per call, not duplicate dispatch, and no matching
playback-finished log. The controller could leave automatic responses disabled
forever after cleared/failed playback or a missing completion event.

Voice revision `eleven-gptlive-poc--opening-recovery-20260922` uses image
`ca773a2b28d9acr.azurecr.io/eleven-gptlive-poc@sha256:ee1d1fbd5e2914e0f8ce82a30359e5b12a8c7fb308e485347f2a9deb7e7f13b9`.
It disables VAD during the bounded opening, restores listening on matching
stop/clear/failure, and adds an eight-second recovery deadline that does not
repeat the greeting. Forty-six tests passed, including missing completion,
cleared/cancelled output, late initial acknowledgement, and busy-event deadline
coverage. Identity, invite, voice, and memory configuration remain unchanged.
This does not establish the upstream cause of the audio cutoff or replace a
real-call acceptance test.

`supabase/tests/onboarding_reserved_identity.sql` verifies rejection without
identity creation, reserved-ID alignment, fresh topic/checkpoint/thread state,
single use, returning-caller recognition, and client privilege restrictions.
It runs in a rollback-only transaction; no synthetic identities persist.

The actual new invite's provisioning was also tested in a rolled-back database
transaction. That did not consume its code or leave an identity/session behind.
The actual call, natural memory capture, and next-call recall still require M's
acceptance test. Do not use a successful dry run as evidence of a successful call.

Do not roll back merely by selecting the previous voice revision: it points to
the now-retired identity and older invite. A restore requires explicit coordinated
identity/configuration changes. Preserve newly captured memories before any reset.
