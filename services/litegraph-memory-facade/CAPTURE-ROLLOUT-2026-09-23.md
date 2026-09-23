# Conversational capture rollout — 2026-09-23

Source commit: `ab3f584` (`Harden conversational memory capture and pending recall`).
Resource group: `rg-eleven-gptlive-poc`. No memory reset or new invite/code.

## Images and revisions

- Memory revision: `litegraph-memory-poc--capture-ab3f584`
- Memory facade image: `ca773a2b28d9acr.azurecr.io/litegraph-memory-facade@sha256:31225db312cd4e21d3aad24d249d771a2c8b7c5123dcd0f4fa88b4b1ea2fb188`
- Voice revision: `eleven-gptlive-poc--capture-ab3f584-scope`
- Voice image: `ca773a2b28d9acr.azurecr.io/eleven-gptlive-poc@sha256:59a824ab8980c25a25ba9371e9db1cc19222041db4e240ad934e480e6c550537`
- ACR builds: `cd14` and `cd15`, Linux AMD64.

## Changes

- Added only `litegraph_two_poc.memory_captures` and its indexes under the existing
  restricted PostgreSQL role. No PUBLIC grants. Verified TLS uses the supplied CA.
- Bound new private `memory-capture-dsn` and `memory-writer-api-key` secrets;
  original secrets were preserved and compared privately.
- Enabled `MEMORY_CAPTURE_ENABLED=true`, with the separately qualified background
  writer `gpt-4.1-2025-04-14`. This does not change the realtime voice model.
- Voice mode: `MEMORY_SCHEMA_MODE=conversational-capture.v1`.
- Allowed tools: `memory_search`, `memory_get`, `memory_capture`,
  `memory_capture_status`, `memory_orientation`.
- Aligned stale voice-side `MCP_TENANT_GUID`/`MCP_GRAPH_GUID` with the already
  enforced facade scope. Workspace and owner are unchanged. The old IDs were not
  the facade's effective scope; no graph was moved or merged.
- Preserved Sage, `gpt-realtime`, caller verification, onboarding configuration,
  all other containers, volumes, replica limits and resource settings.

## Verification

Both final revisions are ready and serving 100% of their app traffic. Deployed
image, environment, resource, volume and scale settings matched the rollout plan.

The previous evaluation record contains 91 facade tests and 52 voice tests, plus
actual-model synthetic extraction/write/recall tests. All 52 voice tests were
rerun successfully during this rollout.

Hosted checks cover authenticated tool discovery, unauthenticated 401 rejection,
explicit external `memory_store` rejection, durable queue access and existing
memory orientation. Orientation returned 12 existing entities in approximately
one second; the voice credential also passed its bounded three-second orientation
path. Unverified and unavailable identity contexts expose no memory tools.

Graph-content fingerprints were compared against the pre-deployment snapshot.
Startup refreshes built-in authorization-role timestamps and request/audit logs;
those metadata tables are excluded from graph-content equality checks. No
synthetic memories or captures were inserted into the live owner scope.

## Remaining acceptance test

1. Call from the established number. Verify one introduction and appropriate
   returning-caller context, without demanding a fresh enrollment code.
2. Talk naturally about several genuine particulars, including a relationship,
   preference, qualifier and correction. Do not split speech into tool-sized facts.
3. Confirm conversation can continue while graph work runs. An inbox capture is
   not yet a completed graph save; 2 must not claim otherwise.
4. Hang up and call again. Ask about the particulars, then correct/add one detail.
5. Inspect the scoped capture status and graph facts for omissions, mistaken
   identities, reversed relationships, duplicate entities and preserved qualifiers.

Background model work still took 23–41 seconds in the richer pre-deployment tests.
Pending source recall should be available before graph processing completes.
Capture remains conversation-model initiated, not an exhaustive call transcript.
Durable onboarding-topic checkpoint writes remain unfinished.

## Rollback

Private pre-deployment app/secret snapshots and graph hashes were retained in a
mode-0700 local temporary directory (`two-capture-rollback-*`); do not commit them.
Restore the prior app templates from that snapshot if needed:

- Prior revisions: both apps `--endpoint-repair-20260922`.
- Prior facade digest: `sha256:c24a0d79ca3f03c1db0475ac2599c66f1c92a7440843860d470813611c3a32d7`.
- Prior voice digest: `sha256:c0c18c0cace9d672568f45f55ddfc5a4f6f247ba937b23b7d180107522cb23ea`.

Use the exact recorded template/image from the private snapshot as the authority.
Restore prior mode/tool configuration and disable capture. Preserve the new queue,
pending jobs and any graph facts produced by real calls; rollback is not a reset.
