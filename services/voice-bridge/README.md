# Voice bridge POC

This service places a controlled, transparent relay between Twilio and the
existing ElevenLabs agent. The first live test runs with `VOICE_FORK_MODE` set
to `disabled`; no call audio is retained or sent to speaker verification.

## Endpoints

- `GET /health` reports process health.
- `POST /calls/poc` originates an outbound call to the single allow-listed
  destination. It requires `X-Bridge-Key`.
- `POST /twiml/inbound` accepts a Twilio-signed inbound voice webhook and gives
  that caller a separate media stream and ElevenLabs conversation. Pointing a
  production number at this route is a separate activation step.
- `POST /twiml/outbound` validates Twilio's request signature and returns TwiML
  for a bidirectional Media Stream.
- `GET /media-stream` relays Twilio mu-law/8 kHz frames to the ElevenLabs agent
  WebSocket and sends agent audio back to Twilio.
- When `TWILIO_STATUS_CALLBACK_URL` is configured, outbound calls request all
  four Twilio progress callbacks so the durable live-call registry can track
  ringing, active, and terminal state without polling.
- `POST /verification/snippet` returns a recent caller-audio window only while
  a call is active. It requires `X-Bridge-Key` and `VOICE_FORK_MODE=buffer`.
- `GET` or `POST /verification/evaluate` converts a transient caller window to mono
  24-kHz PCM WAV and asks the configured speaker-verification service for
  `MATCH`, `NO_MATCH`, or `INCONCLUSIVE` evidence. It is observation-only. A
  caller may omit `stream_sid` only when exactly one call stream is active;
  zero or multiple active streams fail closed. An authenticated empty-body
  request uses the POC owner's fixed `person:m` enrollment and a seven-second
  window, keeping agent-controlled identity claims out of the voice tool.

## Safety properties

- Only `POC_ALLOWED_TO_NUMBER` can be called.
- Twilio signatures are mandatory on both the TwiML request and WebSocket
  upgrade.
- The ElevenLabs API key is used server-side only to mint short-lived signed
  conversation URLs.
- The default fork mode is `disabled`.
- The only pre-verification diagnostic mode, `count`, records frame and byte
  counts in logs but stores no audio.
- `buffer` retains at most `ROLLING_BUFFER_SECONDS` of caller audio in RAM. The
  buffer is deleted when the stream ends; it is never written to disk.
- Unknown fork modes prevent startup.
- Verifier failures resolve to `INCONCLUSIVE` and never interrupt the call.
- The bridge does not translate a voice verdict into identity or authority.

## Local test

```bash
python -m unittest discover -s tests
```

## Container

```bash
docker build -t eleven-voice-bridge .
docker run --rm --env-file .env -p 8080:8080 eleven-voice-bridge
```

Do not place real secrets, enrollment audio, voiceprints, or call recordings in
this repository or image.

## First live test

1. Configure RunPod to expose container port `8080` as HTTP.
2. Set `PUBLIC_BASE_URL` to the resulting HTTPS proxy origin.
3. Supply secrets only through runtime environment variables.
4. Keep `VOICE_FORK_MODE=disabled`.
5. Start the service and verify `/health`.
6. Call `POST /calls/poc` manually with the bridge key and allow-listed number.

For durable live-call state, set `TWILIO_STATUS_CALLBACK_URL` to the deployed
`twilio-call-status` Edge Function. That function validates Twilio's signature;
the bridge never sends database credentials to Twilio.
7. Confirm normal conversation, barge-in, audio quality, and disconnect behavior.
8. Stop on any regression. Enable `count` only after the relay-only test passes.

## RunPod startup

`runpod-start.sh` starts the bridge from the persistent `/workspace` volume and
then executes the RunPod image's original `/start.sh`, preserving SSH, Jupyter,
and the rest of the base-image startup behavior. Configure the Pod's container
start command as:

```text
bash -lc /workspace/eleven-voice-poc/bridge-service/runpod-start.sh
```
