# GPT Live 1 Twilio POC

This service is an isolated voice canary. A dedicated Twilio number sends its
call to OpenAI over SIP. OpenAI sends a signed `live.transport.incoming`
webhook here, and this service accepts the call as a `gpt-live-1` session.

The media path is direct:

```text
caller -> Twilio number -> Twilio SIP -> OpenAI GPT Live 1
                                      -> signed webhook -> this service
                                      -> trusted sideband -> read-only GitHub memory
```

No GPU is required. The service is control-plane only and can run on a small
CPU container. It does not share the production ElevenLabs number or bridge.

## Parallel Realtime + MCP mode

The proven path remains the default (`OPENAI_VOICE_API=live`). A parallel
canary can instead set `OPENAI_VOICE_API=realtime` and connect GPT Realtime
directly to a remote MCP server. For LiteGraph 8.1, use its standard
Streamable HTTP endpoint ending in `/mcp`; `/rpc` is the legacy Voltaic
compatibility endpoint.

Set `MCP_SERVER_URL`, the secret raw access token in `MCP_AUTHORIZATION`, and an
explicit comma-separated `MCP_ALLOWED_TOOLS` list. For onboarding, use only
`memory_search,memory_get,memory_store`. The facade makes `memory_store`
append-only, graph-bound, idempotent, provenance-required, and Level 3 by
default; it does not expose arbitrary node mutation or deletion. The model
never receives unrestricted LiteGraph tools, and the working Live/GitHub
canary remains available for rollback.

The Realtime identity, memory doctrine, trust boundaries, tool etiquette, and
voice direction live in `live_poc/two-realtime-prompt.md`. Keep operational
capabilities conditional on the tools exposed to each session so the prompt can
support read-only deployments now and authorized memory capture later.

## First-run onboarding gate

Set `ONBOARDING_VERIFY_URL`, `ONBOARDING_RESUME_URL`, `ONBOARDING_API_KEY`, and
`ONBOARDING_INVITE_ID` to put the Realtime canary into resumable onboarding
mode. The caller's exact allowlisted E.164 number is supplied by the trusted
bridge; the model supplies only the six-digit code it heard on first enrollment.

Before confirmation, the session receives the onboarding prompt and one local
function: `validate_onboarding_code`. LiteGraph MCP tools are withheld. After
confirmation, the scoped memory facade is attached and trusted session/thread
references are supplied for provenance. The bridge sends the code to the
Supabase verification function, which atomically
returns the permanent actor, workspace, onboarding session, trust session, and
durable thread. After confirmation the bridge removes the validation tool,
marks the runtime context confirmed, and begins topic 1. Internal identifiers
are never spoken.

On later calls, the bridge sends the trusted inbound number and new call ID to
`resolve-onboarding-caller`. A verified active actor receives the existing
workspace, durable thread, onboarding checkpoint, and a fresh trust session.
The invitation code remains single-use. Caller-ID continuity is suitable for
ordinary conversation and onboarding, while sensitive actions may still
require step-up verification.

Set `ONBOARDING_WORKSPACE_ID` to the workspace associated with the intended
enrollment. Resolution is scoped to that workspace because a phone may exist
in multiple workspaces. Missing scope or unavailable lookup withholds tools
and does not fall back to requesting another enrollment code.

The opening disables automatic VAD responses and interruptions in the call
acceptance payload. Its response carries an opening metadata tag; only the
matching SIP `output_audio_buffer.stopped` event restores normal turn handling.
Generation completion alone does not mean the greeting has finished playing.
Empty checkpoints mean the stopping point is unknown; the agent must ask
where to continue rather than claim saved topic progress.

Memory tools remain withheld until trusted verification or returning-caller
resolution succeeds. A scoped facade may then expose `memory_store`; only its
successful result establishes that onboarding details were persisted.

### Entity-graph memory deployment

`MEMORY_SCHEMA_MODE=legacy` preserves the existing atomic-note save contract.
Set `MEMORY_SCHEMA_MODE=entity-memory.v1` only alongside the graph-mode facade
(`GRAPH_MEMORY_ENABLED=true`) and its explicitly provisioned workspace/owner
graph. The voice service loads `two-graph-memory-prompt.md`, supplies trusted
call/thread references, and instructs 2 to save bounded entity/fact bundles,
reuse resolved Entity IDs, and confirm saves from returned receipts.

Graph-mode MCP tools require a recognized context with actor, workspace,
thread, and call references; missing context withholds the catalog. Verification
failures do not fall back to personal memory access. Existing invitation,
returning-caller, greeting, model, and voice behavior is otherwise unchanged.
This prompt does not provide a durable background capture queue or guarantee
that every important statement causes a save. Verify actual records in the
two-call acceptance test before claiming reliable autonomous capture.

## POC stages

1. Prove the dedicated Twilio line reaches GPT Live 1 and supports natural
   interruption.
2. Attach a trusted sideband controller.
3. Expose one read-only GitHub operation for canonical `m-secondbrain` memory.
4. Prove the credential and disallowed repository content never enter the
   spoken session.
5. Add write operations only behind a separate confirmation policy, if ever.

