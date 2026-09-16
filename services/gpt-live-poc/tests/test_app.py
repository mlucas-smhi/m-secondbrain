import json
import os
import sys
import unittest
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from live_poc.app import (
    Settings,
    execute_memory_call,
    event_type,
    function_call_from_event,
    incoming_session_id,
    live_session_payload,
    validate_memory_path,
    twilio_dial_result,
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

    def test_adds_only_read_memory_when_github_is_enabled(self) -> None:
        payload = live_session_payload(Settings("key", "secret", github_token="token"))
        responses = payload["session"]["delegation"]["responses"]
        self.assertEqual(responses["tools"][0]["name"], "read_memory")
        self.assertFalse(responses["parallel_tool_calls"])


class SidebandToolTests(unittest.IsolatedAsyncioTestCase):
    def test_extracts_completed_function_call(self) -> None:
        event = {
            "type": "response.event",
            "event": {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "name": "read_memory",
                    "call_id": "call_123",
                    "arguments": '{"path":"people/michael.md"}',
                },
            },
        }
        self.assertEqual(function_call_from_event(event)["call_id"], "call_123")

    async def test_rejects_unknown_tool_without_calling_github(self) -> None:
        output = await execute_memory_call(
            Settings("key", "secret", github_token="token"),
            {"name": "write_memory", "call_id": "call_123", "arguments": "{}"},
        )
        self.assertEqual(json.loads(output), {"ok": False, "error": "tool_not_allowed"})


class TwilioCallbackTests(unittest.IsolatedAsyncioTestCase):
    async def test_returns_terminal_twiml_without_echoing_callback_data(self) -> None:
        async def post() -> dict[str, str]:
            return {"DialCallStatus": "failed", "DialSipResponseCode": "503"}

        response = await twilio_dial_result(SimpleNamespace(post=post))
        self.assertEqual(response.status, 200)
        self.assertIn("<Hangup/>", response.text)
        self.assertNotIn("503", response.text)


if __name__ == "__main__":
    unittest.main()
