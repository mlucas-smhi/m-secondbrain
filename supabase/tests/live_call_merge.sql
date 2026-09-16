BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;

SELECT plan(11);

SELECT lives_ok($$
  SELECT public.record_live_call_status(
    '00000000-0000-4000-8000-000000000001',
    'CA-merge-owner:0', 'CA-merge-owner', 'in-progress', 'inbound', now(), 0
  )
$$, 'requesting call can be registered');

SELECT lives_ok($$
  SELECT public.record_live_call_status(
    '00000000-0000-4000-8000-000000000001',
    'CA-merge-target:0', 'CA-merge-target', 'in-progress', 'inbound', now(), 0
  )
$$, 'target call can be registered');

SELECT lives_ok($$
  SELECT public.propose_live_call_merge(
    '00000000-0000-4000-8000-000000000001',
    'CA-merge-owner',
    (SELECT id FROM public.live_call_sessions WHERE provider_call_ref = 'CA-merge-target'),
    'merge-test-1', 'Synthetic caller is waiting', 90
  )
$$, 'a live pair can receive a merge offer');

SELECT is(
  (SELECT status FROM public.live_call_merge_requests WHERE idempotency_key = 'merge-test-1'),
  'offered', 'a proposal is not approval'
);

SELECT lives_ok($$
  SELECT public.propose_live_call_merge(
    '00000000-0000-4000-8000-000000000001',
    'CA-merge-owner',
    (SELECT id FROM public.live_call_sessions WHERE provider_call_ref = 'CA-merge-target'),
    'merge-test-1', 'Synthetic caller is waiting', 90
  )
$$, 'proposal replay is idempotent');

SELECT is(
  (SELECT count(*)::integer FROM public.live_call_merge_requests WHERE idempotency_key = 'merge-test-1'),
  1, 'proposal replay creates no duplicate'
);

SELECT throws_ok($$
  SELECT public.answer_live_call_merge(
    '00000000-0000-4000-8000-000000000001',
    (SELECT id FROM public.live_call_merge_requests WHERE idempotency_key = 'merge-test-1'),
    'CA-merge-target', true, 'person:m', '{}'::jsonb
  )
$$, 'PT409', 'answer is not bound to the requesting call',
  'a different call cannot approve the merge');

SELECT lives_ok($$
  SELECT public.answer_live_call_merge(
    '00000000-0000-4000-8000-000000000001',
    (SELECT id FROM public.live_call_merge_requests WHERE idempotency_key = 'merge-test-1'),
    'CA-merge-owner', true, 'person:m', '{"source":"synthetic-test"}'::jsonb
  )
$$, 'the requesting call can explicitly approve');

SELECT results_eq(
  $$ SELECT status, answered_by_actor_ref
       FROM public.live_call_merge_requests WHERE idempotency_key = 'merge-test-1' $$,
  $$ VALUES ('approved'::text, 'person:m'::text) $$,
  'approval and actor are durable'
);

SELECT lives_ok($$
  SELECT public.answer_live_call_merge(
    '00000000-0000-4000-8000-000000000001',
    (SELECT id FROM public.live_call_merge_requests WHERE idempotency_key = 'merge-test-1'),
    'CA-merge-owner', false, 'person:m', '{}'::jsonb
  )
$$, 'answer replay is idempotent');

SELECT is(
  (SELECT status FROM public.live_call_merge_requests WHERE idempotency_key = 'merge-test-1'),
  'approved', 'a replay cannot reverse an approval'
);

SELECT * FROM finish();
ROLLBACK;
