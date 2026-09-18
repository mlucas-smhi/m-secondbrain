-- Onboarding is the user's first durable thread. Channel activity belongs in
-- the shared thread interaction ledger so the same context can continue over
-- phone, SMS, email, web, and background task execution.

ALTER TABLE public.onboarding_sessions
  ADD COLUMN thread_id uuid REFERENCES public.threads(id) ON DELETE CASCADE;

DO $migration$
DECLARE
  v_session record;
  v_actor_ref text;
  v_thread_id uuid;
BEGIN
  FOR v_session IN
    SELECT id, user_id, workspace_id, current_topic
      FROM public.onboarding_sessions
     WHERE thread_id IS NULL
     ORDER BY started_at, id
  LOOP
    SELECT actor_ref INTO v_actor_ref
      FROM public.trust_actors
     WHERE application_user_id = v_session.user_id
       AND workspace_id = v_session.workspace_id
     ORDER BY created_at, id
     LIMIT 1;

    IF v_actor_ref IS NULL THEN
      RAISE EXCEPTION 'onboarding session % has no workspace trust actor', v_session.id;
    END IF;

    INSERT INTO public.threads (
      workspace_id, subject, desired_outcome, status, current_owner_ref, next_action
    ) VALUES (
      v_session.workspace_id,
      'Personal onboarding',
      'Build the durable context, preferences, relationships, and operating boundaries needed for an effective right-hand executive assistant.',
      'active',
      v_actor_ref,
      'Continue onboarding topic ' || COALESCE(v_session.current_topic, 1)::text
    ) RETURNING id INTO v_thread_id;

    INSERT INTO public.thread_participants (
      thread_id, actor_type, actor_ref, identity_confidence, roles
    ) VALUES (
      v_thread_id, 'person', v_actor_ref, 'verified',
      ARRAY['initiator', 'owner', 'approver']
    );

    UPDATE public.onboarding_sessions
       SET thread_id = v_thread_id
     WHERE id = v_session.id;
  END LOOP;
END;
$migration$;

INSERT INTO public.thread_interactions (
  id, thread_id, channel, direction, actor_ref, external_id, content,
  occurred_at, created_at
)
SELECT
  interaction.id,
  session.thread_id,
  interaction.channel,
  'inbound',
  thread.current_owner_ref,
  interaction.external_session_ref,
  jsonb_build_object(
    'interaction_type', 'onboarding.started',
    'onboarding_session_id', interaction.onboarding_session_id,
    'topics_advanced', to_jsonb(interaction.topics_advanced),
    'ended_at', interaction.ended_at,
    'verification_method', 'invite_code'
  ),
  interaction.started_at,
  interaction.started_at
FROM public.onboarding_interactions interaction
JOIN public.onboarding_sessions session
  ON session.id = interaction.onboarding_session_id
JOIN public.threads thread
  ON thread.id = session.thread_id
ON CONFLICT (thread_id, channel, external_id) DO NOTHING;

DROP TABLE public.onboarding_interactions;

ALTER TABLE public.onboarding_sessions ALTER COLUMN thread_id SET NOT NULL;
ALTER TABLE public.onboarding_sessions
  ADD CONSTRAINT onboarding_sessions_thread_id_key UNIQUE (thread_id);

