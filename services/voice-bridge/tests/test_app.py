import os
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from twilio.request_validator import RequestValidator

from bridge.app import Settings, outbound_twiml, validate_twilio_websocket_request


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


class TwimlTests(unittest.TestCase):
    def test_twiml_points_to_secure_bridge_websocket(self) -> None:
        result = outbound_twiml("https://bridge.example.com/")
        self.assertIn('url="wss://bridge.example.com/media-stream"', result)
        self.assertIn("<Connect>", result)


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

    def test_rejects_invalid_signature(self) -> None:
        self.assertFalse(
            validate_twilio_websocket_request(
                self.settings, self.request_with_signature("invalid")
            )
        )


if __name__ == "__main__":
    unittest.main()
