import os
import unittest
from unittest.mock import patch

from bridge.app import Settings, outbound_twiml


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


if __name__ == "__main__":
    unittest.main()
