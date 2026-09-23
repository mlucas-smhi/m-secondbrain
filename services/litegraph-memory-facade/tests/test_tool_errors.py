import json
import unittest
import uuid
from unittest.mock import AsyncMock, patch

from memory_facade.app import Settings, mcp
from memory_facade.errors import GUIDANCE, validation_failure
from memory_facade.graph_memory import GraphMemory
from test_graph_memory import FakeGraph, bundle


class ToolErrorTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.settings = Settings('http://graph', 'secret', str(uuid.UUID(int=1)), str(uuid.UUID(int=2)),
                                 graph_memory_enabled=True, workspace_id='workspace', owner_ref='user:owner')

    async def call(self, arguments, name='memory_store', failure=None, backend=None):
        request = {'settings': self.settings}
        class Request:
            app = request
            json = AsyncMock(return_value={'jsonrpc': '2.0', 'id': 17, 'method': 'tools/call',
                                          'params': {'name': name, 'arguments': arguments}})
        if backend:
            with patch('memory_facade.app.litegraph_request', new=backend):
                response = await mcp(Request())
        else:
            with patch('memory_facade.app.store_memory', new=AsyncMock(side_effect=failure)):
                response = await mcp(Request())
        self.assertEqual(response.status, 200)
        return json.loads(response.text)

    async def test_validation_codes_are_tool_results_not_protocol_errors(self):
        for code in GUIDANCE:
            with self.subTest(code=code):
                with self.assertLogs('litegraph_memory_facade', 'WARNING') as log:
                    response = await self.call({}, failure=ValueError(code))
                self.assertNotIn('error', response)
                self.assertEqual(response['id'], 17)
                result = response['result']
                self.assertTrue(result['isError'])
                self.assertEqual(json.loads(result['content'][0]['text']), result['structuredContent'])
                self.assertEqual(result['structuredContent']['error_code'], code)
                self.assertFalse(result['structuredContent']['save_confirmed'])
                self.assertIn(code, str(log.output))

    async def test_backend_failure_preserves_uncertain_commit_semantics_and_hides_details(self):
        with self.assertLogs('litegraph_memory_facade', 'ERROR') as log:
            result = await self.call({}, failure=TimeoutError('private-api-key and personal fact'))
        text = json.dumps(result) + str(log.output)
        self.assertNotIn('private-api-key', text)
        failure = result['result']['structuredContent']
        self.assertEqual(failure['retry_action'], 'retry_identical_once')
        self.assertEqual(failure['status'], 'unavailable')
        self.assertNotIn('stored', failure)  # outcome unknown, not proven absent

    async def test_unexpected_value_error_does_not_leak_input_or_secrets(self):
        with self.assertLogs('litegraph_memory_facade', 'WARNING') as log:
            response = await self.call({}, failure=ValueError('secret-personal-payload'))
        self.assertNotIn('secret-personal-payload', json.dumps(response) + str(log.output))
        self.assertEqual(response['result']['structuredContent']['error_code'], 'invalid_arguments')

    async def test_unknown_tool_remains_protocol_error_and_bad_arguments_are_actionable(self):
        response = await self.call({}, name='delete_everything')
        self.assertEqual(response['error']['message'], 'tool_not_found')
        for arguments in (None, [], 'not an object'):
            response = await self.call(arguments)
            self.assertEqual(response['result']['structuredContent']['status'], 'rejected')

    async def test_date_rejection_then_corrected_anniversary_saves_without_partial_write(self):
        backend = FakeGraph()
        args = bundle()
        args['entities'] = [{'key': 'couple', 'family': 'event', 'name': 'Example relationship anniversary'}]
        args['facts'] = [{'key': 'date', 'subject': 'couple', 'predicate': 'anniversary_date',
                          'value': 'May 4', 'valid_from': '05-04', 'content': 'The anniversary is May 4.',
                          'evidence': 'Our anniversary is May 4.', 'confidence': 1}]
        response = await self.call(args, backend=backend)
        failure = response['result']['structuredContent']
        self.assertEqual(failure['error_code'], 'invalid_timezone_aware_timestamp')
        self.assertEqual(backend.nodes, {})
        del args['facts'][0]['valid_from']
        args['idempotency_key'] = 'corrected-date'
        response = await self.call(args, backend=backend)
        self.assertFalse(response['result']['isError'])
        self.assertEqual(response['result']['structuredContent']['status'], 'saved')

    async def test_employment_requires_entity_link_and_recovers(self):
        backend = FakeGraph()
        args = bundle()
        args['entities'] = [{'key': 'person', 'family': 'person', 'name': 'Example Person'}]
        args['facts'] = [{'key': 'job', 'subject': 'person', 'predicate': 'works_at', 'value': 'Example Company',
                          'content': 'Example Person works at Example Company.',
                          'evidence': 'Example Person works at Example Company.', 'confidence': 1}]
        response = await self.call(args, backend=backend)
        self.assertEqual(response['result']['structuredContent']['error_code'], 'predicate_requires_entity_object')
        self.assertFalse(backend.nodes)
        args['entities'].append({'key': 'company', 'family': 'organization', 'name': 'Example Company'})
        args['facts'][0].pop('value')
        args['facts'][0]['object'] = 'company'
        args['idempotency_key'] = 'corrected-job'
        response = await self.call(args, backend=backend)
        self.assertEqual(response['result']['structuredContent']['status'], 'saved')

    async def test_endpoint_errors_identify_safe_field_and_never_partially_write(self):
        cases = [({'subject': 'private-person-name'}, (), 'unknown_fact_subject', 'subject'),
                 ({'object': 'missing_person'}, ('value',), 'unknown_fact_object', 'object'),
                 ({'object': 'person'}, (), 'fact_target_conflict', 'target'),
                 ({'object': None}, (), 'fact_target_conflict', 'target'),
                 ({}, ('value',), 'fact_target_missing', 'target')]
        for changes, remove, code, field in cases:
            with self.subTest(code=code, changes=changes):
                backend = FakeGraph()
                args = bundle()
                args['entities'] = [{'key': 'person', 'family': 'person', 'name': 'Example Person'}]
                args['facts'] = [dict(key='date', subject='person', predicate='anniversary_date',
                                     value='May 4', content='Example anniversary May 4.',
                                     evidence='Our anniversary is May 4.', confidence=1)]
                args['facts'][0].update(changes)
                for key in remove:
                    args['facts'][0].pop(key)
                with self.assertLogs('litegraph_memory_facade', 'WARNING') as log:
                    response = await self.call(args, backend=backend)
                failure = response['result']['structuredContent']
                self.assertEqual(failure['error_code'], code)
                self.assertEqual(failure['field_path'], 'facts[0].' + field)
                self.assertEqual(failure['retry_action'], 'correct_arguments')
                self.assertFalse(backend.nodes)
                self.assertNotIn('private-person-name', json.dumps(response) + str(log.output))

    async def test_relationship_and_anniversary_as_separate_facts_save_once(self):
        backend = FakeGraph()
        args = bundle()
        args['entities'] = [{'key': 'person_a', 'family': 'person', 'name': 'Example A'},
                            {'key': 'person_b', 'family': 'person', 'name': 'Example B'}]
        args['facts'] = [dict(key='relationship', subject='person_a', predicate='partner_of',
                              object='person_b', content='Example A and B are partners.',
                              evidence='We are partners.', confidence=1),
                         dict(key='date', subject='person_a', predicate='anniversary_date',
                              value='May 4', content='Example A and B celebrate their relationship anniversary May 4.',
                              evidence='Our anniversary is May 4.', confidence=1)]
        first = (await self.call(args, backend=backend))['result']['structuredContent']
        self.assertEqual(first['status'], 'saved')
        node_count = len(backend.nodes)
        second = (await self.call(args, backend=backend))['result']['structuredContent']
        self.assertEqual(first['receipt_id'], second['receipt_id'])
        self.assertTrue(second['duplicate'])
        self.assertEqual(first['entities'], second['entities'])
        self.assertEqual(node_count, len(backend.nodes))

    async def test_trip_description_and_reporting_relationship_are_supported(self):
        backend = FakeGraph()
        args = bundle()
        args['entities'] = [{'key': 'person', 'family': 'person', 'name': 'Example Person'},
                            {'key': 'boss', 'family': 'person', 'name': 'Example Boss'},
                            {'key': 'trip', 'family': 'event', 'name': 'Example Colombia Trip'},
                            {'key': 'country', 'family': 'place', 'name': 'Colombia'}]
        args['facts'] = [dict(key=key, subject=subject, predicate=predicate, object=obj,
                              content=words, evidence=words, confidence=1) for key, subject, predicate, obj, words in (
            ('boss', 'person', 'reports_to', 'boss', 'Example Person reports to Example Boss.'),
            ('trip', 'person', 'participates_in', 'trip', 'Example Person is taking the Colombia trip.'),
            ('place', 'trip', 'destination', 'country', 'The trip is to Colombia.'))]
        result = (await self.call(args, backend=backend))['result']['structuredContent']
        self.assertEqual(result['status'], 'saved')
        context = await GraphMemory(self.settings, backend).context(result['entities']['person']['id'])
        self.assertEqual(len(context['facts']), 2)
        for code in ('family_requires_authoritative_writer', 'graph_record_outside_authorized_scope'):
            self.assertEqual(validation_failure(ValueError(code))['retry_action'], 'stop')
