import json
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

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
    def graph_settings(self):
        return Settings('key', 'secret', voice_api='realtime', memory_schema_mode='entity-memory.v1',
                        mcp_server_url='https://memory.example/mcp', mcp_authorization='synthetic',
                        mcp_allowed_tools=('memory_search', 'memory_get', 'memory_store'))

    def assert_itinerary_and_memory_contract(self, instructions):
        for topic in range(1, 8):
            self.assertIn('## Topic '+str(topic)+' —', instructions)
        self.assertIn('You own the agenda', instructions)
        self.assertIn('status=rejected', instructions)
        self.assertIn('SAME key and IDENTICAL bundle', instructions)
        self.assertIn('Do not routinely ask', instructions)
        self.assertIn('No checkpoint-writing tool is currently advertised', instructions)

    async def test_returning_call_keeps_full_agenda_and_contract_after_each_tool(self):
        connection = Connection([{'type': 'response.mcp_call.completed', 'item_id': str(i)} for i in range(4)])
        context = {'status': 'recognized', 'actor_ref': 'user:example', 'workspace_id': 'workspace',
                   'thread_id': 'thread', 'current_topic': 2, 'onboarding_state': 'in_progress'}
        with patch('live_poc.app.connect', return_value=connection):
            await run_realtime_sideband(self.graph_settings(), 'call', [], 'auto', context)
        responses = [m['response'] for m in connection.sent if m['type']=='response.create']
        self.assertEqual(len(responses), 4)
        for response in responses:
            self.assert_itinerary_and_memory_contract(response['instructions'])
            self.assertIn('current_topic: 2', response['instructions'])
        self.assertEqual(responses[-1]['tool_choice'], 'none')
        for response in responses[:-1]:
            self.assertIn('error_code and field_path', response['instructions'])
            self.assertIn('retry once before reporting failure', response['instructions'])
            self.assertIn('Never guess missing facts or entity identity', response['instructions'])
            self.assertIn('retry_action=stop', response['instructions'])

    async def test_first_call_uses_confirmed_context_on_later_tool_followup(self):
        connection = Connection([
            {'type': 'response.function_call_arguments.done', 'name': 'validate_onboarding_code',
             'call_id': 'verification', 'arguments': '{"code":"synthetic"}'},
            {'type': 'response.mcp_call.completed', 'item_id': 'save'},
        ])
        confirmed = {'status': 'confirmed', 'actor_ref': 'user:example', 'workspace_id': 'workspace',
                     'thread_id': 'thread', 'current_topic': 1}
        with patch('live_poc.app.connect', return_value=connection), patch('live_poc.app.verify_onboarding_code', new=AsyncMock(return_value=confirmed)):
            await run_realtime_sideband(self.graph_settings(), 'call', [], 'auto')
        response = [m['response'] for m in connection.sent if m['type']=='response.create'][-1]
        self.assert_itinerary_and_memory_contract(response['instructions'])
        self.assertIn('authentication_status: confirmed', response['instructions'])
        self.assertIn('source_thread_ref for memory writes: thread', response['instructions'])

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
