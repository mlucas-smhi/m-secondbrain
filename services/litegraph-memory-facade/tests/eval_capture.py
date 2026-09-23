"""Opt-in model evaluation: LOCAL disposable queue and synthetic graph only.

OPENAI_API_KEY and TEST_CAPTURE_DSN must be supplied privately by the operator.
Set LITEGRAPH_TEST_ENDPOINT to use a disposable localhost LiteGraph instead of
the in-memory double. Always creates a fresh synthetic tenant/graph. Never uses
live credentials or owner memories. Charges bounded Responses API requests.
"""
import asyncio
import json
import os
import re
from pathlib import Path
import uuid
import time
from urllib.parse import urlsplit

import psycopg

from memory_facade.app import Settings, litegraph_request
from memory_facade.capture import CaptureQueue
from memory_facade.capture_worker import CaptureWorker, ResponsesModel
from memory_facade.graph_memory import GraphMemory
from test_graph_memory import FakeGraph

TEXT=("Jenna Example is vegan and she works for Northstar Test Company. She lives in Austin, "
      "no, sorry, Denver. She's really into hiking on weekends. Anyway I run Example Robotics Club. "
      "John likes those. I mean, the robots. There are two Johns in the club and I haven't said which one.")

VARIANT=("Tessa Sample avoids gluten and she works for Meadow Test Company. She lives in Portland, "
         "wait, Boston now. She loves swimming before work. Anyway I run Sample Pottery Club. "
         "Tessa avoids gluten, yes, I said that already. Sam likes that stuff. I mean, pottery. "
         "There are two Sams in the club and I haven't said which one.")

RELATIONSHIPS=("Avery Sample is my partner. Our anniversary is May 4; I haven't given the year. "
    "Devon Example works for Harbor Test Company and is my boss. "
    "We're going to Colombia for a holiday in November, no exact dates yet. "
    "By we I mean Avery and me. Devon is vegetarian, not vegan.")

COMMUNICATION=("For real-time issues I prefer direct and succinct communication, but for projects "
    "and personal discussions I like a casual, exploratory style. Phone and text are my primary "
    "channels; email is the fallback when those are delayed. Urgent messages: phone first, text second. "
    "Do not interrupt me after 10pm unless it is a major issue; otherwise wait until morning. "
    "I am comfortable with 2 proactively contacting me by phone or text for important issues, "
    "but only once those channels are integrated. I usually operate in Central Standard Time. "
    "I work with people in New York and Utah, and worldwide.")


async def check_communication(graph, status, worker, queue):
    assert status['state']=='complete', 'Clear communication preferences need attention'
    nodes=await graph.list_records('nodes')
    entities=[n for n in nodes if n['Data'].get('kind')=='Entity']
    facts=[n['Data'] for n in nodes if n['Data'].get('kind')=='Fact']
    assert all(f['classification_status']=='approved' for f in facts), 'Ordinary preference left pending classification'
    assert all(f['subject_name']=='Morgan Example' for f in facts), 'Preference attached to wrong person'
    assert not any(n['Data']['canonical_name'].lower() in ('2','two','planet earth','earth') for n in entities), 'Invented assistant-person/planet entity'
    preferences=[f for f in facts if f['predicate']=='communication_preference']
    combined=' '.join(f['content']+' '+str(f['value']) for f in preferences).lower()
    assert all(term in combined for term in ('succinct','exploratory','email','fallback','urgent','10','major','integrat','important')), 'Lost preference qualifiers'
    proactive=[f for f in preferences if 'integrat' in f['content'].lower()]
    assert proactive and any('2' in f['content'] and 'important' in f['content'].lower() for f in proactive), 'Assistant/contact conditions lost'
    assert any(f['predicate']=='time_zone' and 'central' in str(f['value']).lower() for f in facts), 'Timezone classification lost'
    places={n['GUID']:n['Data']['canonical_name'] for n in entities}
    assert {places.get(f['object_ref']) for f in facts if f['predicate']=='collaborates_with_people_in'}=={'New York','Utah'}, 'Collaborator location links lost'
    assert any(f['predicate']=='work_geography' for f in facts), 'Broad work geography lost'
    person=next(n for n in entities if n['Data']['canonical_name']=='Morgan Example')
    before_quiet={f['memory_ref'] for f in preferences if '10' in f['content']}
    before_style={f['memory_ref'] for f in preferences if 'exploratory' in f['content'].lower()}
    follow=await queue.capture(dict(content='For urgent messages, change my earlier preference: text first now, phone second. My quiet hours and casual exploratory style are unchanged.',
        context='The caller explicitly introduced themself as Morgan Example.',source_session_ref='synthetic-preference-followup',
        source_thread_ref='synthetic-eval-thread',idempotency_key='correct-urgency'))
    await worker.process(await queue.claim())
    state=(await queue.status({'capture_id':follow['capture_id']}))['captures'][0]
    assert state['state']=='complete', 'Preference correction did not complete'
    recalled=await GraphMemory(graph.settings,graph.request).context(person['GUID'])
    current={n['GUID']:n['Data'] for n in recalled['facts']}
    assert before_quiet<=set(current) and before_style<=set(current), 'Urgency correction erased unrelated communication facet'
    corrected=[f for f in current.values() if f.get('supersedes_memory_id') and 'urgent' in f['content'].lower()]
    assert corrected and any('text' in f['content'].lower() and 'first' in f['content'].lower() for f in corrected), 'Urgency correction missing'
    print('PASS communication: assistant identity, conditional proactive preference (not permission), approved vocabulary, location links, independent facets and later correction.',flush=True)


