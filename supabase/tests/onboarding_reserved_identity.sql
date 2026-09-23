BEGIN;

DO $test$
DECLARE
  invite uuid := gen_random_uuid();
  reserved_user uuid := gen_random_uuid();
  reserved_workspace uuid := gen_random_uuid();
  result jsonb;
BEGIN
  INSERT INTO public.onboarding_invites (
    id, code_digest, invite_type, delivery_channel, intended_identifier_type,
    intended_identifier, expires_at, provision_user_id, provision_workspace_id
  ) VALUES (invite, repeat('a',64), 'preview_invite', 'manual', 'phone',
    '+15550008881', now()+interval '1 hour', reserved_user, reserved_workspace);

  result := public.verify_and_provision_onboarding(invite, 'reserved-test-wrong', repeat('b',64),
    'phone', '+15550008881', 'reserved-test-wrong-call', 'phone', 'litegraph');
  ASSERT result->>'status' = 'retry', 'Wrong code must not confirm';
  ASSERT NOT EXISTS (SELECT 1 FROM public.application_users WHERE id=reserved_user), 'Reservation cannot create a user';
  ASSERT NOT EXISTS (SELECT 1 FROM public.workspaces WHERE id=reserved_workspace), 'Reservation cannot create a workspace';
  ASSERT public.resume_onboarding_by_verified_identifier('phone', '+15550008881',
    'reserved-test-before', 'phone', reserved_workspace)->>'status' = 'not_found', 'Reservation cannot resume';

  result := public.verify_and_provision_onboarding(invite, 'reserved-test-good', repeat('a',64),
    'phone', '+15550008881', 'reserved-test-good-call', 'phone', 'litegraph');
  ASSERT result->>'status' = 'confirmed', 'Correct code must confirm';
  ASSERT (result->>'user_id')::uuid=reserved_user, 'User must match reserved memory owner';
  ASSERT (result->>'workspace_id')::uuid=reserved_workspace, 'Workspace must match reserved graph';
  ASSERT result->>'thread_id' IS NOT NULL, 'Fresh onboarding needs a thread';
  ASSERT (SELECT current_topic=1 AND completed_topics='{}'::integer[] AND checkpoint='{}'::jsonb
    AND completion_percentage=0 FROM public.onboarding_sessions WHERE id=(result->>'onboarding_session_id')::uuid), 'Onboarding must begin clean';
  ASSERT public.verify_and_provision_onboarding(invite, 'reserved-test-reuse', repeat('a',64),
    'phone', '+15550008881', 'reserved-test-reuse-call', 'phone', 'litegraph')->>'status' = 'retry', 'Consumed code cannot be reused';
  ASSERT public.resume_onboarding_by_verified_identifier('phone', '+15550008881',
    'reserved-test-return', 'phone', reserved_workspace)->>'status' = 'recognized', 'Validated identity can resume';
  ASSERT NOT has_table_privilege('anon', 'public.onboarding_invites', 'UPDATE'), 'Anonymous callers cannot reserve identities';
  ASSERT NOT has_table_privilege('authenticated', 'public.onboarding_invites', 'UPDATE'), 'Clients cannot reserve identities';
END;
$test$;

SELECT 'PASS: reserved scope, verification gate, clean onboarding, single use, resume, permissions' AS result;
ROLLBACK;
