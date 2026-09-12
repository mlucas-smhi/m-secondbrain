from __future__ import annotations

import asyncio
import base64
import hmac
import json
import logging
import os
from collections import deque
from dataclasses import dataclass
from typing import Any
from urllib.parse import urljoin

from aiohttp import ClientSession, WSMsgType, web
from twilio.request_validator import RequestValidator
from twilio.rest import Client as TwilioClient


LOG = logging.getLogger("voice_bridge")
FORK_MODES = {"disabled", "count", "buffer"}
MULAW_BYTES_PER_SECOND = 8_000


class RollingAudioBuffer:
    """Bounded, in-memory buffer for Twilio's 8 kHz mu-law caller audio."""

    def __init__(self, seconds: int) -> None:
        if seconds < 1 or seconds > 60:
            raise ValueError("rolling buffer seconds must be between 1 and 60")
        self.max_bytes = seconds * MULAW_BYTES_PER_SECOND
        self._chunks: deque[bytes] = deque()
        self._size = 0

    def append_base64(self, payload: str) -> None:
        chunk = base64.b64decode(payload, validate=True)
        self._chunks.append(chunk)
        self._size += len(chunk)
        while self._size > self.max_bytes and self._chunks:
            overflow = self._size - self.max_bytes
            first = self._chunks[0]
            if len(first) <= overflow:
                self._chunks.popleft()
                self._size -= len(first)
            else:
                self._chunks[0] = first[overflow:]
                self._size -= overflow

    def recent(self, seconds: int) -> bytes:
        wanted = min(seconds * MULAW_BYTES_PER_SECOND, self._size)
        if not wanted:
            return b""
        return b"".join(self._chunks)[-wanted:]

    @property
    def size(self) -> int:
        return self._size


@dataclass(frozen=True)
class Settings:
    public_base_url: str
    elevenlabs_agent_id: str
    elevenlabs_api_key: str
    twilio_account_sid: str
    twilio_auth_token: str
    twilio_from_number: str
    allowed_to_number: str
    bridge_api_key: str
    elevenlabs_agent_name: str = "11"
    elevenlabs_user_name: str = "Michael"
    elevenlabs_greeting: str = "Hello"
    voice_fork_mode: str = "disabled"
    rolling_buffer_seconds: int = 15
    port: int = 8080

    @classmethod
    def from_env(cls) -> "Settings":
        required = {
            "public_base_url": "PUBLIC_BASE_URL",
            "elevenlabs_agent_id": "ELEVENLABS_AGENT_ID",
            "elevenlabs_api_key": "ELEVENLABS_API_KEY",
            "twilio_account_sid": "TWILIO_ACCOUNT_SID",
            "twilio_auth_token": "TWILIO_AUTH_TOKEN",
            "twilio_from_number": "TWILIO_FROM_NUMBER",
            "allowed_to_number": "POC_ALLOWED_TO_NUMBER",
            "bridge_api_key": "BRIDGE_API_KEY",
        }
        values: dict[str, Any] = {}
        missing: list[str] = []
        for field, env_name in required.items():
            value = os.getenv(env_name, "").strip()
            if not value:
                missing.append(env_name)
            values[field] = value
        if missing:
            raise RuntimeError(f"missing required environment: {', '.join(missing)}")

        mode = os.getenv("VOICE_FORK_MODE", "disabled").strip().lower()
        if mode not in FORK_MODES:
            raise RuntimeError(f"VOICE_FORK_MODE must be one of {sorted(FORK_MODES)}")
        values["voice_fork_mode"] = mode
        values["elevenlabs_agent_name"] = os.getenv("ELEVENLABS_AGENT_NAME", "11").strip()
        values["elevenlabs_user_name"] = os.getenv("ELEVENLABS_USER_NAME", "Michael").strip()
        values["elevenlabs_greeting"] = os.getenv("ELEVENLABS_GREETING", "Hello").strip()
        values["rolling_buffer_seconds"] = int(os.getenv("ROLLING_BUFFER_SECONDS", "15"))
        if not 1 <= values["rolling_buffer_seconds"] <= 60:
            raise RuntimeError("ROLLING_BUFFER_SECONDS must be between 1 and 60")
        values["port"] = int(os.getenv("PORT", "8080"))
        values["public_base_url"] = values["public_base_url"].rstrip("/") + "/"
        return cls(**values)


def outbound_twiml(public_base_url: str) -> str:
    websocket_url = urljoin(public_base_url, "media-stream").replace("https://", "wss://", 1)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        "<Response><Connect>"
        f'<Stream url="{websocket_url}" />'
        "</Connect></Response>"
    )


