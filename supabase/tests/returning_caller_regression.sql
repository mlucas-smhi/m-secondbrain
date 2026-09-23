BEGIN;
DO $test$
DECLARE
  invite_a uuid := gen_random_uuid();
  invite_b uuid := gen_random_uuid();
  first_user jsonb;
  second_user jsonb;
  resumed jsonb;
BEGIN
  PERFORM public.create_onboarding_invite(repeat('d',64), 'preview_invite',
    'manual','phone','+15559998765',now()+interval '1 hour',5,NULL,NULL,invite_a);
  PERFORM public.create_onboarding_invite(repeat('e',64), 'preview_invite',
    'manual','phone','+15559998765',now()+interval '1 hour',5,NULL,NULL,invite_b);
  first_user := public.verify_and_provision_onboarding(invite_a,'test-first',
    repeat('d',64),'phone','+15559998765','test-first','phone','litegraph');
  second_user := public.verify_and_provision_onboarding(invite_b,'test-second',
    repeat('e',64),'phone','+15559998765','test-second','phone','litegraph');
  resumed := public.resume_onboarding_by_verified_identifier('phone',
    '+15559998765','test-return','phone',(second_user->>'workspace_id')::uuid);
  IF resumed->>'status' <> 'recognized'
     OR resumed->>'actor_ref' IS DISTINCT FROM second_user->>'actor_ref'
     OR resumed->>'thread_id' IS DISTINCT FROM second_user->>'thread_id' THEN
    RAISE EXCEPTION 'workspace-scoped duplicate-number resolution failed';
  END IF;
  IF public.resume_onboarding_by_verified_identifier('phone',
    '+15559998765','test-unknown','phone',gen_random_uuid())->>'status' <> 'not_found' THEN
    RAISE EXCEPTION 'cross-workspace resolution leaked';
  END IF;
  UPDATE public.trust_actors SET status='suspended'
   WHERE actor_ref=second_user->>'actor_ref';
  IF public.resume_onboarding_by_verified_identifier('phone',
    '+15559998765','test-suspended','phone',(second_user->>'workspace_id')::uuid)->>'status' <> 'unavailable' THEN
    RAISE EXCEPTION 'suspended actor accepted';
  END IF;
END;
$test$;
SELECT 'returning caller regression passed; fixtures rolled back' AS result;
ROLLBACK;
