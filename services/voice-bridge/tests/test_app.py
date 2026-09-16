import os
import base64
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from unittest.mock import MagicMock

from twilio.request_validator import RequestValidator
from aiohttp.test_utils import TestClient, TestServer

from bridge.app import (
    Settings,
    RollingAudioBuffer,
    conversation_initiation_payload,
    conference_participant_twiml,
    create_app,
    live_call_context_update,
    mulaw_8khz_to_wav_24khz,
    newer_live_sessions,
    outbound_twiml,
    perform_conference_merge,
    parse_verifier_result,
    twilio_call_options,
    validate_twilio_websocket_request,
)


VALID_ENV = {
    "PUBLIC_BASE_URL": "https://bridge.example.com",
    "ELEVENLABS_AGENT_ID": "agent_test",
    "ELEVENLABS_API_KEY": "eleven-secret",
    "TWILIO_ACCOUNT_SID": "AC_test",
    "TWILIO_AUTH_TOKEN": "twilio-secret",
    "TWILIO_FROM_NUMBER": "+15550000001",
    "POC_ALLOWED_TO_NUMBER": "+15550000002",
    "BRIDGE_API_KEY": "bridge-secret",
}


class SettingsTests(unittest.TestCase):
    def test_defaults_disable_audio_fork(self) -> None:
        with patch.dict(os.environ, VALID_ENV, clear=True):
            settings = Settings.from_env()
        self.assertEqual(settings.voice_fork_mode, "disabled")
        self.assertEqual(settings.port, 8080)
        self.assertEqual(settings.public_base_url, "https://bridge.example.com/")
        self.assertEqual(settings.elevenlabs_agent_name, "11")
        self.assertEqual(settings.elevenlabs_user_name, "Michael")
        self.assertEqual(settings.elevenlabs_greeting, "Hello")
        self.assertEqual(settings.twilio_status_callback_url, "")

    def test_accepts_live_call_status_callback_url(self) -> None:
        env = VALID_ENV | {
            "TWILIO_STATUS_CALLBACK_URL": "https://example.supabase.co/functions/v1/twilio-call-status"
        }
        with patch.dict(os.environ, env, clear=True):
            settings = Settings.from_env()
        self.assertEqual(
            settings.twilio_status_callback_url,
            "https://example.supabase.co/functions/v1/twilio-call-status",
        )

    def test_derives_live_call_merge_url_from_context_url(self) -> None:
        env = VALID_ENV | {
            "LIVE_CALL_CONTEXT_URL": "https://example.supabase.co/functions/v1/live-call-context",
            "TURN_ENGINE_API_KEY": "turn-secret",
        }
        with patch.dict(os.environ, env, clear=True):
            settings = Settings.from_env()
        self.assertEqual(
            settings.live_call_merge_url,
            "https://example.supabase.co/functions/v1/live-call-merge",
        )

    def test_missing_secret_fails_closed(self) -> None:
        env = VALID_ENV | {"BRIDGE_API_KEY": ""}
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(RuntimeError, "BRIDGE_API_KEY"):
                Settings.from_env()

    def test_unknown_fork_mode_fails_closed(self) -> None:
        env = VALID_ENV | {"VOICE_FORK_MODE": "record"}
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(RuntimeError, "VOICE_FORK_MODE"):
                Settings.from_env()

    def test_invalid_buffer_window_fails_closed(self) -> None:
        env = VALID_ENV | {"ROLLING_BUFFER_SECONDS": "61"}
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(RuntimeError, "ROLLING_BUFFER_SECONDS"):
                Settings.from_env()

    def test_observe_mode_requires_verifier_configuration(self) -> None:
        env = VALID_ENV | {"VERIFIER_MODE": "observe"}
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(RuntimeError, "SPEAKER_VERIFIER_URL"):
                Settings.from_env()

    def test_conference_poc_requires_twiml_app(self) -> None:
        env = VALID_ENV | {"CONFERENCE_MERGE_MODE": "poc"}
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(RuntimeError, "TWILIO_CONFERENCE_APP_SID"):
                Settings.from_env()


