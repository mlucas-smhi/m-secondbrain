from __future__ import annotations

import base64
import hashlib
import hmac
import io
import json
import logging
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from aiohttp import web


LOG = logging.getLogger("speaker_verifier")


@dataclass(frozen=True)
class Settings:
    api_key: str
    enrollment_dir: Path
    model_source: str = "speechbrain/spkrec-ecapa-voxceleb"
    model_cache_dir: Path = Path("/workspace/models/spkrec-ecapa-voxceleb")
    device: str = "cuda"
    match_threshold: float = 0.35
    no_match_threshold: float = 0.20
    port: int = 8090

    @classmethod
    def from_env(cls) -> "Settings":
        api_key = os.getenv("SPEAKER_VERIFIER_API_KEY", "").strip()
        enrollment_dir = os.getenv("SPEAKER_ENROLLMENT_DIR", "").strip()
        if not api_key or not enrollment_dir:
            raise RuntimeError(
                "SPEAKER_VERIFIER_API_KEY and SPEAKER_ENROLLMENT_DIR are required"
            )
        settings = cls(
            api_key=api_key,
            enrollment_dir=Path(enrollment_dir),
            model_source=os.getenv(
                "SPEAKER_MODEL_SOURCE", "speechbrain/spkrec-ecapa-voxceleb"
            ).strip(),
            model_cache_dir=Path(
                os.getenv(
                    "SPEAKER_MODEL_CACHE_DIR",
                    "/workspace/models/spkrec-ecapa-voxceleb",
                )
            ),
            device=os.getenv("SPEAKER_DEVICE", "cuda").strip(),
            match_threshold=float(os.getenv("SPEAKER_MATCH_THRESHOLD", "0.35")),
            no_match_threshold=float(os.getenv("SPEAKER_NO_MATCH_THRESHOLD", "0.20")),
            port=int(os.getenv("SPEAKER_VERIFIER_PORT", "8090")),
        )
        if not 0 <= settings.no_match_threshold < settings.match_threshold <= 1:
            raise RuntimeError("speaker thresholds must satisfy 0 <= no-match < match <= 1")
        return settings


class SpeakerModel(Protocol):
    def similarity(self, enrollment_wav: Path, candidate_wav: bytes) -> float: ...


class SpeechBrainEcapaModel:
    def __init__(self, settings: Settings) -> None:
        import torch
        import torchaudio
        from speechbrain.inference.speaker import SpeakerRecognition

        self.torch = torch
        self.torchaudio = torchaudio
        self.device = settings.device
        self.model = SpeakerRecognition.from_hparams(
            source=settings.model_source,
            savedir=str(settings.model_cache_dir),
            run_opts={"device": settings.device},
        )

    def _load(self, source: Any) -> Any:
        waveform, sample_rate = self.torchaudio.load(source)
        waveform = waveform.mean(dim=0, keepdim=True)
        if sample_rate != 16_000:
            waveform = self.torchaudio.functional.resample(waveform, sample_rate, 16_000)
        return waveform.to(self.device)

    def similarity(self, enrollment_wav: Path, candidate_wav: bytes) -> float:
        enrolled = self._load(str(enrollment_wav))
        candidate = self._load(io.BytesIO(candidate_wav))
        with self.torch.inference_mode():
            enrolled_embedding = self.model.encode_batch(enrolled).squeeze()
            candidate_embedding = self.model.encode_batch(candidate).squeeze()
            score = self.torch.nn.functional.cosine_similarity(
                enrolled_embedding.flatten(), candidate_embedding.flatten(), dim=0
            )
        return float(score.detach().cpu().item())


def enrollment_filename(actor_ref: str) -> str:
    return hashlib.sha256(actor_ref.encode("utf-8")).hexdigest() + ".wav"


def classify(score: float, settings: Settings) -> tuple[str, list[str]]:
    if score >= settings.match_threshold:
        return "MATCH", ["similarity_above_match_threshold"]
    if score < settings.no_match_threshold:
        return "NO_MATCH", ["similarity_below_no_match_threshold"]
    return "INCONCLUSIVE", ["similarity_in_gray_zone"]


async def health(request: web.Request) -> web.Response:
    return web.json_response({"status": "ok", "model_loaded": "model" in request.app})


async def verify(request: web.Request) -> web.Response:
    settings: Settings = request.app["settings"]
    authorization = request.headers.get("Authorization", "")
    if not hmac.compare_digest(authorization, f"Bearer {settings.api_key}"):
        return web.json_response({"error": "unauthorized"}, status=401)
    try:
        body = await request.json()
    except (json.JSONDecodeError, TypeError):
        return web.json_response({"error": "invalid_json"}, status=400)

    actor_ref = str(body.get("claimed_actor_ref", "")).strip()
    if not actor_ref or body.get("audio_format") != "wav_pcm_s16le_24000_mono":
        return web.json_response({"error": "invalid_request"}, status=400)
    try:
        candidate = base64.b64decode(body.get("audio_base64", ""), validate=True)
    except (ValueError, TypeError):
        return web.json_response({"error": "invalid_audio"}, status=400)
    if len(candidate) < 44 + 24_000 * 2:
        return web.json_response(
            {
                "verdict": "INCONCLUSIVE",
                "score": None,
                "model": "speechbrain-ecapa-voxceleb",
                "model_version": "poc-v1",
                "reason_codes": ["insufficient_audio"],
            }
        )

    enrollment = settings.enrollment_dir / enrollment_filename(actor_ref)
    if not enrollment.is_file():
        return web.json_response(
            {
                "verdict": "INCONCLUSIVE",
                "score": None,
                "model": "speechbrain-ecapa-voxceleb",
                "model_version": "poc-v1",
                "reason_codes": ["enrollment_not_found"],
            }
        )
    try:
        model: SpeakerModel = request.app["model"]
        score = await request.app["run_inference"](
            model.similarity, enrollment, candidate
        )
        verdict, reasons = classify(score, settings)
    except Exception as error:
        LOG.exception("speaker_inference_failed error_type=%s", type(error).__name__)
        return web.json_response(
            {
                "verdict": "INCONCLUSIVE",
                "score": None,
                "model": "speechbrain-ecapa-voxceleb",
                "model_version": "poc-v1",
                "reason_codes": ["inference_failed"],
            }
        )
    response = web.json_response(
        {
            "verdict": verdict,
            "score": score,
            "model": "speechbrain-ecapa-voxceleb",
            "model_version": "poc-v1",
            "reason_codes": reasons,
        }
    )
    response.headers["Cache-Control"] = "no-store"
    return response


async def run_inference(function: Any, *args: Any) -> Any:
    import asyncio

    return await asyncio.to_thread(function, *args)


def create_app(settings: Settings, model: SpeakerModel | None = None) -> web.Application:
    app = web.Application(client_max_size=2 * 1024 * 1024)
    app["settings"] = settings
    app["model"] = model or SpeechBrainEcapaModel(settings)
    app["run_inference"] = run_inference
    app.add_routes([web.get("/health", health), web.post("/verify", verify)])
    return app


def main() -> None:
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    settings = Settings.from_env()
    web.run_app(create_app(settings), host="127.0.0.1", port=settings.port)


if __name__ == "__main__":
    main()
