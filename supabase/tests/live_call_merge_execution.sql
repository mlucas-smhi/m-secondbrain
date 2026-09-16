BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;

SELECT plan(10);

SELECT lives_ok($$
  SELECT public.record_live_call_status(
    '00000000-0000-4000-8000-000000000001',
    'CA-exec-owner:0', 'CA-exec-owner', 'in-progress', 'inbound', now(), 0
  )
$$, 'requesting execution call can be registered');

SELECT lives_ok($$
  SELECT public.record_live_call_status(
    '00000000-0000-4000-8000-000000000001',
    'CA-exec-target:0', 'CA-exec-target', 'in-progress', 'inbound', now(), 0
  )
$$, 'target execution call can be registered');

SELECT lives_ok($$
  SELECT public.propose_live_call_merge(
    '00000000-0000-4000-8000-000000000001', 'CA-exec-owner',
    (SELECT id FROM public.live_call_sessions WHERE provider_call_ref = 'CA-exec-target'),
    'merge-execution-test', 'Synthetic execution test', 90
  )
$$, 'execution merge can be proposed');

SELECT throws_ok($$
  SELECT public.claim_live_call_merge_execution(
    '00000000-0000-4000-8000-000000000001',
    (SELECT id FROM public.live_call_merge_requests WHERE idempotency_key = 'merge-execution-test'),
    'CA-exec-owner'
  )
$$, 'PT409', 'merge request is not approved',
  'an unapproved merge cannot execute');

SELECT lives_ok($$
  SELECT public.answer_live_call_merge(
    '00000000-0000-4000-8000-000000000001',
    (SELECT id FROM public.live_call_merge_requests WHERE idempotency_key = 'merge-execution-test'),
    'CA-exec-owner', true, 'person:m', '{"source":"synthetic-test"}'::jsonb
  )
$$, 'the merge can be approved');

SELECT throws_ok($$
  SELECT public.claim_live_call_merge_execution(
    '00000000-0000-4000-8000-000000000001',
    (SELECT id FROM public.live_call_merge_requests WHERE idempotency_key = 'merge-execution-test'),
    'CA-exec-target'
  )
$$, 'PT409', 'execution is not bound to the requesting call',
  'the wrong call cannot claim execution');

SELECT lives_ok($$
  SELECT public.claim_live_call_merge_execution(
    '00000000-0000-4000-8000-000000000001',
    (SELECT id FROM public.live_call_merge_requests WHERE idempotency_key = 'merge-execution-test'),
    'CA-exec-owner'
  )
$$, 'the approved requesting call can claim execution');

SELECT results_eq(
  $$ SELECT status, room_ref IS NOT NULL
       FROM public.live_call_merge_requests WHERE idempotency_key = 'merge-execution-test' $$,
  $$ VALUES ('executing'::text, true) $$,
  'claiming creates a durable non-PII room'
);

SELECT lives_ok($$
  SELECT public.complete_live_call_merge_execution(
    '00000000-0000-4000-8000-000000000001',
    (SELECT id FROM public.live_call_merge_requests WHERE idempotency_key = 'merge-execution-test'),
    true, 'CA-exec-agent', NULL, '{"provider":"twilio"}'::jsonb
  )
$$, 'successful provider execution can be completed');

SELECT results_eq(
  $$ SELECT status, agent_provider_call_ref, execution_evidence->>'provider'
       FROM public.live_call_merge_requests WHERE idempotency_key = 'merge-execution-test' $$,
  $$ VALUES ('joined'::text, 'CA-exec-agent'::text, 'twilio'::text) $$,
  'joined state and provider evidence are durable'
);

SELECT * FROM finish();
ROLLBACK;