class RollingAudioBufferTests(unittest.TestCase):
    def test_keeps_only_configured_window(self) -> None:
        buffer = RollingAudioBuffer(1)
        buffer.append_base64(base64.b64encode(b"a" * 6_000).decode())
        buffer.append_base64(base64.b64encode(b"b" * 4_000).decode())
        self.assertEqual(buffer.size, 8_000)
        self.assertEqual(buffer.recent(1), b"a" * 4_000 + b"b" * 4_000)

    def test_returns_requested_recent_audio(self) -> None:
        buffer = RollingAudioBuffer(3)
        buffer.append_base64(base64.b64encode(b"a" * 8_000).decode())
        buffer.append_base64(base64.b64encode(b"b" * 8_000).decode())
        self.assertEqual(buffer.recent(1), b"b" * 8_000)


class VerifierAdapterTests(unittest.TestCase):
    def test_converts_one_second_mulaw_to_24khz_wav(self) -> None:
        wav = mulaw_8khz_to_wav_24khz(bytes([0xFF]) * 8_000)
        self.assertEqual(wav[:4], b"RIFF")
        self.assertEqual(len(wav), 44 + 24_000 * 2)

    def test_accepts_structured_verdict(self) -> None:
        self.assertEqual(
            parse_verifier_result(
                {"verdict": "MATCH", "score": 0.91, "model": "test", "model_version": "1"}
            )["verdict"],
            "MATCH",
        )

    def test_rejects_invalid_verdict(self) -> None:
        with self.assertRaisesRegex(ValueError, "invalid verdict"):
            parse_verifier_result({"verdict": "ALLOW", "score": 1})


class VerificationEndpointTests(unittest.IsolatedAsyncioTestCase):
    async def test_bodyless_get_ignores_json_entity_headers(self) -> None:
        env = VALID_ENV | {
            "VOICE_FORK_MODE": "buffer",
            "VERIFIER_MODE": "observe",
            "SPEAKER_VERIFIER_URL": "http://127.0.0.1:8090/verify",
            "SPEAKER_VERIFIER_API_KEY": "verifier-secret",
        }
        with patch.dict(os.environ, env, clear=True):
            app = create_app(Settings.from_env())
        async with TestClient(TestServer(app)) as client:
            response = await client.get(
                "/verification/evaluate",
                headers={
                    "X-Bridge-Key": "bridge-secret",
                    "Content-Type": "application/json",
                },
            )
            self.assertEqual(response.status, 409)
            self.assertEqual(await response.json(), {"error": "active_stream_not_unique"})


class TwimlTests(unittest.TestCase):
    def test_twiml_points_to_secure_bridge_websocket(self) -> None:
        result = outbound_twiml("https://bridge.example.com/")
        self.assertIn('url="wss://bridge.example.com/media-stream"', result)
        self.assertIn("<Connect>", result)

    def test_outbound_call_requests_every_progress_event(self) -> None:
        env = VALID_ENV | {
            "TWILIO_STATUS_CALLBACK_URL": "https://example.supabase.co/functions/v1/twilio-call-status"
        }
        with patch.dict(os.environ, env, clear=True):
            options = twilio_call_options(Settings.from_env(), "+15550000002")
        self.assertEqual(
            options["status_callback_event"],
            ["initiated", "ringing", "answered", "completed"],
        )
        self.assertEqual(options["status_callback_method"], "POST")

    def test_conference_twiml_is_non_recording_and_labeled(self) -> None:
        room = "merge-11111111-1111-4111-8111-111111111111"
        result = conference_participant_twiml(room, "owner")
        self.assertIn(f">{room}</Conference>", result)
        self.assertIn('participantLabel="owner"', result)
        self.assertIn('beep="false"', result)
        self.assertNotIn("record=", result)


