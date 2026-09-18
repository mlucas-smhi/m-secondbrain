BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;

SELECT plan(18);

SELECT has_table('public', 'application_users', 'application users table exists');
SELECT has_table('public', 'onboarding_invites', 'onboarding invites table exists');
SELECT has_table('public', 'trust_actor_identifiers', 'actor identifiers table exists');
SELECT has_table('public', 'onboarding_sessions', 'onboarding sessions table exists');
SELECT has_function('public', 'verify_and_provision_onboarding', ARRAY['uuid','text','text','text','text','text','text','text'], 'atomic onboarding function exists');

INSERT INTO public.onboarding_invites (
  id, code_digest, invite_type, delivery_channel, intended_identifier_type,
  intended_identifier, max_attempts, expires_at
) VALUES (
  '10000000-0000-4000-8000-000000000001', repeat('a', 64),
  'preview_invite', 'sms', 'phone', '+18323886696', 2, now() + interval '1 hour'
);

SELECT is(
  public.verify_and_provision_onboarding(
    '10000000-0000-4000-8000-000000000001', 'onboarding-test-bad-1', repeat('b', 64),
    'phone', '+18323886696', 'call-test-bad-1', 'phone', 'litegraph'
  )->>'status',
  'retry', 'first incorrect code may be retried'
);

SELECT is(
  (SELECT attempt_count FROM public.onboarding_invites WHERE id = '10000000-0000-4000-8000-000000000001'),
  1, 'incorrect code increments the attempt count'
);

SELECT is(
  public.verify_and_provision_onboarding(
    '10000000-0000-4000-8000-000000000001', 'onboarding-test-bad-2', repeat('b', 64),
    'phone', '+18323886696', 'call-test-bad-2', 'phone', 'litegraph'
  )->>'status',
  'locked', 'final incorrect attempt locks the invite'
);

INSERT INTO public.onboarding_invites (
  id, code_digest, invite_type, delivery_channel, intended_identifier_type,
  intended_identifier, expires_at
) VALUES (
  '10000000-0000-4000-8000-000000000002', repeat('c', 64),
  'preview_invite', 'sms', 'phone', '+18323886696', now() + interval '1 hour'
);

CREATE TEMP TABLE onboarding_result AS
SELECT public.verify_and_provision_onboarding(
  '10000000-0000-4000-8000-000000000002', 'onboarding-test-good', repeat('c', 64),
  'phone', '+18323886696', 'call-test-good', 'phone', 'litegraph'
) AS body;

SELECT is((SELECT body->>'status' FROM onboarding_result), 'confirmed', 'valid code confirms onboarding');
SELECT is((SELECT status FROM public.onboarding_invites WHERE id = '10000000-0000-4000-8000-000000000002'), 'consumed', 'confirmed invite is consumed');
SELECT is((SELECT count(*)::integer FROM public.application_users WHERE created_from_invite_id = '10000000-0000-4000-8000-000000000002'), 1, 'one permanent user is created');
SELECT is((SELECT count(*)::integer FROM public.trust_actor_identifiers WHERE normalized_value = '+18323886696' AND verification_status = 'verified'), 1, 'phone is bound as a verified actor identifier');
SELECT is((SELECT count(*)::integer FROM public.trust_role_assignments assignment JOIN public.trust_actors actor ON actor.id = assignment.actor_id WHERE actor.application_user_id = (SELECT (body->>'user_id')::uuid FROM onboarding_result) AND assignment.role_key = 'owner' AND assignment.clearance_level = 3), 1, 'workspace owner authority is provisioned');
SELECT is((SELECT count(*)::integer FROM public.onboarding_sessions WHERE user_id = (SELECT (body->>'user_id')::uuid FROM onboarding_result) AND status = 'in_progress'), 1, 'resumable onboarding session is created');
SELECT is((SELECT count(*)::integer FROM public.workspace_memory_stores WHERE workspace_id = (SELECT (body->>'workspace_id')::uuid FROM onboarding_result) AND provider = 'litegraph'), 1, 'workspace memory namespace is reserved');

SELECT is(
  public.verify_and_provision_onboarding(
    '10000000-0000-4000-8000-000000000002', 'onboarding-test-good', repeat('c', 64),
    'phone', '+18323886696', 'call-test-good', 'phone', 'litegraph'
  )->>'replayed',
  'true', 'same request replays without provisioning another user'
);

SELECT is((SELECT count(*)::integer FROM public.application_users WHERE created_from_invite_id = '10000000-0000-4000-8000-000000000002'), 1, 'replay remains single-provisioned');

SELECT throws_ok(
  $$INSERT INTO public.trust_actor_identifiers (
      workspace_id, actor_id, identifier_type, normalized_value,
      verification_status, verified_at, verification_method
    )
    SELECT workspace_id, id, 'phone', '+18323886696', 'verified', now(), 'invite_code'
      FROM public.trust_actors
     WHERE application_user_id = (SELECT (body->>'user_id')::uuid FROM onboarding_result)$$,
  '23505', NULL,
  'one active phone identifier cannot be assigned twice within a workspace'
);

SELECT * FROM finish();
ROLLBACK;
