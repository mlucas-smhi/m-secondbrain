# Voice bridge POC

This service places a controlled, transparent relay between Twilio and the
existing ElevenLabs agent. The first live test runs with `VOICE_FORK_MODE` set
to `disabled`; no call audio is retained or sent to speaker verification.

## Endpoints

- `GET /health` reports process health.
- `POST /calls/poc` originates an outbound call to the single allow-listed
  destination. It requires `X-Bridge-Key`.
- `POST /twiml/outbound` validates Twilio's request signature and returns TwiML
  for a bidirectional Media Stream.
- `GET /media-stream` relays Twilio mu-law/8 kHz frames to the ElevenLabs agent
  WebSocket and sends agent audio back to Twilio.

## Safety properties

- Only `POC_ALLOWED_TO_NUMBER` can be called.
- Twilio signatures are mandatory on both the TwiML request and WebSocket
  upgrade.
- The ElevenLabs API key is used server-side only to mint short-lived signed
  conversation URLs.
- The default fork mode is `disabled`.
- The only pre-verification diagnostic mode, `count`, records frame and byte
  counts in logs but stores no audio.
- Unknown fork modes prevent startup.

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
