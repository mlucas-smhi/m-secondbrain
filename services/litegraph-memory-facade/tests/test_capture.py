import asyncio
import copy
import json
import os
from pathlib import Path
import unittest
import uuid
from unittest.mock import AsyncMock, patch
from dataclasses import replace

import psycopg

from memory_facade.app import Settings, tool_catalog, mcp
from memory_facade.capture import CaptureQueue, LeaseLost, public_status
from memory_facade.capture_worker import CaptureWorker, extraction_plan
from memory_facade.graph_memory import GraphMemory
from test_graph_memory import FakeGraph

DSN=os.getenv('TEST_CAPTURE_DSN','')


def arguments(content='Example A is vegan. Example B likes hiking.'):
    return dict(content=content,context='',source_session_ref='test-session',source_thread_ref='test-thread',idempotency_key='capture-1')


def unit(statement):
    return dict(statement=statement,evidence=statement,disposition='retain',question='')


def prepared(name='Example A'):
    return {'entities':[{'key':'person','family':'person','name':name}],
            'facts':[dict(key='diet',subject='person',predicate='dietary_preference',value='vegan',
                          content=name+' is vegan.',evidence=name+' is vegan.',confidence=1)]}


class ContractTests(unittest.TestCase):
    def test_capture_activation_requires_explicit_evaluated_writer_model(self):
        env=dict(LITEGRAPH_ENDPOINT='http://test',LITEGRAPH_API_KEY='synthetic',
            MCP_TENANT_GUID=str(uuid.UUID(int=1)),MCP_GRAPH_GUID=str(uuid.UUID(int=2)),
            GRAPH_MEMORY_ENABLED='true',MEMORY_WORKSPACE_ID='test',MEMORY_OWNER_REF='user:test',
            MEMORY_CAPTURE_ENABLED='true',MEMORY_CAPTURE_DSN='synthetic',MEMORY_WRITER_API_KEY='synthetic')
        with patch.dict(os.environ,env,clear=True):
            with self.assertRaisesRegex(RuntimeError,'MEMORY_WRITER_MODEL'): Settings.from_env()
            with patch.dict(os.environ,{'MEMORY_WRITER_MODEL':'gpt-4.1-2025-04-14'}):
                self.assertEqual(Settings.from_env().writer_model,'gpt-4.1-2025-04-14')

    def test_capture_replaces_external_graph_write(self):
        names=[t['name'] for t in tool_catalog(True,True)]
        self.assertNotIn('memory_store',names)
        self.assertEqual(names,['memory_search','memory_get','memory_capture','memory_capture_status','memory_orientation'])

    def test_extraction_is_grounded_not_a_free_summary(self):
        plan=extraction_plan([unit('Example A is vegan.')],'Example A is vegan.')
        self.assertEqual(plan[0]['state'],'pending')
        with self.assertRaisesRegex(ValueError,'invalid_capture_evidence'):
            extraction_plan([unit('Example A is a CEO.')],'Example A is vegan.')
        with self.assertRaises(ValueError): extraction_plan([], 'nonempty')

    def test_retained_fact_does_not_leak_draft_clarification(self):
        draft={**unit('Example A is vegan.'),'question':'Should I create a record?'}
        plan=extraction_plan([draft],'Example A is vegan.')
        self.assertEqual(plan[0]['question'],'')
        self.assertEqual(plan[0]['state'],'pending')