async def check_relationship_passage(graph, status):
    assert status['state']=='complete', 'Clear relationship passage did not finish'
    nodes=await graph.list_records('nodes')
    entities={n['GUID']:n['Data'] for n in nodes if n['Data'].get('kind')=='Entity'}
    facts=[n['Data'] for n in nodes if n['Data'].get('kind')=='Fact']
    def name(identifier): return entities.get(identifier,{}).get('canonical_name','')
    def link(subject,predicate,target):
        return any(name(f['subject_ref'])==subject and f['predicate']==predicate
                   and name(f['object_ref'])==target for f in facts)
    assert link('Morgan Example','partner_of','Avery Sample') or link('Avery Sample','partner_of','Morgan Example'), 'Partner relationship lost'
    assert link('Morgan Example','reports_to','Devon Example') or link('Devon Example','boss_of','Morgan Example'), 'Boss relationship lost or reversed'
    assert link('Devon Example','works_at','Harbor Test Company'), 'Employer attached to wrong person'
    assert not any(name(f['subject_ref'])=='Morgan Example' and f['predicate']=='works_at' for f in facts), 'Caller employer inferred from boss'
    anniversary=[f for f in facts if f['predicate']=='anniversary_date']
    assert len(anniversary)==1 and anniversary[0]['value'] in ('May 4','May 04','05-04','--05-04'), 'Anniversary date precision lost'
    assert not any(re.search(r'\b(?:19|20)\d{2}\b',f['content']+' '+str(f['value'] or '')) for f in facts), 'Unstated year invented'
    destinations=[f for f in facts if f['predicate']=='destination' and name(f['object_ref'])=='Colombia']
    assert len(destinations)==1 and entities[destinations[0]['subject_ref']]['family']=='event', 'Trip not linked to destination'
    trip=destinations[0]['subject_ref']
    participants={name(f['subject_ref']) for f in facts if f['predicate']=='participates_in' and f['object_ref']==trip}
    assert {'Morgan Example','Avery Sample'}<=participants, 'Trip participants lost'
    assert any(f['subject_ref']==trip and f['predicate']=='event_timing' and
               'november' in str(f['value'] or '').lower() for f in facts), 'Trip month missing as a literal event attribute'
    superseded={f.get('supersedes_memory_id') for f in facts}
    diet=[f for f in facts if f['predicate']=='dietary_preference' and name(f['subject_ref'])=='Devon Example'
          and f['memory_ref'] not in superseded]
    diet_values=[str(f['value']).strip().lower() for f in diet]
    positive={'vegetarian','vegetarian (not vegan)','vegetarian, not vegan'}
    assert sum(v in positive for v in diet_values)==1 and set(diet_values)<=positive|{'not vegan'}, 'Diet changed or duplicated'
    assert any('not vegan' in f['content'].lower() for f in diet), 'Diet negation lost'
    assert all(e['family'] not in ('task','decision','interaction') for e in entities.values()), 'Memory claimed operational execution'
    assert not any(re.search(r'\b(booked|confirmed booking)\b',f['content'],re.I) for f in facts), 'Trip intention became a booking'
    fresh=GraphMemory(graph.settings,graph.request)
    boss_id=next(identifier for identifier,e in entities.items() if e['canonical_name']=='Devon Example')
    recalled=await fresh.context(boss_id)
    predicates={n['Data']['predicate'] for n in recalled['facts']}
    assert {'works_at','dietary_preference'}<=predicates and predicates & {'reports_to','boss_of'}, 'Fresh-reader boss character sheet incomplete'
    print('PASS relationship passage: partner, partial anniversary date, boss/employer, trip participants/destination/month, diet negation; no booking claim.',flush=True)


