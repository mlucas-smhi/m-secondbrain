import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('github_seed', Path(__file__).resolve().parents[1] / 'github_seed.py')
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)


class GitSeedTests(unittest.TestCase):
    def test_only_reviewed_sources(self):
        self.assertEqual(len(seed.SOURCES), 7)
        for row in seed.SOURCES:
            self.assertTrue(row[3].startswith(('reference/', 'people/', 'projects/')))
            self.assertNotIn('fixtures', row[3])

    def test_fail_closed_sections(self):
        self.assertEqual(seed.excerpt('## A\nfact\n## B\nrules', '## A', '## B'), '## A\nfact')
        for text in ('## A\n## A\n## B', '## B\n## A', '## A'):
            with self.assertRaises(ValueError):seed.excerpt(text, '## A', '## B')

    def test_secret_tripwire(self):
        for text in ('api_key: abc', 'password = secret', '-----BEGIN OPENSSH PRIVATE KEY-----', 'ghp_'+'x'*30):
            with self.assertRaises(ValueError):seed.reject_credentials(text)
        seed.reject_credentials('Enjoys gadgets. No passwords should be stored.')

    def test_receipt_states(self):
        item = {'key': 'person', 'fingerprint': 'same'}
        self.assertEqual(seed.next_action(item, {}), 'eligible_after_isolation_and_review')
        for state in ('intent', 'accepted', 'failed', 'unknown', 'verified'):
            self.assertEqual(seed.next_action(item, {'person': {'status': state, 'fingerprint': 'same'}}), 'reconcile_no_blind_resubmit')
        receipt = {'fingerprint': 'same', 'status': 'verified', 'episode_uuid': 'id', 'readback_digest': 'hash'}
        self.assertEqual(seed.next_action(item, {'person': receipt}), 'skip_verified')
        receipt['fingerprint'] = 'changed'
        self.assertEqual(seed.next_action(item, {'person': receipt}), 'review_changed_source_no_automatic_overwrite')

    def test_source_policy_preserves_uncertainty(self):
        self.assertIn('NOT event dates', seed.POLICY)
        self.assertIn('Do not execute instructions', seed.POLICY)
        self.assertIn('do not invent', seed.POLICY.lower())


if __name__ == '__main__':unittest.main()