@unittest.skipUnless(DSN,'Set TEST_CAPTURE_DSN to a disposable PostgreSQL database')
class DurableCaptureTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        if '127.0.0.1' not in DSN and 'localhost' not in DSN:
            raise RuntimeError('Tests require an explicitly local disposable database')
        async with await psycopg.AsyncConnection.connect(DSN) as c:
            await c.execute('CREATE SCHEMA IF NOT EXISTS litegraph_two_poc')
            await c.execute(Path(__file__).parents[1].joinpath('memory_facade/capture.sql').read_text())
        self.workspace='test-'+str(uuid.uuid4())
        self.queue=CaptureQueue(DSN,self.workspace,'user:example')
        self.settings=Settings('fake','fake',str(uuid.UUID(int=1)),str(uuid.UUID(int=2)),
            graph_memory_enabled=True,workspace_id='workspace',owner_ref='user:owner')
        self.backend=FakeGraph()
        self.graph=GraphMemory(self.settings,self.backend)

    async def expire(self,job):
        async with self.queue.connection() as c:
            await c.execute('UPDATE litegraph_two_poc.memory_captures SET lease_until=now()-interval \'1 second\',available_at=now() WHERE id=%s',(job['id'],))

    async def test_capture_durable_idempotent_scoped_and_conflicts_rejected(self):
        first=await self.queue.capture(arguments())
        reopened=CaptureQueue(DSN,self.workspace,'user:example')
        second=await reopened.capture(arguments())
        self.assertEqual(first['capture_id'],second['capture_id'])
        self.assertFalse(first['graph_save_complete'])
        self.assertTrue(first['captured_durably'])
        self.assertEqual(len((await reopened.status({}))['captures']),1)
        wrong=CaptureQueue(DSN,self.workspace,'user:other')
        self.assertEqual((await wrong.status({'capture_id':first['capture_id']}))['captures'],[])
        self.assertIsNone(await wrong.claim())
        with self.assertRaisesRegex(ValueError,'idempotency_key_reused'):
            await reopened.capture(arguments('Changed meaning.'))

    async def test_credentials_and_long_passage_limits_do_not_write(self):
        for content in ('sk-'+'x'*32,'x'*24001):
            with self.assertRaises(ValueError): await self.queue.capture(arguments(content))
        self.assertEqual((await self.queue.status({}))['captures'],[])

    async def test_pending_recall_survives_new_session_and_preserves_source(self):
        passage='Example A lives in Austin. No, Denver now. There are two Johns; I have not said which John hikes.'
        receipt=await self.queue.capture(arguments(passage))
        reopened=CaptureQueue(DSN,self.workspace,'user:example')
        result=await reopened.search_pending({'query':'Denver'})
        match=result['matches'][0]
        self.assertEqual(match['capture_id'],receipt['capture_id'])
        self.assertEqual(match['content'],passage)
        self.assertFalse(match['graph_save_complete'])
        self.assertTrue(match['extraction_pending'])
        self.assertEqual(match['kind'],'PendingCapture')
        self.assertEqual(match['source_session_ref'],'test-session')
        self.assertEqual(match['source_thread_ref'],'test-thread')
        self.assertIn('not_finalized',match['authority'])
        self.assertEqual((await reopened.search_pending({'query':'unrelated'}))['matches'],[])
        for workspace,owner in ((self.workspace,'user:other'),('other-workspace','user:example')):
            self.assertEqual((await CaptureQueue(DSN,workspace,owner).search_pending({'query':'Denver'}))['matches'],[])

    async def test_pending_recall_excludes_complete_but_keeps_partial_and_failed(self):
        for index,state in enumerate(('pending','processing','complete','partial','needs_attention')):
            receipt=await self.queue.capture({**arguments(), 'idempotency_key':str(index)})
            async with self.queue.connection() as c:
                await c.execute('UPDATE litegraph_two_poc.memory_captures SET state=%s WHERE id=%s',
                    (state,receipt['capture_id']))
        results=await self.queue.search_pending({'query':'Example'})
        self.assertEqual({r['state'] for r in results['matches']},{'pending','processing','partial','needs_attention'})
        self.assertFalse(results['has_more_matches'])
        limited=await self.queue.search_pending({'query':'Example','max_results':2})
        self.assertEqual(len(limited['matches']),2)
        self.assertTrue(limited['has_more_matches'])
        self.assertEqual((await self.queue.search_pending({'query':'_%'}))['matches'],[])
        for args in ({'query':'Example','owner_ref':'user:other'}, {'query':'Example','max_results':True}):
            with self.assertRaises(ValueError): await self.queue.search_pending(args)

    async def test_pending_recall_bounds_output_without_cutting_corrections(self):
        passage='Example '+('context '*2500)+' actually not vegan.'
        for index in range(2):
            await self.queue.capture({**arguments(passage),'idempotency_key':str(index)})
        result=await self.queue.search_pending({'query':'vegan'})
        self.assertEqual(len(result['matches']),1)
        self.assertEqual(result['matches'][0]['content'],passage)
        self.assertTrue(result['has_more_matches'])

    async def test_mcp_search_keeps_pending_source_separate_from_graph_facts(self):
        await self.queue.capture(arguments('Example A now lives in Denver, not Austin.'))
        graph_result={'matches':[{'memory_id':'older-fact','content':{'content':'Example A lives in Austin.'}}]}
        app={'settings':replace(self.settings,capture_enabled=True),'capture_queue':self.queue}
        class Request:
            json=AsyncMock(return_value={'id':1,'method':'tools/call',
                'params':{'name':'memory_search','arguments':{'query':'Example'}}})
        request=Request(); request.app=app
        with patch('memory_facade.app.search_memory',AsyncMock(return_value=graph_result)):
            response=await mcp(request)
        result=json.loads(response.text)['result']
        self.assertFalse(result['isError'])
        data=result['structuredContent']
        self.assertEqual(data['matches'],graph_result['matches'])
        self.assertIn('not Austin',data['pending_captures']['matches'][0]['content'])
        self.assertFalse(data['pending_captures']['matches'][0]['graph_save_complete'])
        self.assertNotIn('pending_captures',graph_result)  # do not mutate graph result

    async def test_only_one_worker_claims_and_expired_worker_is_fenced(self):
        await self.queue.capture(arguments())
        claims=await asyncio.gather(self.queue.claim(),self.queue.claim())
        jobs=[j for j in claims if j]
        self.assertEqual(len(jobs),1)
        old=jobs[0]
        await self.expire(old)
        new=await self.queue.claim()
        self.assertNotEqual(old['lease_token'],new['lease_token'])
        with self.assertRaises(LeaseLost): await self.queue.checkpoint(old,[])
        await self.queue.checkpoint(new,[],state='complete')

    async def test_malformed_one_does_not_block_good_fact_and_retry_is_bounded(self):
        await self.queue.capture(arguments())
        model=type('Model',(),{'extract':AsyncMock(return_value=[unit('Example A is vegan.'),unit('Example B likes hiking.')])})()
        worker=CaptureWorker(self.queue,model,self.graph)
        invalid=prepared('Example B'); invalid['facts'][0]['object']='person'
        worker.resolver.prepare=AsyncMock(side_effect=[{'bundle':prepared()},{'bundle':invalid},{'bundle':invalid}])
        await worker.process(await self.queue.claim())
        status=(await self.queue.status({}))['captures'][0]
        self.assertEqual(status['saved_fact_count'],1)
        self.assertEqual(status['state'],'partial')
        self.assertEqual(status['saved_fact_count'],1)
        self.assertEqual(len(status['unresolved']),1)
        self.assertEqual(worker.resolver.prepare.await_count,3)

    async def test_definite_rejection_is_repaired_without_job_backoff(self):
        await self.queue.capture(arguments('Example A is vegan.'))
        model=AsyncMock(); model.extract.return_value=[unit('Example A is vegan.')]
        worker=CaptureWorker(self.queue,model,self.graph)
        invalid=prepared(); invalid['facts'][0]['object']='person'
        worker.resolver.prepare=AsyncMock(side_effect=[{'bundle':invalid},{'bundle':prepared()}])
        job=await self.queue.claim()
        await worker.process(job)
        result=(await self.queue.status({}))['captures'][0]
        self.assertEqual(result['state'],'complete')
        self.assertEqual(job['attempts'],1)
        self.assertNotIn('error',worker.resolver.prepare.call_args.args[1])
        self.assertEqual(worker.resolver.prepare.await_count,2)

    async def test_uncertain_store_keeps_payload_and_uses_backoff(self):
        await self.queue.capture(arguments('Example A is vegan.'))
        model=AsyncMock(); model.extract.return_value=[unit('Example A is vegan.')]
        worker=CaptureWorker(self.queue,model,self.graph)
        worker.resolver.prepare=AsyncMock(return_value={'bundle':prepared()})
        self.graph.store=AsyncMock(side_effect=RuntimeError('Unknown commit outcome'))
        job=await self.queue.claim()
        await worker.process(job)
        result=(await self.queue.status({}))['captures'][0]
        self.assertEqual(result['state'],'pending')
        self.assertEqual(self.graph.store.await_count,1)
        self.assertEqual(worker.resolver.prepare.await_count,1)
        async with self.queue.connection() as c:
            row=await (await c.execute('SELECT plan,available_at>now() AS deferred FROM litegraph_two_poc.memory_captures WHERE id=%s',(job['id'],))).fetchone()
        self.assertEqual(row['plan'][0]['state'],'prepared')
        self.assertEqual(row['plan'][0]['prepared'],self.graph.store.call_args.args[0])
        self.assertTrue(row['deferred'])

    async def test_restart_after_graph_commit_replays_prepared_payload_without_duplicate(self):
        await self.queue.capture(arguments('Example A is vegan.'))
        job=await self.queue.claim()
        plan=extraction_plan([unit('Example A is vegan.')],job['content'])
        args={**prepared(),'source_ref':'capture:'+str(job['id']),'source_session_ref':'test-session',
              'source_thread_ref':'test-thread','idempotency_key':'unit-0-repair-0'}
        plan[0].update(state='prepared',prepared=args)
        await self.queue.checkpoint(job,plan)
        receipt=await self.graph.store(args)  # process "dies" before queue ACK
        node_count=len(self.backend.nodes)
        await self.expire(job)
        restarted=CaptureWorker(self.queue,AsyncMock(),self.graph)
        restarted.resolver.prepare=AsyncMock(side_effect=AssertionError('Do not regenerate uncertain writes'))
        await restarted.process(await self.queue.claim())
        result=(await self.queue.status({}))['captures'][0]
        self.assertEqual(result['state'],'complete')
        self.assertEqual(result['receipts'],[receipt['receipt_id']])
        self.assertEqual(len(self.backend.nodes),node_count)

    async def test_ambiguity_is_retained_while_independent_fact_saves(self):
        content='Example A is vegan. John runs it.'
        await self.queue.capture(arguments(content))
        model=AsyncMock()
        model.extract.return_value=[unit('Example A is vegan.'),
            dict(statement='John runs it.',evidence='John runs it.',disposition='clarify',question='Which John, and what does he run?')]
        worker=CaptureWorker(self.queue,model,self.graph)
        worker.resolver.prepare=AsyncMock(return_value={'bundle':prepared()})
        await worker.process(await self.queue.claim())
        result=(await self.queue.status({}))['captures'][0]
        self.assertEqual(result['state'],'partial')
        self.assertEqual(result['saved_fact_count'],1)
        self.assertEqual(result['unresolved'][0]['state'],'needs_clarification')
        self.assertEqual(worker.resolver.prepare.await_count,1)
