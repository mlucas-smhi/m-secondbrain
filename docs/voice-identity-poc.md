# Voice identity POC

## Decision

Do not deploy VibeVoice or treat a voiceprint as authentication yet. First run a
bounded media-bridge POC that proves caller audio can be observed without
affecting 11's conversation quality or availability.

The existing outbound path calls ElevenLabs' native
`/v1/convai/twilio/outbound-call` endpoint. That managed path returns a Twilio
call SID and ElevenLabs conversation ID, but it does not expose a raw live-audio
feed to our services. The post-call webhook is intentionally too late for
in-call identity decisions.

## Proposed POC topology

```text
n8n / Supabase
      |
      | initiate call
      v
Twilio call
      |
      | bidirectional Media Stream (caller track received by bridge)
      v
our media bridge ----------------------> ElevenLabs conversation WebSocket
      |                                      |
      | asynchronous copy                    | 11 audio back to caller
      v                                      v
VibeVoice streaming ASR / speaker evidence  Twilio
      |
      v
Supabase trust-session evidence
```

The bridge owns Twilio's TwiML and relays audio between Twilio and ElevenLabs.
Twilio sends the caller's inbound track to a bidirectional Media Stream. The
bridge copies that track to a bounded VibeVoice queue while immediately
forwarding the original μ-law frames to ElevenLabs. ElevenLabs output goes
straight back to Twilio and is not sent through VibeVoice.

This replaces the native outbound-call initiation only for the POC calls. It
does not replace the ElevenLabs agent, turn engine, trust engine, or post-call
webhook.

## Audio boundary

- Twilio and the ElevenLabs telephony bridge use G.711 μ-law at 8 kHz.
- Preserve those frames unchanged on the conversational path.
- Decode μ-law, convert to mono floating-point PCM, and resample to 24 kHz only
  on the VibeVoice side branch.
- Send only the inbound caller track to VibeVoice. Do not send the mixed call or
  11's synthesized speech.
- Use a bounded, non-blocking queue. If the identity branch is slow or down,
  drop identity frames and continue the call.
- Never route VibeVoice output back into the call audio.

## Security semantics

Voice similarity is evidence, not identity and never authority. The bridge may
append observations to the active Supabase `trust_session`, including:

```json
{
  "evidence_type": "voice_match",
  "claimed_actor_ref": "person:stable-id",
  "model": "vibevoice-asr-streaming-7b",
  "score": 0.0,
  "observed_at": "ISO-8601 timestamp",
  "call_ref": "provider-neutral call reference",
  "quality": {
    "speech_seconds": 0,
    "packet_loss": 0.0,
    "signal_quality": "unknown"
  }
}
```

The trust engine combines this evidence with phone possession, challenge
results, session presence, and policy. A low score, insufficient speech,
multiple speakers, replay suspicion, or unknown listener must produce
`CHALLENGE` or `DEFER`, never an automatic denial based solely on voice.
Privileged disclosure and action remain fail-closed if the required assurance
is not reached.

## Privacy and retention

- Obtain explicit enrollment consent and retain the consent record.
- Use synthetic or explicitly consented voices during the POC.
- Do not store raw call audio by default.
- Store the smallest useful derived evidence with model/version provenance and
  an expiry.
- Keep enrollment material and derived embeddings outside Git.
- Treat embeddings and reference audio as Level 3 biometric data.
- Support revocation, deletion, re-enrollment, and model-version invalidation.

## POC sequence

1. Build a local or isolated bridge with one allow-listed destination number.
2. Validate Twilio webhook signatures and use short-lived ElevenLabs signed
   conversation URLs.
3. Relay a call through ElevenLabs with the VibeVoice branch disabled and prove
   audio is equivalent to the current known-good call.
4. Enable a sink-only audio fork that counts frames but performs no inference.
5. Add μ-law-to-24-kHz conversion and measure queue growth, drops, and CPU.
6. Run VibeVoice streaming transcription/speaker output on synthetic audio.
7. Test an enrolled speaker, an impostor, replayed audio, background speech,
   speakerphone, poor signal, and insufficient-speech cases.
8. Feed evidence into a non-production trust session and verify the expected
   `ALLOW`, `CHALLENGE`, and `DEFER` behavior.

## Kill switches and limits

- One environment switch disables the VibeVoice fork without restarting the
  conversational bridge.
- One environment switch disables the POC call route entirely.
- Hard limits cover call duration, buffered audio, concurrent calls, GPU time,
  and retained evidence.
- Bridge health and ElevenLabs relay errors page independently from identity
  inference errors.
- No scheduled workflow is required for the POC; initiate each call manually.

## Go / no-go gate

Proceed beyond the POC only if all of these are true:

- no audible degradation, disconnects, or material conversational latency;
- the identity branch can fail without interrupting the call;
- end-to-end evidence arrives early enough for the intended in-call decision;
- false-accept and false-reject behavior is acceptable across the test matrix;
- ambiguous and hostile cases reliably fall back to challenge or defer;
- biometric consent, retention, deletion, and audit controls are operable;
- infrastructure cost and operational burden are acceptable.

If any availability or isolation condition fails, stop. Post-call speaker
analysis may still be useful for audit, but it must not be presented as live
authentication.

## Deferred work

LiteGraph installation remains deferred until this voice feasibility gate is
resolved. The provider-neutral memory contract and graph mapping may continue
to evolve in Git without provisioning LiteGraph, credentials, containers, or
MCP access.