class MeasuredModel(ResponsesModel):
    def __init__(self,*args):
        super().__init__(*args)
        self.calls=0; self.input_tokens=0; self.output_tokens=0; self.resolved_model=None
        self.trace=[]

    async def response(self,**payload):
        result=await super().response(**payload)
        self.calls+=1
        self.input_tokens+=result.get('usage',{}).get('input_tokens',0)
        self.output_tokens+=result.get('usage',{}).get('output_tokens',0)
        self.resolved_model=result.get('model')
        if isinstance(payload.get('input'),list):
            unit=json.loads(payload['input'][0]['content']).get('unit',{}).get('statement')
            for item in result.get('output',[]):
                if item.get('type')=='function_call':
                    self.trace.append({'unit':unit,'tool':item['name'],'arguments':json.loads(item['arguments'])})
        return result


async def main():
    started=time.monotonic()
    variant=os.getenv('CAPTURE_EVAL_CASE','original')
    if variant not in ('original','variant'): raise RuntimeError('Unknown synthetic test case')
    passage=TEXT if variant=='original' else VARIANT
    person='Jenna Example' if variant=='original' else 'Tessa Sample'
    relationships=os.getenv('CAPTURE_EVAL_RELATIONSHIPS')=='1'
    communication=os.getenv('CAPTURE_EVAL_COMMUNICATION')=='1'
    if relationships: passage=RELATIONSHIPS; person='Avery Sample'
    if communication: passage=COMMUNICATION; person='Morgan Example'
    particulars=('vegan','northstar','denver','hiking') if variant=='original' else ('gluten','meadow','boston','swimming')
    club='robotics' if variant=='original' else 'pottery'
    stale='austin' if variant=='original' else 'portland'
    qualifier='weekend' if variant=='original' else 'before work'
    ambiguous='john' if variant=='original' else 'sam'
    dsn=os.environ['TEST_CAPTURE_DSN']
    if '127.0.0.1' not in dsn: raise RuntimeError('Local test database required')
    async with await psycopg.AsyncConnection.connect(dsn) as c:
        await c.execute('CREATE SCHEMA IF NOT EXISTS litegraph_two_poc')
        await c.execute(Path(__file__).parents[1].joinpath('memory_facade/capture.sql').read_text())
    q=CaptureQueue(dsn,'eval-'+str(uuid.uuid4()),'user:test')
    endpoint=os.getenv('LITEGRAPH_TEST_ENDPOINT')
    if endpoint:
        if urlsplit(endpoint).hostname not in ('127.0.0.1','localhost'):
            raise RuntimeError('Disposable localhost graph required')
        settings=Settings(endpoint,'synthetic-local-test-only',str(uuid.uuid4()),str(uuid.uuid4()),
            graph_memory_enabled=True,workspace_id=q.workspace,owner_ref='user:test',timeout_seconds=20)
        await litegraph_request(settings,'PUT','/v1.0/tenants',json_body={
            'GUID':settings.tenant_guid,'Name':'synthetic-capture-eval','Active':True})
        await litegraph_request(settings,'PUT',f'/v1.0/tenants/{settings.tenant_guid}/graphs',json_body={
            'GUID':settings.graph_guid,'Name':'synthetic-capture-eval','Data':{
                'memory_schema_version':'entity-memory.v1','workspace_id':q.workspace,'owner_ref':'user:test'}})
        graph=GraphMemory(settings,litegraph_request)
    else:
        graph=GraphMemory(Settings('fake','fake',str(uuid.UUID(int=1)),str(uuid.UUID(int=2)),
            graph_memory_enabled=True,workspace_id=q.workspace,owner_ref='user:test'),FakeGraph())
    model=MeasuredModel(os.environ['OPENAI_API_KEY'],os.getenv('MEMORY_WRITER_MODEL','gpt-4.1-mini'))
    worker=CaptureWorker(q,model,graph)
    captured=await q.capture(dict(content=passage,context='The caller explicitly introduced themself as Morgan Example.',
        source_session_ref='synthetic-eval',source_thread_ref='synthetic-eval-thread',idempotency_key='paragraph'))
    reopened=CaptureQueue(dsn,q.workspace,q.owner)
    pending=await reopened.search_pending({'query':person})
    assert pending['matches'][0]['content']==passage, 'Pending source not recalled before extraction'
    assert not pending['matches'][0]['graph_save_complete'], 'Pending source misrepresented as graph save'
    job=await q.claim()
    await worker.process(job)
    for _ in range(2):
        status=(await q.status({'capture_id':captured['capture_id']}))['captures'][0]
        if status['state']!='pending': break
        # Accelerate only this synthetic job's retry delay; production uses backoff.
        async with q.connection() as c:
            await c.execute('UPDATE litegraph_two_poc.memory_captures SET available_at=now() WHERE id=%s AND workspace_id=%s',
                            (captured['capture_id'],q.workspace))
        await worker.process(await q.claim())
    statuses=await q.status({'capture_id':captured['capture_id']})
    print(json.dumps({'stage':'processed','status':statuses}),flush=True)
    print(json.dumps({'model':model.resolved_model,'calls':model.calls,'input_tokens':model.input_tokens,
        'output_tokens':model.output_tokens,'processing_seconds':round(time.monotonic()-started,1)}),flush=True)
    if os.getenv('CAPTURE_EVAL_TRACE')=='1': print(json.dumps({'synthetic_trace':model.trace}),flush=True)
    if communication:
        await check_communication(graph,statuses['captures'][0],worker,q)
        print(json.dumps({'total_calls_including_followup':model.calls,'total_seconds':round(time.monotonic()-started,1)}),flush=True)
        return
    if relationships:
        await check_relationship_passage(graph,statuses['captures'][0])
        return
    nodes=await graph.list_records('nodes')
    facts=[n['Data'] for n in nodes if n['Data'].get('kind')=='Fact']
    content=' '.join(f['content'] for f in facts).lower()
    assert all(word in content for word in (*particulars,club)), 'Missing clear particular'
    for word in particulars:
        assert any(word in f['content'].lower() and f['subject_name']==person for f in facts), 'Wrong subject for '+word
    assert any(club in f['content'].lower() and f['subject_name']=='Morgan Example' for f in facts), 'Caller role mapped to wrong person'
    assert any(particulars[-1] in f['content'].lower() and qualifier in f['content'].lower()
               and f['subject_name']==person for f in facts), 'Activity qualifier lost'
    residences=[f for f in facts if f['subject_name']==person and f['predicate']=='lives_in']
    assert len(residences)==1 and residences[0]['object_ref'], 'Current residence must be one entity relationship'
    residence=next(n['Data'] for n in nodes if n['GUID']==residences[0]['object_ref'])
    assert residence['canonical_name'].lower()==particulars[2], 'Superseded location saved as current'
    # Historical correction wording may mention the old city; the current link must not.
    assert residence['canonical_name'].lower()!=stale
    assert not any(f['subject_name'].lower().split()[0]==ambiguous for f in facts), 'Ambiguous identity guessed'
    assert any(ambiguous in u['statement'].lower() for u in statuses['captures'][0]['unresolved']), 'Ambiguity lost'
    assert all(ambiguous in u['statement'].lower() for u in statuses['captures'][0]['unresolved']), 'Clear fact unnecessarily unresolved'
    assert sum(particulars[0] in f['content'].lower() and f['subject_name']==person for f in facts)==1, 'Repeated fact duplicated'
    people=[n for n in nodes if n['Data'].get('kind')=='Entity' and n['Data'].get('canonical_name')==person]
    assert len(people)==1, 'One named person split across duplicate entities'
    activity=next(f for f in facts if particulars[-1] in f['content'].lower() and f['subject_name']==person)
    assert activity['predicate']=='interested_in' and activity['object_ref'], 'Activity not saved as relationship'
    target=next(n['Data'] for n in nodes if n['GUID']==activity['object_ref'])
    assert target['family']=='activity' and particulars[-1] in target['canonical_name'].lower(), 'Wrong activity endpoint'
    fresh=GraphMemory(graph.settings,graph.request)
    recalled=await fresh.context(activity['subject_ref'])
    assert any(qualifier in n['Data']['content'].lower() for n in recalled['facts']), 'Fresh-reader qualifier recall failed'
    review_job={'content':passage,'context':'The caller explicitly introduced themself as Morgan Example.'}
    clear_unit={'statement':activity['content'],'evidence':activity['evidence']}
    review=await worker.resolver.review_clarification(review_job,clear_unit,
        f'Is {particulars[-1]} {qualifier} a general activity, or a specific established thing?',[])
    assert review['decision']=='representation_issue', 'Internal representation question passed semantic review'
    ambiguous_unit={'statement':f'{ambiguous.title()} likes the club activity.','evidence':passage}
    review=await worker.resolver.review_clarification(review_job,ambiguous_unit,
        f'Which of the two people named {ambiguous.title()} likes the club activity?',[])
    assert review['decision']=='source_ambiguity', 'Real identity ambiguity suppressed'
    print('PASS '+variant+': rambling multi-person paragraph, qualifiers, correction, repetition and unresolved identity.',flush=True)

    if os.getenv('CAPTURE_EVAL_FOLLOWUP')=='1':
        started=time.monotonic(); calls_before=model.calls
        diet='is still vegan' if variant=='original' else 'still avoids gluten'
        followup=f'{person} now lives in Seattle instead of {particulars[2].title()}. She {diet}. She also likes cycling after lunch.'
        follow=await reopened.capture(dict(content=followup,context='The caller explicitly introduced themself as Morgan Example.',
            source_session_ref='synthetic-later-call',source_thread_ref='synthetic-eval-thread',idempotency_key='followup'))
        # A new worker/session must resolve existing entities and facts, not clone them.
        restarted=CaptureWorker(reopened,model,GraphMemory(graph.settings,graph.request))
        await restarted.process(await reopened.claim())
        state=(await reopened.status({'capture_id':follow['capture_id']}))['captures'][0]
        print(json.dumps({'stage':'followup','status':state,'calls':model.calls-calls_before,
            'processing_seconds':round(time.monotonic()-started,1)}),flush=True)
        assert state['state']=='complete', 'Clear followup failed to finish'
        current=await GraphMemory(graph.settings,graph.request).context(people[0]['GUID'])
        current_facts=[n['Data'] for n in current['facts'] if n['Data']['subject_ref']==people[0]['GUID']]
        homes=[f for f in current_facts if f['predicate']=='lives_in']
        assert len(homes)==1 and homes[0]['supersedes_memory_id']==residences[0]['memory_ref'], 'Correction did not supersede prior residence'
        home=await graph.read(homes[0]['object_ref'])
        assert home['Data']['canonical_name']=='Seattle', 'Correction has wrong city link'
        assert any('cycling' in f['content'].lower() and 'after lunch' in f['content'].lower() for f in current_facts), 'Followup qualifier lost'
        assert sum(particulars[0] in f['content'].lower() for f in current_facts)==1, 'Followup duplicated the unchanged diet'
        all_nodes=await graph.list_records('nodes')
        assert sum(n['Data'].get('kind')=='Entity' and n['Data'].get('canonical_name')==person for n in all_nodes)==1, 'Followup cloned the person'
        pending=await reopened.search_pending({'query':'Seattle'})
        assert not any(m['capture_id']==follow['capture_id'] for m in pending['matches']), 'Completed capture still shown as pending'
        print('PASS later-call correction, existing-entity reuse, unchanged-fact deduplication and fresh-reader recall.',flush=True)


if __name__=='__main__': asyncio.run(main())