class ConferenceExecutionTests(unittest.TestCase):
    def test_preflights_creates_agent_then_redirects_human_legs(self) -> None:
        env = VALID_ENV | {
            "CONFERENCE_MERGE_MODE": "poc",
            "TWILIO_CONFERENCE_APP_SID": "AP" + "b" * 32,
        }
        with patch.dict(os.environ, env, clear=True):
            settings = Settings.from_env()
        requesting_sid = "CA" + "1" * 32
        target_sid = "CA" + "2" * 32
        agent_sid = "CA" + "3" * 32
        room = "merge-11111111-1111-4111-8111-111111111111"
        client = MagicMock()
        requesting_call = MagicMock()
        requesting_call.fetch.return_value.status = "in-progress"
        target_call = MagicMock()
        target_call.fetch.return_value.status = "in-progress"
        client.calls.side_effect = lambda sid: {
            requesting_sid: requesting_call,
            target_sid: target_call,
        }[sid]
        participant = MagicMock()
        participant.call_sid = agent_sid
        client.conferences.return_value.participants.create.return_value = participant

        with patch("bridge.app.TwilioClient", return_value=client):
            result = perform_conference_merge(
                settings,
                {
                    "room_ref": room,
                    "requesting_provider_call_ref": requesting_sid,
                    "target_provider_call_ref": target_sid,
                },
            )

        self.assertEqual(result, agent_sid)
        client.conferences.assert_called_once_with(room)
        client.conferences.return_value.participants.create.assert_called_once_with(
            to="app:" + "AP" + "b" * 32,
            from_="+15550000001",
            label="elevenlabs-agent",
            beep=False,
            start_conference_on_enter=True,
            end_conference_on_exit=False,
        )
        target_call.update.assert_called_once()
        requesting_call.update.assert_called_once()


class InboundTwimlTests(unittest.IsolatedAsyncioTestCase):
    async def test_requires_valid_twilio_signature(self) -> None:
        with patch.dict(os.environ, VALID_ENV, clear=True):
            app = create_app(Settings.from_env())
        async with TestClient(TestServer(app)) as client:
            response = await client.post("/twiml/inbound", data={"CallSid": "CA-test"})
            self.assertEqual(response.status, 403)

    async def test_creates_an_isolated_stream(self) -> None:
        env = VALID_ENV | {
            "TWILIO_STATUS_CALLBACK_URL": "https://example.supabase.co/functions/v1/twilio-call-status"
        }
        with patch.dict(os.environ, env, clear=True):
            app = create_app(Settings.from_env())
        form = {"CallSid": "CA-test"}
        signature = RequestValidator("twilio-secret").compute_signature(
            "https://bridge.example.com/twiml/inbound", form
        )
        async with TestClient(TestServer(app)) as client:
            response = await client.post(
                "/twiml/inbound",
                data=form,
                headers={"X-Twilio-Signature": signature},
            )
            self.assertEqual(response.status, 200)
            body = await response.text()
            self.assertIn('url="wss://bridge.example.com/media-stream"', body)
            self.assertIn(
                'statusCallback="https://example.supabase.co/functions/v1/twilio-call-status"',
                body,
            )
            self.assertIn('statusCallbackMethod="POST"', body)

    async def test_conference_agent_is_disabled_by_default(self) -> None:
        with patch.dict(os.environ, VALID_ENV, clear=True):
            app = create_app(Settings.from_env())
        form = {"CallSid": "CA-test"}
        signature = RequestValidator("twilio-secret").compute_signature(
            "https://bridge.example.com/twiml/conference-agent", form
        )
        async with TestClient(TestServer(app)) as client:
            response = await client.post(
                "/twiml/conference-agent",
                data=form,
                headers={"X-Twilio-Signature": signature},
            )
            self.assertEqual(response.status, 409)

    async def test_conference_agent_receives_dedicated_stream_role(self) -> None:
        env = VALID_ENV | {
            "CONFERENCE_MERGE_MODE": "poc",
            "TWILIO_CONFERENCE_APP_SID": "AP" + "a" * 32,
        }
        with patch.dict(os.environ, env, clear=True):
            app = create_app(Settings.from_env())
        form = {"CallSid": "CA-test"}
        signature = RequestValidator("twilio-secret").compute_signature(
            "https://bridge.example.com/twiml/conference-agent", form
        )
        async with TestClient(TestServer(app)) as client:
            response = await client.post(
                "/twiml/conference-agent",
                data=form,
                headers={"X-Twilio-Signature": signature},
            )
            self.assertEqual(response.status, 200)
            body = await response.text()
            self.assertIn('name="session_role" value="conference_agent"', body)


