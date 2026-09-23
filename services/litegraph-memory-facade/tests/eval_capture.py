"""Opt-in model evaluation: LOCAL disposable queue + in-memory fake graph only.

OPENAI_API_KEY and TEST_CAPTURE_DSN must be supplied privately by the operator.
Never connects to a live memory graph. Charges bounded Responses API requests.
"""
import asyncio
import json
import os
from pathlib import Path
import uuid

import psycopg

from memory_facade.app import Settings
from memory_facade.capture import CaptureQueue
from memory_facade.capture_worker import CaptureWorker, ResponsesModel
from memory_facade.graph_memory import GraphMemory
from test_graph_memory import FakeGraph

TEXT=("Jenna Example is vegan and she works for Northstar Test Company. She lives in Austin, "
      "no, sorry, Denver. She's really into hiking on weekends. Anyway I run Example Robotics Club. "
      "John likes those. I mean, the robots. There are two Johns in the club and I haven't said which one.")


async def main():
    dsn=os.environ['TEST_CAPTURE_DSN']
    if '127.0.0.1' not in dsn: raise RuntimeError('Local test database required')
    async with await psycopg.AsyncConnection.connect(dsn) as c:
        await c.execute('CREATE SCHEMA IF NOT EXISTS litegraph_two_poc')
        await c.execute(Path(__file__).parents[1].joinpath('memory_facade/capture.sql').read_text())
    q=CaptureQueue(dsn,'eval-'+str(uuid.uuid4()),'user:test')
    graph=GraphMemory(Settings('fake','fake',str(uuid.UUID(int=1)),str(uuid.UUID(int=2)),
        graph_memory_enabled=True,workspace_id='workspace',owner_ref='user:test'),FakeGraph())
    model=ResponsesModel(os.environ['OPENAI_API_KEY'],os.getenv('MEMORY_WRITER_MODEL','gpt-4.1-mini'))
    worker=CaptureWorker(q,model,graph)
    captured=await q.capture(dict(content=TEXT,context='The caller explicitly introduced themself as Morgan Example.',
        source_session_ref='synthetic-eval',source_thread_ref='synthetic-eval-thread',idempotency_key='paragraph'))
    job=await q.claim()
    await worker.process(job)
    statuses=await q.status({'capture_id':captured['capture_id']})
    print(json.dumps({'stage':'processed','status':statuses}),flush=True)
    facts=[n['Data'] for n in graph.request.nodes.values() if n['Data'].get('kind')=='Fact']
    content=' '.join(f['content'] for f in facts).lower()
    assert all(word in content for word in ('vegan','northstar','denver','hiking','robotics')), 'Missing clear particular'
    assert 'austin' not in content, 'Superseded location saved as current'
    assert not any('john' in f['content'].lower() for f in facts), 'Ambiguous John guessed'
    assert any('john' in u['statement'].lower() for u in statuses['captures'][0]['unresolved']), 'Ambiguity lost'
    print('PASS: rambling multi-person paragraph, explicit correction, independent saves and unresolved identity.',flush=True)


if __name__=='__main__': asyncio.run(main())
