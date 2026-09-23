-- Scope returning caller resolution to the configured workspace.
DROP FUNCTION public.resume_onboarding_by_verified_identifier(text, text, text, text);
-- Resolve a returning caller through a previously verified identifier and
-- attach the new channel interaction to the durable onboarding thread.

CREATE OR REPLACE FUNCTION public.resume_onboarding_by_verified_identifier(
  p_identifier_type text,
  p_identifier text,
  p_external_session_ref text,
  p_channel text DEFAULT 'phone',
  p_workspace_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_identifier text;
  v_match_count integer;
  v_actor public.trust_actors%ROWTYPE;
  v_user public.application_users%ROWTYPE;
  v_session public.onboarding_sessions%ROWTYPE;
  v_trust_session_id uuid;
BEGIN
  IF p_workspace_id IS NULL OR p_identifier_type IS NULL OR p_identifier IS NULL
     OR p_channel IS NULL OR p_identifier_type NOT IN ('phone', 'email')
     OR p_channel NOT IN ('phone', 'sms', 'email', 'web')
     OR p_external_session_ref IS NULL
     OR btrim(p_external_session_ref) = ''
     OR length(p_external_session_ref) > 200 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid resume request';
  END IF;

  v_identifier := CASE
    WHEN p_identifier_type = 'email' THEN lower(btrim(p_identifier))
    ELSE btrim(p_identifier)
  END;

  IF (p_identifier_type = 'phone' AND v_identifier !~ '^\+[1-9][0-9]{7,14}$')
     OR (p_identifier_type = 'email' AND (v_identifier NOT LIKE '%@%' OR v_identifier <> lower(v_identifier))) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid identifier';
  END IF;

  SELECT count(*)::integer INTO v_match_count
    FROM public.trust_actor_identifiers identifier
   WHERE identifier.workspace_id = p_workspace_id
     AND identifier.identifier_type = p_identifier_type
     AND identifier.normalized_value = v_identifier
     AND identifier.verification_status = 'verified'
     AND identifier.valid_from <= now()
     AND (identifier.valid_until IS NULL OR identifier.valid_until > now());

  IF v_match_count = 0 THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;
  IF v_match_count > 1 THEN
    RETURN jsonb_build_object('status', 'unavailable', 'reason_code', 'identifier_ambiguous');
  END IF;

  SELECT actor.* INTO v_actor
    FROM public.trust_actor_identifiers identifier
    JOIN public.trust_actors actor ON actor.id = identifier.actor_id
   WHERE identifier.workspace_id = p_workspace_id
     AND identifier.identifier_type = p_identifier_type
     AND identifier.normalized_value = v_identifier
     AND identifier.verification_status = 'verified'
     AND identifier.valid_from <= now()
     AND (identifier.valid_until IS NULL OR identifier.valid_until > now())
   LIMIT 1;

  SELECT * INTO v_user
    FROM public.application_users
   WHERE id = v_actor.application_user_id;

  IF v_actor.status <> 'active'
     OR v_user.id IS NULL
     OR v_user.status NOT IN ('onboarding', 'active') THEN
    RETURN jsonb_build_object('status', 'unavailable', 'reason_code', 'actor_inactive');
  END IF;

  SELECT * INTO v_session
    FROM public.onboarding_sessions
   WHERE user_id = v_user.id
     AND workspace_id = v_actor.workspace_id
   ORDER BY
     CASE WHEN status IN ('in_progress', 'paused', 'minimum_complete') THEN 0 ELSE 1 END,
     last_activity_at DESC,
     started_at DESC
   LIMIT 1;

  INSERT INTO public.trust_sessions (
    workspace_id, external_session_ref, authenticated_actor_id,
    auth_assurance, identity_confidence, present_actor_refs,
    unknown_speaker_count, evidence, expires_at
  ) VALUES (
    v_actor.workspace_id, btrim(p_external_session_ref), v_actor.id,
    2, 0.8500, ARRAY[v_actor.actor_ref], 0,
    jsonb_build_object(
      'method', 'verified_identifier',
      'identifier_type', p_identifier_type,
      'channel', p_channel
    ),
    now() + interval '12 hours'
  )
  ON CONFLICT (workspace_id, external_session_ref) DO UPDATE
    SET authenticated_actor_id = EXCLUDED.authenticated_actor_id,
        auth_assurance = EXCLUDED.auth_assurance,
        identity_confidence = EXCLUDED.identity_confidence,
        present_actor_refs = EXCLUDED.present_actor_refs,
        unknown_speaker_count = 0,
        evidence = EXCLUDED.evidence,
        expires_at = EXCLUDED.expires_at,
        updated_at = now()
  RETURNING id INTO v_trust_session_id;

  IF v_session.id IS NOT NULL THEN
    INSERT INTO public.thread_interactions (
      thread_id, channel, direction, actor_ref, external_id, content
    ) VALUES (
      v_session.thread_id, p_channel, 'inbound', v_actor.actor_ref,
      btrim(p_external_session_ref),
      jsonb_build_object(
        'interaction_type', 'onboarding.resumed',
        'onboarding_session_id', v_session.id,
        'verification_method', 'verified_identifier'
      )
    ) ON CONFLICT (thread_id, channel, external_id) DO NOTHING;

    UPDATE public.onboarding_sessions
       SET last_channel = p_channel,
           last_external_session_ref = btrim(p_external_session_ref),
           last_activity_at = now()
     WHERE id = v_session.id;
  END IF;

  RETURN jsonb_build_object(
    'status', 'recognized',
    'user_id', v_user.id,
    'display_name', v_user.display_name,
    'actor_ref', v_actor.actor_ref,
    'workspace_id', v_actor.workspace_id,
    'trust_session_id', v_trust_session_id,
    'onboarding_session_id', v_session.id,
    'thread_id', v_session.thread_id,
    'onboarding_state', COALESCE(v_session.status, v_user.onboarding_status),
    'current_topic', v_session.current_topic,
    'completed_topics', COALESCE(to_jsonb(v_session.completed_topics), '[]'::jsonb),
    'checkpoint', COALESCE(v_session.checkpoint, '{}'::jsonb),
    'completion_percentage', COALESCE(v_session.completion_percentage, 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.resume_onboarding_by_verified_identifier(text, text, text, text, uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resume_onboarding_by_verified_identifier(text, text, text, text, uuid)
TO service_role;