class ElevenLabsInitiationTests(unittest.TestCase):
    def test_supplies_required_first_message_variables(self) -> None:
        with patch.dict(os.environ, VALID_ENV, clear=True):
            settings = Settings.from_env()
        self.assertEqual(
            conversation_initiation_payload(settings),
            {
                "type": "conversation_initiation_client_data",
                "dynamic_variables": {
                    "agent_name": "11",
                    "user_name": "Michael",
                    "greeting": "Hello",
                },
            },
        )

    def test_supplies_provider_call_reference_when_available(self) -> None:
        with patch.dict(os.environ, VALID_ENV, clear=True):
            settings = Settings.from_env()
        payload = conversation_initiation_payload(settings, "CA123")
        self.assertEqual(payload["dynamic_variables"]["provider_call_ref"], "CA123")


class LiveCallContextTests(unittest.TestCase):
    def test_only_returns_sessions_newer_than_current_call(self) -> None:
        context = {
            "session": {"started_at": "2026-09-15T20:00:00+00:00"},
            "other_live_sessions": [
                {"session_id": "older", "started_at": "2026-09-15T19:59:00+00:00"},
                {"session_id": "newer", "started_at": "2026-09-15T20:01:00+00:00"},
            ],
        }
        self.assertEqual(
            [session["session_id"] for session in newer_live_sessions(context)],
            ["newer"],
        )

    def test_unverified_caller_is_not_named(self) -> None:
        text = live_call_context_update(
            {"identity_state": "withheld", "actor_ref": "person:secret"}
        )
        self.assertIn("identity is not verified", text)
        self.assertNotIn("person:secret", text)


class TwilioWebsocketValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        with patch.dict(os.environ, VALID_ENV, clear=True):
            self.settings = Settings.from_env()

    def request_with_signature(self, signature: str) -> SimpleNamespace:
        return SimpleNamespace(
            headers={"X-Twilio-Signature": signature},
            rel_url=SimpleNamespace(path="/media-stream"),
        )

    def test_accepts_signature_without_trailing_slash(self) -> None:
        signature = RequestValidator("twilio-secret").compute_signature(
            "https://bridge.example.com/media-stream", {}
        )
        self.assertTrue(
            validate_twilio_websocket_request(
                self.settings, self.request_with_signature(signature)
            )
        )

    def test_accepts_documented_trailing_slash_signature(self) -> None:
        signature = RequestValidator("twilio-secret").compute_signature(
            "https://bridge.example.com/media-stream/", {}
        )
        self.assertTrue(
            validate_twilio_websocket_request(
                self.settings, self.request_with_signature(signature)
            )
        )

    def test_accepts_wss_signature(self) -> None:
        signature = RequestValidator("twilio-secret").compute_signature(
            "wss://bridge.example.com/media-stream", {}
        )
        self.assertTrue(
            validate_twilio_websocket_request(
                self.settings, self.request_with_signature(signature)
            )
        )

    def test_accepts_wss_trailing_slash_signature(self) -> None:
        signature = RequestValidator("twilio-secret").compute_signature(
            "wss://bridge.example.com/media-stream/", {}
        )
        self.assertTrue(
            validate_twilio_websocket_request(
                self.settings, self.request_with_signature(signature)
            )
        )

    def test_rejects_invalid_signature(self) -> None:
        self.assertFalse(
            validate_twilio_websocket_request(
                self.settings, self.request_with_signature("invalid")
            )
        )


if __name__ == "__main__":
    unittest.main()
