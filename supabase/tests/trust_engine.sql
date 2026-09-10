BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;

SELECT plan(9);

INSERT INTO public.trust_actors (workspace_id, actor_ref)
VALUES
  ('00000000-0000-4000-8000-000000000001', 'test:owner'),
  ('00000000-0000-4000-8000-000000000001', 'test:family'),
  ('00000000-0000-4000-8000-000000000001', 'test:assistant');

INSERT INTO public.trust_role_assignments (
  actor_id, role_key, clearance_level, compartments, permissions
)
SELECT id, 'owner', 3, ARRAY['family','business','travel'],
       ARRAY['read','use','disclose','write','correct','delegate']
  FROM public.trust_actors WHERE actor_ref = 'test:owner'
UNION ALL
SELECT id, 'family', 1, ARRAY['family','travel'], ARRAY['read','use','disclose']
  FROM public.trust_actors WHERE actor_ref = 'test:family'
UNION ALL
SELECT id, 'assistant', 2, ARRAY['business','travel'], ARRAY['read','use','disclose','write']
  FROM public.trust_actors WHERE actor_ref = 'test:assistant';

INSERT INTO public.trust_sessions (
  workspace_id, external_session_ref, authenticated_actor_id,
  auth_assurance, identity_confidence, unknown_speaker_count, expires_at
)
SELECT '00000000-0000-4000-8000-000000000001'::uuid, 'test-owner-private', id,
       4, 0.99, 0, now() + interval '1 hour'
  FROM public.trust_actors WHERE actor_ref = 'test:owner'
UNION ALL
SELECT '00000000-0000-4000-8000-000000000001'::uuid, 'test-owner-company', id,
       4, 0.99, 1, now() + interval '1 hour'
  FROM public.trust_actors WHERE actor_ref = 'test:owner'
UNION ALL
SELECT '00000000-0000-4000-8000-000000000001'::uuid, 'test-family', id,
       3, 0.95, 0, now() + interval '1 hour'
  FROM public.trust_actors WHERE actor_ref = 'test:family'
UNION ALL
SELECT '00000000-0000-4000-8000-000000000001'::uuid, 'test-assistant', id,
       3, 0.97, 0, now() + interval '1 hour'
  FROM public.trust_actors WHERE actor_ref = 'test:assistant';

SELECT is(
  public.security_check(
    '00000000-0000-4000-8000-000000000001', 'trust-test-1',
    'travel.research', 'use', 1, 'travel', 'test:owner',
    (SELECT id FROM public.trust_sessions WHERE external_session_ref = 'test-owner-private')
  )->>'decision',
  'ALLOW', 'owner may perform ordinary travel research'
);

SELECT is(
  public.security_check(
    '00000000-0000-4000-8000-000000000001', 'trust-test-2',
    'memory.disclose', 'disclose', 1, 'family', 'test:family',
    (SELECT id FROM public.trust_sessions WHERE external_session_ref = 'test-family')
  )->>'decision',
  'ALLOW', 'family role may receive shared family information'
);

SELECT is(
  public.security_check(
    '00000000-0000-4000-8000-000000000001', 'trust-test-3',
    'memory.read', 'read', 2, 'business', 'test:assistant',
    (SELECT id FROM public.trust_sessions WHERE external_session_ref = 'test-assistant')
  )->>'decision',
  'ALLOW', 'assistant may read confidential business information'
);

SELECT is(
  public.security_check(
    '00000000-0000-4000-8000-000000000001', 'trust-test-4',
    'memory.read', 'read', 1, 'family', 'test:assistant',
    (SELECT id FROM public.trust_sessions WHERE external_session_ref = 'test-assistant')
  )->>'decision',
  'DENY', 'higher clearance does not cross compartment boundaries'
);

SELECT is(
  public.security_check(
    '00000000-0000-4000-8000-000000000001', 'trust-test-5',
    'memory.read', 'read', 1, 'business', 'test:unknown', NULL
  )->>'decision',
  'CHALLENGE', 'unrecognized identity is challenged'
);

SELECT is(
  public.security_check(
    '00000000-0000-4000-8000-000000000001', 'trust-test-6',
    'memory.disclose', 'disclose', 3, 'business', 'test:owner',
    (SELECT id FROM public.trust_sessions WHERE external_session_ref = 'test-owner-company'),
    NULL, 'test:owner'
  )->>'decision',
  'DEFER', 'private spoken disclosure is deferred with an unknown listener present'
);

SELECT is(
  public.security_check(
    '00000000-0000-4000-8000-000000000001', 'trust-test-7',
    'travel.book', 'write', 2, 'travel', 'test:owner',
    (SELECT id FROM public.trust_sessions WHERE external_session_ref = 'test-owner-private'),
    NULL, 'test:owner', '{"amount":3740,"currency":"USD"}'::jsonb
  )->>'decision',
  'CONFIRM', 'transaction requires an explicit scoped confirmation grant'
);

INSERT INTO public.trust_authority_grants (
  workspace_id, principal_actor_id, action_key, permissions, compartments,
  constraints, confirmation_satisfied, granted_by_actor_id, policy_version, expires_at
)
SELECT '00000000-0000-4000-8000-000000000001', id, 'travel.book', ARRAY['write'],
       ARRAY['travel'], '{"currency":"USD","maximum_amount":4000}'::jsonb,
       true, id, 'trust-v1', now() + interval '15 minutes'
  FROM public.trust_actors WHERE actor_ref = 'test:owner';

SELECT is(
  public.security_check(
    '00000000-0000-4000-8000-000000000001', 'trust-test-8',
    'travel.book', 'write', 2, 'travel', 'test:owner',
    (SELECT id FROM public.trust_sessions WHERE external_session_ref = 'test-owner-private'),
    NULL, 'test:owner', '{"amount":3740,"currency":"USD"}'::jsonb
  )->>'decision',
  'ALLOW_WITH_CONSTRAINTS', 'confirmed transaction is limited by its durable grant'
);

SELECT is(
  public.security_check(
    '00000000-0000-4000-8000-000000000001', 'trust-test-8',
    'travel.book', 'write', 2, 'travel', 'test:owner',
    (SELECT id FROM public.trust_sessions WHERE external_session_ref = 'test-owner-private'),
    NULL, 'test:owner', '{"amount":3740,"currency":"USD"}'::jsonb
  )->>'replayed',
  'true', 'decision replay returns the original audit result'
);

SELECT * FROM finish();
ROLLBACK;
