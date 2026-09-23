import unittest
from unittest.mock import patch, AsyncMock

from live_poc.app import Settings, realtime_call_payload, mcp_continuation_event, memory_orientation_snapshot


class CaptureContractTests(unittest.IsolatedAsyncioTestCase):
    def settings(self):
        return Settings('key','secret',voice_api='realtime',memory_schema_mode='conversational-capture.v1',
            mcp_server_url='https://memory.example/mcp',mcp_authorization='synthetic',
            mcp_allowed_tools=('memory_search','memory_get','memory_capture','memory_capture_status','memory_orientation','memory_store'))

    def context(self):
        return dict(status='recognized',actor_ref='user:example',workspace_id='workspace',thread_id='thread')

    async def test_capture_mode_is_gated_and_hides_direct_graph_writes(self):
        s=self.settings()
        self.assertFalse(realtime_call_payload(s).get('tools'))
        payload=realtime_call_payload(s,self.context(),'call')
        self.assertNotIn('memory_store',payload['tools'][0]['allowed_tools']['tool_names'])
        self.assertIn('No graph keys, UUIDs, predicates',payload['instructions'])
        self.assertIn('empty onboarding checkpoint NEVER proves an empty',payload['instructions'])
        for missing in ('actor_ref','workspace_id','thread_id'):
            context=self.context(); context.pop(missing)
            self.assertEqual(realtime_call_payload(s,context,'call')['tools'],[])

    async def test_orientation_unavailable_does_not_mean_empty(self):
        with patch('live_poc.app.ClientSession',side_effect=TimeoutError):
            context=await memory_orientation_snapshot(self.settings(),self.context())
        self.assertEqual(context['memory_orientation']['status'],'unavailable')
        self.assertIn('Do not claim it is empty',context['memory_orientation']['instruction'])
        self.assertEqual((await memory_orientation_snapshot(self.settings(),{'status':'not_found'})),{'status':'not_found'})

    async def test_followup_retains_capture_and_agenda_rules(self):
        instructions=realtime_call_payload(self.settings(),self.context(),'call')['instructions']
        response=mcp_continuation_event(True,instructions)['response']['instructions']
        self.assertIn('durable capture only, not graph persistence',response)
        self.assertIn('Do not poll after every capture',response)
        self.assertIn('You own the agenda',response)
        self.assertIn('including passages from earlier calls',response)
        self.assertIn('not finalized graph facts',response)
        self.assertIn('without claiming the graph update is finished',response)