def conversation_initiation_payload(settings: Settings) -> dict[str, Any]:
    return {
        "type": "conversation_initiation_client_data",
        "dynamic_variables": {
            "agent_name": settings.elevenlabs_agent_name,
            "user_name": settings.elevenlabs_user_name,
            "greeting": settings.elevenlabs_greeting,
        },
    }


def public_request_url(settings: Settings, request: web.Request) -> str:
    return urljoin(settings.public_base_url, request.rel_url.path.lstrip("/"))


def validate_twilio_request(settings: Settings, request: web.Request, form: dict[str, str]) -> bool:
    signature = request.headers.get("X-Twilio-Signature", "")
    return RequestValidator(settings.twilio_auth_token).validate(
        public_request_url(settings, request), form, signature
    )


def validate_twilio_websocket_request(settings: Settings, request: web.Request) -> bool:
    signature = request.headers.get("X-Twilio-Signature", "")
    request_url = public_request_url(settings, request)
    validator = RequestValidator(settings.twilio_auth_token)
    websocket_url = request_url.replace("https://", "wss://", 1)

    # The public proxy presents HTTPS to the app, while Twilio signs the WSS
    # Stream URL. Twilio also documents a trailing-slash signature variant for
    # Media Streams handshakes, so validate all canonical forms and nothing else.
    candidate_urls = {
        request_url.rstrip("/"),
        request_url.rstrip("/") + "/",
        websocket_url.rstrip("/"),
        websocket_url.rstrip("/") + "/",
    }
    return any(validator.validate(url, {}, signature) for url in candidate_urls)


async def get_signed_url(settings: Settings, session: ClientSession) -> str:
    endpoint = "https://api.elevenlabs.io/v1/convai/conversation/get-signed-url"
    async with session.get(
        endpoint,
        params={"agent_id": settings.elevenlabs_agent_id},
        headers={"xi-api-key": settings.elevenlabs_api_key},
    ) as response:
        response.raise_for_status()
        body = await response.json()
        return str(body["signed_url"])


async def health(request: web.Request) -> web.Response:
    settings: Settings = request.app["settings"]
    return web.json_response({"status": "ok", "voice_fork_mode": settings.voice_fork_mode})


async def originate_call(request: web.Request) -> web.Response:
    settings: Settings = request.app["settings"]
    if not hmac.compare_digest(request.headers.get("X-Bridge-Key", ""), settings.bridge_api_key):
        return web.json_response({"error": "unauthorized"}, status=401)

    try:
        body = await request.json()
    except (json.JSONDecodeError, TypeError):
        return web.json_response({"error": "invalid_json"}, status=400)

    destination = str(body.get("to", "")).strip()
    if destination != settings.allowed_to_number:
        return web.json_response({"error": "destination_not_allowed"}, status=403)

    twiml_url = urljoin(settings.public_base_url, "twiml/outbound")
    client = TwilioClient(settings.twilio_account_sid, settings.twilio_auth_token)
    call = await asyncio.to_thread(
        client.calls.create,
        to=destination,
        from_=settings.twilio_from_number,
        url=twiml_url,
        method="POST",
    )
    return web.json_response({"call_sid": call.sid, "status": call.status}, status=202)


async def twiml_outbound(request: web.Request) -> web.Response:
    settings: Settings = request.app["settings"]
    form_data = await request.post()
    form = {key: str(value) for key, value in form_data.items()}
    if not validate_twilio_request(settings, request, form):
        return web.Response(status=403, text="forbidden")
    return web.Response(text=outbound_twiml(settings.public_base_url), content_type="text/xml")


async def verification_snippet(request: web.Request) -> web.Response:
    """Return recent caller audio while a stream is active; never persist it."""
    settings: Settings = request.app["settings"]
    if not hmac.compare_digest(request.headers.get("X-Bridge-Key", ""), settings.bridge_api_key):
        return web.json_response({"error": "unauthorized"}, status=401)
    if settings.voice_fork_mode != "buffer":
        return web.json_response({"error": "audio_buffer_disabled"}, status=409)

    try:
        body = await request.json()
    except (json.JSONDecodeError, TypeError):
        return web.json_response({"error": "invalid_json"}, status=400)
    stream_sid = str(body.get("stream_sid", "")).strip()
    seconds = body.get("seconds", 7)
    if not isinstance(seconds, int) or not 1 <= seconds <= settings.rolling_buffer_seconds:
        return web.json_response({"error": "invalid_seconds"}, status=400)

    buffers: dict[str, RollingAudioBuffer] = request.app["audio_buffers"]
    if not stream_sid:
        if len(buffers) != 1:
            return web.json_response({"error": "stream_sid_required"}, status=400)
        stream_sid = next(iter(buffers))
    audio = buffers.get(stream_sid)
    if audio is None:
        return web.json_response({"error": "active_stream_not_found"}, status=404)
    snippet = audio.recent(seconds)
    response = web.json_response(
        {
            "stream_sid": stream_sid,
            "format": "ulaw_8000",
            "duration_ms": len(snippet) * 1000 // MULAW_BYTES_PER_SECOND,
            "audio_base64": base64.b64encode(snippet).decode("ascii"),
        }
    )
    response.headers["Cache-Control"] = "no-store"
    return response


