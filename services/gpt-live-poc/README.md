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

Set `ONBOARDING_VERIFY_URL`, `ONBOARDING_API_KEY`, and `ONBOARDING_INVITE_ID`
to put the Realtime canary into first-run onboarding mode. The caller's exact
allowlisted E.164 number is supplied by the trusted bridge; the model supplies
only the six-digit code it heard.

Before confirmation, the session receives the onboarding prompt and one local
function: `validate_onboarding_code`. LiteGraph MCP tools are withheld. After
confirmation, the scoped memory facade is attached and trusted session/thread
references are supplied for provenance. The bridge sends the code to the
Supabase verification function, which atomically
returns the permanent actor, workspace, onboarding session, trust session, and
durable thread. After confirmation the bridge removes the validation tool,
marks the runtime context confirmed, and begins topic 1. Internal identifiers
are never spoken.

The current POC intentionally exposes no memory-write tool after confirmation.
Do not claim onboarding answers were persisted until the workspace's LiteGraph
namespace is active and an authorized write facade has been added.

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
