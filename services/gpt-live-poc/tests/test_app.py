import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from live_poc.app import (
    Settings,
    event_type,
    incoming_session_id,
    live_session_payload,
    validate_memory_path,
)


class SettingsTests(unittest.TestCase):
    def test_requires_openai_secrets(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "OPENAI_API_KEY"):
                Settings.from_env()

    def test_github_memory_requires_token(self) -> None:
        self.assertFalse(Settings("key", "secret").github_memory_enabled)
        self.assertTrue(Settings("key", "secret", github_token="token").github_memory_enabled)


class MemoryBoundaryTests(unittest.TestCase):
    def test_allows_canonical_markdown_paths(self) -> None:
        self.assertEqual(validate_memory_path("people/michael.md"), "people/michael.md")
        self.assertEqual(validate_memory_path("/reference/travel.md"), "reference/travel.md")

    def test_rejects_sensitive_or_unsafe_paths(self) -> None:
        for path in (
            "_system/policy.md",
            "security/credentials.md",
            "people/../../.env",
            "people/michael.txt",
        ):
            with self.subTest(path=path):
                with self.assertRaisesRegex(ValueError, "memory_path_not_allowed"):
                    validate_memory_path(path)


class IncomingEventTests(unittest.TestCase):
    def test_reads_live_transport_event(self) -> None:
        event = {"type": "live.transport.incoming", "data": {"session_id": "live_123"}}
        self.assertEqual(event_type(event), "live.transport.incoming")
        self.assertEqual(incoming_session_id(event), "live_123")

    def test_tolerates_legacy_call_id(self) -> None:
        event = {"type": "live.call.incoming", "data": {"call_id": "call_123"}}
        self.assertEqual(incoming_session_id(event), "call_123")


class SessionPayloadTests(unittest.TestCase):
    def test_pins_requested_live_model_and_voice(self) -> None:
        payload = live_session_payload(Settings("key", "secret"))
        session = payload["session"]
        self.assertEqual(session["type"], "live")
        self.assertEqual(session["model"], "gpt-live-1")
        self.assertEqual(session["audio"]["output"]["voice"], "marin")
        self.assertIn("read-only", session["instructions"])


if __name__ == "__main__":
    unittest.main()