async def media_stream(request: web.Request) -> web.WebSocketResponse:
    settings: Settings = request.app["settings"]
    if not validate_twilio_websocket_request(settings, request):
        raise web.HTTPForbidden(text="forbidden")
    twilio_ws = web.WebSocketResponse(heartbeat=20)
    await twilio_ws.prepare(request)

    stream_sid: str | None = None
    el_session: ClientSession | None = None
    el_ws: Any = None
    pump_task: asyncio.Task[None] | None = None
    inbound_frames = 0
    inbound_bytes = 0
    audio_buffer: RollingAudioBuffer | None = None

    async def pump_elevenlabs_to_twilio() -> None:
        nonlocal el_ws, stream_sid
        async for message in el_ws:
            if message.type != WSMsgType.TEXT:
                continue
            event = json.loads(message.data)
            event_type = event.get("type")
            if event_type == "audio" and stream_sid:
                await twilio_ws.send_json(
                    {
                        "event": "media",
                        "streamSid": stream_sid,
                        "media": {"payload": event["audio_event"]["audio_base_64"]},
                    }
                )
            elif event_type == "ping":
                await el_ws.send_json(
                    {"type": "pong", "event_id": event["ping_event"]["event_id"]}
                )
            elif event_type == "interruption" and stream_sid:
                await twilio_ws.send_json({"event": "clear", "streamSid": stream_sid})
            elif event_type == "conversation_initiation_metadata":
                metadata = event.get("conversation_initiation_metadata_event", {})
                LOG.info(
                    "conversation_started conversation_id=%s input=%s output=%s",
                    metadata.get("conversation_id"),
                    metadata.get("user_input_audio_format"),
                    metadata.get("agent_output_audio_format"),
                )
            elif event_type == "client_error":
                LOG.error("elevenlabs_client_error event=%s", event)

    try:
        async for message in twilio_ws:
            if message.type != WSMsgType.TEXT:
                continue
            event = json.loads(message.data)
            event_type = event.get("event")

            if event_type == "start":
                stream_sid = event["start"]["streamSid"]
                if settings.voice_fork_mode == "buffer":
                    audio_buffer = RollingAudioBuffer(settings.rolling_buffer_seconds)
                    request.app["audio_buffers"][stream_sid] = audio_buffer
                el_session = ClientSession()
                el_ws = await el_session.ws_connect(await get_signed_url(settings, el_session))
                await el_ws.send_json(conversation_initiation_payload(settings))
                pump_task = asyncio.create_task(pump_elevenlabs_to_twilio())
                LOG.info("stream_started stream_sid=%s", stream_sid)
            elif event_type == "media" and el_ws is not None:
                payload = event["media"]["payload"]
                await el_ws.send_json({"user_audio_chunk": payload})
                if settings.voice_fork_mode in {"count", "buffer"}:
                    inbound_frames += 1
                    inbound_bytes += (len(payload) * 3) // 4
                if audio_buffer is not None:
                    audio_buffer.append_base64(payload)
            elif event_type == "stop":
                break
    except Exception:
        LOG.exception("media_stream_failed stream_sid=%s", stream_sid)
        raise
    finally:
        if pump_task:
            pump_task.cancel()
            await asyncio.gather(pump_task, return_exceptions=True)
        if el_ws is not None and not el_ws.closed:
            await el_ws.close()
        if el_session is not None and not el_session.closed:
            await el_session.close()
        if stream_sid:
            request.app["audio_buffers"].pop(stream_sid, None)
        LOG.info(
            "stream_stopped stream_sid=%s fork_mode=%s inbound_frames=%d inbound_bytes=%d",
            stream_sid,
            settings.voice_fork_mode,
            inbound_frames,
            inbound_bytes,
        )

    return twilio_ws


def create_app(settings: Settings) -> web.Application:
    app = web.Application(client_max_size=64 * 1024)
    app["settings"] = settings
    app["audio_buffers"] = {}
    app.add_routes(
        [
            web.get("/health", health),
            web.post("/calls/poc", originate_call),
            web.post("/twiml/outbound", twiml_outbound),
            web.post("/verification/snippet", verification_snippet),
            web.get("/media-stream", media_stream),
        ]
    )
    return app


def main() -> None:
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    settings = Settings.from_env()
    web.run_app(create_app(settings), host="0.0.0.0", port=settings.port)


if __name__ == "__main__":
    main()