Stages 1 and 2 are implemented here. When `GITHUB_TOKEN` is configured, the
signed incoming-session webhook accepts the call and attaches a trusted Live
sideband controller. A delegated Responses model may call exactly one tool:
`read_memory`. The token remains in the container and never enters the spoken
session.

## Required configuration

Copy `.env.example` and set `OPENAI_API_KEY` and `OPENAI_WEBHOOK_SECRET` as
platform secrets. Do not store either value in Git. `GITHUB_TOKEN` is optional
until the voice-only call succeeds. When enabled, use a fine-grained token
restricted to `mlucas-smhi/m-secondbrain` with **Contents: read-only**.

The adapter only accepts Markdown files below `reference/`, `people/`,
`projects/`, `events/`, or `pets/`. It rejects traversal, `_system/`,
`security/`, non-Markdown files, and responses larger than 32 KB. It exposes
no GitHub write operation. Retrieved text is untrusted context, not executable
instructions.

Start locally:

```bash
python -m venv .venv
.venv/bin/pip install -r requirements.txt
OPENAI_API_KEY=... OPENAI_WEBHOOK_SECRET=... .venv/bin/python -m live_poc.app
```

Build the deployment image from this directory:

```bash
docker build -t gpt-live-poc:local .
```

Health check:

```bash
curl http://127.0.0.1:8090/health
```

Public webhook path:

```text
https://<control-host>/openai/webhook
```

For SIP diagnostics, set the Twilio `<Dial action>` to
`https://<control-host>/twilio/dial-result`. The callback logs only the dial
status and SIP response code; it does not retain caller numbers or audio.

Configure that URL as an OpenAI project webhook for incoming Live transport
events. Route only the dedicated Twilio canary number to the OpenAI SIP URI;
do not repoint the production ElevenLabs number.

## Caller allowlist

Before enabling GitHub memory, route the canary number's incoming-call webhook
to `https://<control-host>/twilio/inbound` with HTTP POST. Configure
`TWILIO_AUTH_TOKEN`, `ALLOWED_CALLER_NUMBER`, `PUBLIC_BASE_URL`, and
`OPENAI_SIP_URI` in the container. The service verifies Twilio's request
signature and returns the OpenAI SIP `<Dial>` only for the exact allowed E.164
number. All other callers receive `<Reject>` and never see the SIP target.

## Tests

```bash
python -m unittest discover -s tests -v
```
# Opening recovery (2026-09-22)

The explicit greeting runs with `turn_detection: null`, then restores normal
VAD after its matching playback-stop/clear event. A failed/cancelled greeting
also releases the guard. An eight-second deadline prevents a missing event
from leaving automatic responses disabled indefinitely. Recovery never sends
another greeting and never unlocks memory or bypasses code validation.

The opening is briefly non-interruptible. Startup input is cleared before
normal listening resumes; a caller speaking over that short introduction may
need to repeat their answer. Boundary/status logs deliberately omit audio,
transcripts, codes, and tool arguments. This recovery addresses a controller
deadlock; it does not prove the cause of an upstream audio cutoff.

Reference: [OpenAI Realtime conversation controls](https://developers.openai.com/api/docs/guides/realtime-conversations).

## Memory-save recovery (2026-09-22)

The graph prompt distinguishes rejected inputs from uncertain backend results,
permits one corrective retry, and forbids invented facts, authorization bypass,
or unconfirmed save claims. Anniversary/trip dates use literal facts rather than
assertion-validity timestamps. Descriptive trips remain separate from bookings.

Unsupported local functions now receive `tool_not_allowed`, not an onboarding
verification failure. They are never dispatched to the database/MCP implicitly
and cannot change authentication. Only `validate_onboarding_code` uses that
verification handler; remote MCP execution remains provider-owned, as described
in [OpenAI Docs: Realtime tools](https://developers.openai.com/api/docs/guides/realtime-mcp).
Rejected local calls log a bounded error code without arguments. Existing MCP
follow-up bounds and opening-recovery behavior are unchanged.

Post-tool responses retain the full active session instructions before adding
their one-response direction. Previously that short direction replaced the
onboarding agenda, voice/personality, trusted context, and memory contract for
the response. This follows the documented
[response.create override semantics](https://developers.openai.com/api/reference/resources/realtime/client-events).
The controller updates its active instruction snapshot after successful code
verification, so first-time and returning calls receive the same protection.
The seven-topic sequence is unchanged; 2 leads it instead of requesting an
agenda after each save. Missing durable checkpoints are not fabricated: the
POC still needs an authorized checkpoint-writing tool for reliable cross-call
topic completion. In-call conversational progress is distinct from that work.
# Staged conversational capture

`MEMORY_SCHEMA_MODE=conversational-capture.v1` selects the natural-language inbox
contract instead of requiring the voice model to build graph payloads. Do not
enable it independently of the matching memory facade/worker. The current live
POC has not been switched. See
[`../litegraph-memory-facade/CONVERSATIONAL_CAPTURE.md`](../litegraph-memory-facade/CONVERSATIONAL_CAPTURE.md)
for the rollout gate and API-billing blocker. Voice/accent settings are unchanged.