CREATE OR REPLACE FUNCTION public.ensure_onboarding_thread()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor_ref text;
BEGIN
  IF NEW.thread_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT actor_ref INTO v_actor_ref
    FROM public.trust_actors
   WHERE application_user_id = NEW.user_id
     AND workspace_id = NEW.workspace_id
   ORDER BY created_at, id
   LIMIT 1;

  IF v_actor_ref IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'onboarding user has no workspace trust actor';
  END IF;

  INSERT INTO public.threads (
    workspace_id, subject, desired_outcome, status, current_owner_ref, next_action
  ) VALUES (
    NEW.workspace_id,
    'Personal onboarding',
    'Build the durable context, preferences, relationships, and operating boundaries needed for an effective right-hand executive assistant.',
    'active',
    v_actor_ref,
    'Continue onboarding topic ' || COALESCE(NEW.current_topic, 1)::text
  ) RETURNING id INTO NEW.thread_id;

  INSERT INTO public.thread_participants (
    thread_id, actor_type, actor_ref, identity_confidence, roles
  ) VALUES (
    NEW.thread_id, 'person', v_actor_ref, 'verified',
    ARRAY['initiator', 'owner', 'approver']
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER onboarding_sessions_ensure_thread
  BEFORE INSERT ON public.onboarding_sessions
  FOR EACH ROW EXECUTE FUNCTION public.ensure_onboarding_thread();

-- Keep the original provisioning function compatible while moving physical
-- storage to thread_interactions. New code must write thread_interactions
-- directly; this view is only the migration bridge for the original function.
CREATE VIEW public.onboarding_interactions
WITH (security_invoker = true)
AS
SELECT
  interaction.id,
  session.id AS onboarding_session_id,
  interaction.channel,
  interaction.external_id AS external_session_ref,
  ARRAY(
    SELECT value::integer
      FROM jsonb_array_elements_text(
        COALESCE(interaction.content->'topics_advanced', '[]'::jsonb)
      ) AS item(value)
  ) AS topics_advanced,
  interaction.occurred_at AS started_at,
  NULL::timestamptz AS ended_at
FROM public.onboarding_sessions session
JOIN public.thread_interactions interaction
  ON interaction.thread_id = session.thread_id
WHERE interaction.content->>'interaction_type' LIKE 'onboarding.%';

CREATE OR REPLACE FUNCTION public.forward_onboarding_interaction()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_thread_id uuid;
  v_actor_ref text;
BEGIN
  SELECT session.thread_id, thread.current_owner_ref
    INTO v_thread_id, v_actor_ref
    FROM public.onboarding_sessions session
    JOIN public.threads thread ON thread.id = session.thread_id
   WHERE session.id = NEW.onboarding_session_id;

  IF v_thread_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'onboarding session not found';
  END IF;

  INSERT INTO public.thread_interactions (
    id, thread_id, channel, direction, actor_ref, external_id, content,
    occurred_at, created_at
  ) VALUES (
    COALESCE(NEW.id, gen_random_uuid()),
    v_thread_id,
    NEW.channel,
    'inbound',
    v_actor_ref,
    NEW.external_session_ref,
    jsonb_build_object(
      'interaction_type', 'onboarding.started',
      'onboarding_session_id', NEW.onboarding_session_id,
      'topics_advanced', to_jsonb(COALESCE(NEW.topics_advanced, '{}'::integer[])),
      'ended_at', NEW.ended_at,
      'verification_method', 'invite_code'
    ),
    COALESCE(NEW.started_at, now()),
    now()
  ) RETURNING id, occurred_at INTO NEW.id, NEW.started_at;

  UPDATE public.onboarding_sessions
     SET last_channel = NEW.channel,
         last_external_session_ref = NEW.external_session_ref,
         last_activity_at = COALESCE(NEW.started_at, now())
   WHERE id = NEW.onboarding_session_id;

  RETURN NEW;
END;
$$;

CREATE TRIGGER onboarding_interactions_forward_insert
  INSTEAD OF INSERT ON public.onboarding_interactions
  FOR EACH ROW EXECUTE FUNCTION public.forward_onboarding_interaction();

ALTER FUNCTION public.verify_and_provision_onboarding(uuid, text, text, text, text, text, text, text)
  RENAME TO verify_and_provision_onboarding_base;

CREATE FUNCTION public.verify_and_provision_onboarding(
  p_invite_id uuid,
  p_request_id text,
  p_code_digest text,
  p_identifier_type text,
  p_identifier text,
  p_external_session_ref text,
  p_channel text DEFAULT 'phone',
  p_memory_provider text DEFAULT 'litegraph'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_result jsonb;
  v_thread_id uuid;
BEGIN
  v_result := public.verify_and_provision_onboarding_base(
    p_invite_id, p_request_id, p_code_digest, p_identifier_type,
    p_identifier, p_external_session_ref, p_channel, p_memory_provider
  );

  IF v_result->>'status' = 'confirmed' AND v_result ? 'onboarding_session_id' THEN
    SELECT thread_id INTO v_thread_id
      FROM public.onboarding_sessions
     WHERE id = (v_result->>'onboarding_session_id')::uuid;
    v_result := v_result || jsonb_build_object('thread_id', v_thread_id);
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON TABLE public.onboarding_interactions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.onboarding_interactions TO service_role;

REVOKE ALL ON FUNCTION public.ensure_onboarding_thread() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.forward_onboarding_interaction() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.verify_and_provision_onboarding_base(uuid, text, text, text, text, text, text, text)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.verify_and_provision_onboarding(uuid, text, text, text, text, text, text, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_and_provision_onboarding(uuid, text, text, text, text, text, text, text)
TO service_role;
