import copy
import io
import json
from pathlib import Path
import unittest
from urllib.error import HTTPError

from bridge.memory_baseline import build, SCHEMA, MAPPING_VERSION
from bridge.memory_import import apply_plan, verify_plan


class Store:
    def __init__(self, plan):
        self.plan = plan
        self.nodes, self.edges = {}, {}
        self.transactions = 0
        self.lose_reply = False

    def request(self, method, path, body=None):
        clean = path.split('?', 1)[0]
        if method == 'POST':
            self.transactions += 1
            self.assert_create_only(body)
            for op in body['Operations']:
                target = self.nodes if op['ObjectType'] == 'Node' else self.edges
                value = copy.deepcopy(op['Payload'])
                if value['GUID'] in target:
                    raise RuntimeError('duplicate')
                target[value['GUID']] = value
            if self.lose_reply:
                raise TimeoutError('committed but response lost')
            return {'Success': True, 'State': 'Committed', 'RolledBack': False}
        if '/nodes/' in clean:
            value = self.nodes.get(clean.rsplit('/', 1)[1])
            if value is None:
                raise HTTPError(path, 404, 'missing', {}, None)
            return copy.deepcopy(value)
        for kind, values in [('nodes', self.nodes), ('edges', self.edges)]:
            if clean.endswith('/' + kind):
                return {'TotalRecords': len(values), 'Objects': copy.deepcopy(list(values.values())), 'EndOfResults': True}
        s = self.plan['scope']
        return {'Data': {'memory_schema_version': SCHEMA, 'workspace_id': s['workspace'],
                         'owner_ref': s['owner'], 'import_version': MAPPING_VERSION}}

    @staticmethod
    def assert_create_only(body):
        assert all(op['OperationType'] == 'Create' for op in body['Operations'])


class ImportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan = build(Path(__file__).resolve().parents[3],
                         '11111111-1111-4111-8111-111111111111',
                         '22222222-2222-4222-8222-222222222222',
                         '33333333-3333-4333-8333-333333333333', 'user:test')

    def test_commit_full_readback_and_non_overwriting_retry(self):
        store = Store(self.plan)
        self.assertEqual(apply_plan(self.plan, store.request)['status'], 'imported')
        self.assertEqual(verify_plan(self.plan, store.request)['readback'], 'all_records_match')
        node = store.nodes[self.plan['nodes'][0]['GUID']]
        node['Data']['later_conversation'] = 'Must survive a rerun'
        self.assertEqual(apply_plan(self.plan, store.request)['status'], 'already_imported')
        self.assertEqual(store.transactions, 1)
        self.assertIn('later_conversation', node['Data'])

    def test_lost_response_resolved_by_receipt(self):
        store = Store(self.plan)
        store.lose_reply = True
        self.assertEqual(apply_plan(self.plan, store.request)['status'], 'imported')
        self.assertEqual(store.transactions, 1)

    def test_nonempty_graph_is_not_overwritten(self):
        store = Store(self.plan)
        store.nodes['unrelated'] = {'GUID': 'unrelated'}
        with self.assertRaisesRegex(ValueError, 'requires_empty_graph'):
            apply_plan(self.plan, store.request)
        self.assertEqual(store.transactions, 0)

    def test_changed_payload_and_wrong_scope_fail(self):
        store = Store(self.plan)
        bad = copy.deepcopy(self.plan)
        bad['nodes'][0]['Name'] = 'tampered'
        with self.assertRaisesRegex(ValueError, 'digest_mismatch'):
            apply_plan(bad, store.request)
        bad = copy.deepcopy(self.plan)
        bad['scope']['owner'] = 'another-owner'
        with self.assertRaisesRegex(ValueError, 'scope_mismatch'):
            apply_plan(bad, store.request)

    def test_missing_edge_fails_verification(self):
        store = Store(self.plan)
        apply_plan(self.plan, store.request)
        store.edges.pop(next(iter(store.edges)))
        with self.assertRaisesRegex(RuntimeError, 'readback_mismatch'):
            verify_plan(self.plan, store.request)

    def test_v9_missing_node_400_is_narrowly_recognized(self):
        store = Store(self.plan)

        def request(method, path, body=None):
            try:
                return store.request(method, path, body)
            except HTTPError as error:
                error.close()
                record_id = path.split('?', 1)[0].rsplit('/', 1)[1]
                payload = json.dumps({'Description': "No node with GUID '" + record_id + "' exists."}).encode()
                raise HTTPError(path, 400, 'missing', {}, io.BytesIO(payload)) from None

        self.assertEqual(apply_plan(self.plan, request)['status'], 'imported')

    def test_generic_bad_request_does_not_mean_missing(self):
        store = Store(self.plan)

        def request(method, path, body=None):
            if '/nodes/' in path:
                raise HTTPError(path, 400, 'invalid', {}, io.BytesIO(b'{"Description":"invalid request"}'))
            return store.request(method, path, body)

        with self.assertRaises(HTTPError):
            apply_plan(self.plan, request)
        self.assertEqual(store.transactions, 0)


if __name__ == '__main__':
    unittest.main()
