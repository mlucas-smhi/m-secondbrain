import copy
import json
import unittest
import uuid
from unittest.mock import AsyncMock

from memory_facade.app import Settings
from memory_facade.capture_worker import GraphResolver
from memory_facade.graph_memory import GraphMemory
from test_graph_memory import FakeGraph, bundle


def call(name,args):
    return {'output':[{'type':'function_call','name':name,'call_id':str(uuid.uuid4()),'arguments':json.dumps(args)}]}


class ResolverTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.graph=GraphMemory(Settings('fake','fake',str(uuid.UUID(int=1)),str(uuid.UUID(int=2)),
            workspace_id='workspace',owner_ref='user:test'),FakeGraph())
        self.job={'content':'Example A is vegan.','context':''}
        self.unit={'statement':'Example A is vegan.','evidence':'Example A is vegan.','state':'pending'}
        self.payload={'entities':[{'key':'person','family':'person','name':'Example A'}],
            'facts':[{'key':'diet','subject':'person','predicate':'dietary_preference','value':'vegan',
                      'content':'Example A is vegan.','evidence':'model tries to replace evidence','confidence':1}]}

    async def test_new_entity_search_required_and_evidence_cannot_be_replaced(self):
        model=AsyncMock()
        model.response.side_effect=[call('prepare_fact',copy.deepcopy(self.payload)),
            call('memory_search',{'query':'Example A'}),call('prepare_fact',copy.deepcopy(self.payload))]
        prepared=await GraphResolver(model,self.graph).prepare(self.job,self.unit,AsyncMock())
        self.assertEqual(model.response.await_count,3)
        self.assertEqual(prepared['bundle']['facts'][0]['evidence'],self.unit['evidence'])
        self.assertFalse(self.graph.request.nodes)  # resolution never writes

    async def test_unread_existing_id_cannot_be_used(self):
        self.payload['entities'][0]['existing_id']=str(uuid.uuid4())
        model=AsyncMock()
        model.response.side_effect=[call('prepare_fact',self.payload),call('needs_clarification',{'question':'Which person?'})]
        result=await GraphResolver(model,self.graph).prepare(self.job,self.unit,AsyncMock())
        self.assertEqual(result,{'question':'Which person?'})
        self.assertFalse(self.graph.request.nodes)

    async def test_known_fact_requires_current_fact_read(self):
        saved=await self.graph.store(bundle())
        model=AsyncMock()
        fact_id=saved['memory_ids'][0]
        model.response.side_effect=[call('already_known',{'memory_id':fact_id}),
            call('memory_get',{'memory_id':saved['entities']['andrew']['id']}),call('already_known',{'memory_id':fact_id})]
        result=await GraphResolver(model,self.graph).prepare(self.job,self.unit,AsyncMock())
        self.assertEqual(result,{'already_known':fact_id})
        self.assertEqual(model.response.await_count,3)

    async def test_budget_cannot_invent_success(self):
        model=AsyncMock()
        model.response.return_value=call('delete_everything',{})
        with self.assertRaisesRegex(RuntimeError,'capture_resolver_budget'):
            await GraphResolver(model,self.graph).prepare(self.job,self.unit,AsyncMock())
        self.assertEqual(model.response.await_count,10)
        self.assertFalse(self.graph.request.nodes)
