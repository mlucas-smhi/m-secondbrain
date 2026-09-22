import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from live_poc.app import Settings, run_realtime_sideband


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


class MCPFollowupTests(unittest.IsolatedAsyncioTestCase):
    async def test_tool_followups_are_bounded_deduplicated_and_reset_on_speech(self):
        events = []
        for i in range(4):
            events.extend([{"type": "response.mcp_call.completed", "item_id": str(i)}] * 2)
        events.extend([
            {"type": "input_audio_buffer.speech_started"},
            {"type": "response.mcp_call.completed", "item_id": "next-turn"},
        ])
        connection = Connection(events)
        settings = Settings("key", "secret", voice_api="realtime")
        with patch("live_poc.app.connect", return_value=connection):
            await run_realtime_sideband(settings, "call", [], "auto")
        responses = [m["response"] for m in connection.sent if m["type"] == "response.create"]
        self.assertEqual([r["tool_choice"] for r in responses], ["auto", "auto", "auto", "none", "auto"])
