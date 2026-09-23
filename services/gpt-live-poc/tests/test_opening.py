import asyncio
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from live_poc.app import Settings, run_realtime_sideband, realtime_call_payload
from live_poc.opening import OpeningDeadline


class Connection:
    def __init__(self, events):
        self.events = events
        self.sent = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        pass

    async def send(self, message):
        self.sent.append(json.loads(message))

    async def __aiter__(self):
        for event in self.events:
            yield json.dumps(event)


class OpeningTests(unittest.IsolatedAsyncioTestCase):
    async def test_busy_event_stream_cannot_starve_deadline(self):
        class Busy:
            async def __aiter__(self):
                for _ in range(10):
                    await asyncio.sleep(0.001)
                    yield '{}'
        gate = OpeningDeadline(0.002)
        events = [json.loads(e) async for e in gate.messages(Busy())]
        self.assertEqual(sum(e.get('type') == 'local.opening_timeout' for e in events), 1)
        self.assertEqual(sum(e == {} for e in events), 10)

    def settings(self):
        return Settings("key", "secret", voice_api="realtime",
                        allowed_caller_number="+15550000001",
                        onboarding_verify_url="https://example/verify",
                        onboarding_api_key="key", onboarding_invite_id="invite")

    def test_unavailable_does_not_expose_validation_or_memory(self):
        payload = realtime_call_payload(self.settings(), {"status": "unavailable"})
        self.assertEqual(payload["tools"], [])
        self.assertEqual(payload["tool_choice"], "none")
        self.assertIn("Do not ask", payload["instructions"])
        self.assertNotIn("authentication_status: unverified", payload["instructions"])

    async def test_only_matching_playback_end_unlocks_greeting_once(self):
        events = [
            {"type": "session.updated"},
            {"type": "session.updated"},
            {"type": "response.created", "response": {
                "id": "greeting", "metadata": {"purpose": "opening_greeting"}}},
            {"type": "response.done", "response": {"id": "other"}},
            {"type": "response.done", "response": {"id": "greeting"}},
            {"type": "output_audio_buffer.stopped", "response_id": "other"},
        ]
        connection = Connection(events)
        with patch("live_poc.app.connect", return_value=connection):
            await run_realtime_sideband(self.settings(), "call", [], "none")
        self.assertEqual(len(connection.sent), 2)
        self.assertIsNone(connection.sent[0]["session"]["audio"]["input"]["turn_detection"])
        events.extend([
            {"type": "output_audio_buffer.stopped", "response_id": "greeting"},
            {"type": "output_audio_buffer.stopped", "response_id": "greeting"},
            {"type": "session.updated"},
        ])
        connection = Connection(events)
        with patch("live_poc.app.connect", return_value=connection):
            await run_realtime_sideband(self.settings(), "call", [], "none")
        self.assertEqual(len(connection.sent), 4)
        self.assertTrue(connection.sent[-1]["session"]["audio"]["input"]["turn_detection"]["create_response"])

    async def test_cleared_opening_restores_listening_without_repeating(self):
        connection = Connection([
            {"type": "session.updated"},
            {"type": "response.created", "response": {"id": "greeting", "metadata": {"purpose": "opening_greeting"}}},
            {"type": "output_audio_buffer.cleared", "response_id": "other"},
            {"type": "output_audio_buffer.cleared", "response_id": "greeting"},
            {"type": "output_audio_buffer.stopped", "response_id": "greeting"},
            {"type": "session.updated"},
        ])
        with patch("live_poc.app.connect", return_value=connection):
            await run_realtime_sideband(self.settings(), "call", [], "none")
        self.assertEqual(sum(e["type"] == "response.create" for e in connection.sent), 1)
        self.assertEqual(sum(e["type"] == "input_audio_buffer.clear" for e in connection.sent), 1)
        self.assertTrue(connection.sent[-1]["session"]["audio"]["input"]["turn_detection"]["create_response"])

    async def test_failed_or_cancelled_greeting_does_not_wait_for_playback(self):
        for status in ("failed", "cancelled", "incomplete"):
            connection = Connection([
                {"type": "session.updated"},
                {"type": "response.created", "response": {"id": "greeting", "metadata": {"purpose": "opening_greeting"}}},
                {"type": "response.done", "response": {"id": "greeting", "status": status}},
            ])
            with patch("live_poc.app.connect", return_value=connection):
                await run_realtime_sideband(self.settings(), "call", [], "none")
            self.assertTrue(connection.sent[-1]["session"]["audio"]["input"]["turn_detection"]["create_response"])
            self.assertEqual(sum(e["type"] == "response.create" for e in connection.sent), 1)

    async def test_missing_playback_event_has_bounded_recovery(self):
        class StalledConnection(Connection):
            async def __aiter__(self):
                for event in self.events:
                    yield json.dumps(event)
                await asyncio.sleep(0.03)
                yield json.dumps({"type": "session.updated"})

        connection = StalledConnection([
            {"type": "session.updated"},
            {"type": "response.created", "response": {"id": "greeting", "metadata": {"purpose": "opening_greeting"}}},
        ])
        with patch("live_poc.app.connect", return_value=connection), patch("live_poc.app.OPENING_TIMEOUT_SECONDS", 0.005):
            await run_realtime_sideband(self.settings(), "call", [], "none")
        self.assertIn({"type": "response.cancel", "response_id": "greeting"}, connection.sent)
        self.assertEqual(sum(e["type"] == "response.create" for e in connection.sent), 1)
        self.assertTrue(connection.sent[-1]["session"]["audio"]["input"]["turn_detection"]["create_response"])

    async def test_missing_initial_ack_does_not_greet_after_timeout(self):
        class LateConnection(Connection):
            async def __aiter__(self):
                await asyncio.sleep(0.03)
                yield json.dumps({"type": "session.updated"})
        connection = LateConnection([])
        with patch("live_poc.app.connect", return_value=connection), patch("live_poc.app.OPENING_TIMEOUT_SECONDS", 0.005):
            await run_realtime_sideband(self.settings(), "call", [], "none")
        self.assertFalse(any(e["type"] == "response.create" for e in connection.sent))
        self.assertTrue(connection.sent[-1]["session"]["audio"]["input"]["turn_detection"]["create_response"])
