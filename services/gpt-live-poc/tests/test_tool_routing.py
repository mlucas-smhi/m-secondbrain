import json
import unittest
from unittest.mock import AsyncMock, patch

from test_opening import Connection
from live_poc.app import Settings, run_realtime_sideband


class RoutingTests(unittest.IsolatedAsyncioTestCase):
    async def test_unknown_local_tool_is_not_onboarding_failure_or_executed(self):
        call = {'type': 'function_call', 'name': 'memory_store', 'call_id': 'local-1', 'arguments': '{}'}
        connection = Connection([
            {'type': 'response.function_call_arguments.done', **{k: v for k, v in call.items() if k != 'type'}},
            {'type': 'response.output_item.done', 'item': call},
        ])
        with patch('live_poc.app.connect', return_value=connection), patch('live_poc.app.verify_onboarding_code', new=AsyncMock()) as verify:
            await run_realtime_sideband(Settings('key', 'secret', voice_api='realtime'), 'call', [], 'none')
        verify.assert_not_awaited()
        outputs = [m['item'] for m in connection.sent if m['type'] == 'conversation.item.create']
        self.assertEqual(len(outputs), 1)
        result = json.loads(outputs[0]['output'])
        self.assertEqual(result['error_code'], 'tool_not_allowed')
        self.assertEqual(result['status'], 'rejected')
        responses = [m for m in connection.sent if m['type'] == 'response.create']
        self.assertEqual(len(responses), 1)
        self.assertIn('not available', responses[0]['response']['instructions'])
        self.assertEqual(responses[0]['response']['tool_choice'], 'none')
        self.assertFalse(any('instructions' in m.get('session', {}) for m in connection.sent))
