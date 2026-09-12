from __future__ import annotations

import asyncio
import hmac
import json
import logging
import os
from dataclasses import dataclass
from typing import Any
from urllib.parse import urljoin

from aiohttp import ClientSession, WSMsgType, web
from twilio.request_validator import RequestValidator
from twilio.rest import Client as TwilioClient


LOG = logging.getLogger("voice_bridge")
FORK_MODES = {"disabled", "count"}


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
        values["rolling_buffer_seconds"] = int(os.getenv("ROLLING_BUFFER_SECONDS", "15"))
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
    if validator.validate(request_url, {}, signature):
        return True

    # Twilio documents that Media Streams handshake signatures may use a
    # trailing slash even when the configured WSS URL omits it.
    return validator.validate(request_url.rstrip("/") + "/", {}, signature)


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

    try:
        async for message in twilio_ws:
            if message.type != WSMsgType.TEXT:
                continue
            event = json.loads(message.data)
            event_type = event.get("event")

            if event_type == "start":
                stream_sid = event["start"]["streamSid"]
                el_session = ClientSession()
                el_ws = await el_session.ws_connect(await get_signed_url(settings, el_session))
                await el_ws.send_json({"type": "conversation_initiation_client_data"})
                pump_task = asyncio.create_task(pump_elevenlabs_to_twilio())
                LOG.info("stream_started stream_sid=%s", stream_sid)
            elif event_type == "media" and el_ws is not None:
                payload = event["media"]["payload"]
                await el_ws.send_json({"user_audio_chunk": payload})
                if settings.voice_fork_mode == "count":
                    inbound_frames += 1
                    inbound_bytes += (len(payload) * 3) // 4
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
    app.add_routes(
        [
            web.get("/health", health),
            web.post("/calls/poc", originate_call),
            web.post("/twiml/outbound", twiml_outbound),
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
