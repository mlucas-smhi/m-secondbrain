import os
import base64
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from twilio.request_validator import RequestValidator

from bridge.app import (
    Settings,
    RollingAudioBuffer,
    conversation_initiation_payload,
    mulaw_8khz_to_wav_24khz,
    outbound_twiml,
    parse_verifier_result,
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


class TwimlTests(unittest.TestCase):
    def test_twiml_points_to_secure_bridge_websocket(self) -> None:
        result = outbound_twiml("https://bridge.example.com/")
        self.assertIn('url="wss://bridge.example.com/media-stream"', result)
        self.assertIn("<Connect>", result)


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
