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

## Tests

```bash
python -m unittest discover -s tests -v
```
