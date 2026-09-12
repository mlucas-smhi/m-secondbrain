# Speaker verifier POC

Private, observation-only speaker-similarity service for the voice bridge. It
uses SpeechBrain's ECAPA-TDNN VoxCeleb model to compare a transient candidate
window with an explicitly consented enrollment recording.

The service returns `MATCH`, `NO_MATCH`, or `INCONCLUSIVE`. These are evidence,
not authentication or authority decisions. Thresholds are POC defaults and
must be calibrated against the project test matrix before any production use.

## Privacy boundary

- Bind only to `127.0.0.1`; Cloudflare must not expose port 8090.
- Keep enrollment WAV files under `SPEAKER_ENROLLMENT_DIR`, outside Git.
- Name enrollment files as `sha256(actor_ref).wav`.
- Never write candidate snippets to disk.
- Use only synthetic or explicitly consented enrollment audio.

## API

`POST /verify` requires `Authorization: Bearer SPEAKER_VERIFIER_API_KEY`:

```json
{
  "claimed_actor_ref": "test:synthetic-speaker",
  "audio_format": "wav_pcm_s16le_24000_mono",
  "audio_base64": "..."
}
```

## Run

```bash
python -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m unittest discover -s tests
.venv/bin/python -m verifier.app
```

Model weights and biometric artifacts are runtime data and do not belong in
the repository or container image.
