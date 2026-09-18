-- Durable application identity and resumable onboarding. Invitation codes are
-- HMACed by the trusted Edge Function before they reach Postgres; raw codes are
-- never stored in this schema.

CREATE TABLE public.application_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
  display_name text,
  status text NOT NULL DEFAULT 'onboarding',
  onboarding_status text NOT NULL DEFAULT 'not_started',
  default_workspace_id uuid REFERENCES public.workspaces(id) ON DELETE SET NULL,
  suspended_at timestamptz,
  suspension_reason text,
  retention_until timestamptz,
  deletion_requested_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT application_users_name_check CHECK (
    display_name IS NULL OR btrim(display_name) <> ''
  ),
  CONSTRAINT application_users_status_check CHECK (
    status IN ('onboarding', 'active', 'suspended', 'pending_deletion', 'deleted')
  ),
  CONSTRAINT application_users_onboarding_check CHECK (
    onboarding_status IN ('not_started', 'in_progress', 'minimum_complete', 'completed')
  ),
  CONSTRAINT application_users_suspension_check CHECK (
    status <> 'suspended' OR (suspended_at IS NOT NULL AND retention_until IS NOT NULL)
  ),
  CONSTRAINT application_users_deletion_check CHECK (
    status <> 'deleted' OR deleted_at IS NOT NULL
  ),
  CONSTRAINT application_users_retention_check CHECK (
    retention_until IS NULL OR suspended_at IS NULL OR retention_until > suspended_at
  )
);

ALTER TABLE public.trust_actors
  ADD COLUMN application_user_id uuid REFERENCES public.application_users(id) ON DELETE RESTRICT;

CREATE INDEX trust_actors_application_user_idx
  ON public.trust_actors (application_user_id, workspace_id)
  WHERE application_user_id IS NOT NULL;

CREATE UNIQUE INDEX trust_actors_id_workspace_idx
  ON public.trust_actors (id, workspace_id);

CREATE TABLE public.onboarding_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code_digest text NOT NULL,
  invite_type text NOT NULL,
  delivery_channel text NOT NULL,
  intended_identifier_type text NOT NULL,
  intended_identifier text NOT NULL,
  auth_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'pending',
  attempt_count integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 5,
  expires_at timestamptz NOT NULL,
  verified_at timestamptz,
  consumed_at timestamptz,
  consumed_by_user_id uuid REFERENCES public.application_users(id) ON DELETE RESTRICT,
  consumed_request_id text,
  created_by_actor_id uuid REFERENCES public.trust_actors(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT onboarding_invite_digest_check CHECK (code_digest ~ '^[0-9a-f]{64}$'),
  CONSTRAINT onboarding_invite_type_check CHECK (invite_type IN ('preview_invite', 'signup')),
  CONSTRAINT onboarding_invite_channel_check CHECK (delivery_channel IN ('phone', 'sms', 'email', 'manual')),
  CONSTRAINT onboarding_invite_identifier_type_check CHECK (intended_identifier_type IN ('phone', 'email')),
  CONSTRAINT onboarding_invite_identifier_check CHECK (
    (intended_identifier_type = 'phone' AND intended_identifier ~ '^\+[1-9][0-9]{7,14}$')
    OR (intended_identifier_type = 'email' AND intended_identifier = lower(intended_identifier)
        AND intended_identifier LIKE '%@%')
  ),
  CONSTRAINT onboarding_invite_status_check CHECK (
    status IN ('pending', 'verified', 'consumed', 'expired', 'revoked', 'locked')
  ),
  CONSTRAINT onboarding_invite_attempts_check CHECK (
    max_attempts BETWEEN 1 AND 20 AND attempt_count BETWEEN 0 AND max_attempts
  ),
  CONSTRAINT onboarding_invite_expiry_check CHECK (expires_at > created_at),
  CONSTRAINT onboarding_invite_consumed_check CHECK (
    (status = 'consumed' AND consumed_at IS NOT NULL AND consumed_by_user_id IS NOT NULL
      AND consumed_request_id IS NOT NULL)
    OR status <> 'consumed'
  )
);

ALTER TABLE public.application_users
  ADD COLUMN created_from_invite_id uuid UNIQUE
  REFERENCES public.onboarding_invites(id) ON DELETE RESTRICT;

CREATE INDEX onboarding_invites_lookup_idx
  ON public.onboarding_invites (status, expires_at);

CREATE TABLE public.onboarding_validation_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invite_id uuid NOT NULL REFERENCES public.onboarding_invites(id) ON DELETE RESTRICT,
  request_id text NOT NULL,
  external_session_ref text,
  presented_identifier_type text,
  presented_identifier text,
  outcome text NOT NULL,
  failure_reason text,
  attempted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (invite_id, request_id),
  CONSTRAINT onboarding_attempt_request_check CHECK (btrim(request_id) <> ''),
  CONSTRAINT onboarding_attempt_identifier_type_check CHECK (
    presented_identifier_type IS NULL OR presented_identifier_type IN ('phone', 'email')
  ),
  CONSTRAINT onboarding_attempt_outcome_check CHECK (
    outcome IN ('confirmed', 'rejected', 'locked', 'expired', 'revoked', 'already_consumed')
  ),
  CONSTRAINT onboarding_attempt_failure_check CHECK (
    (outcome = 'confirmed' AND failure_reason IS NULL)
    OR (outcome <> 'confirmed' AND failure_reason IS NOT NULL)
  )
);

CREATE TABLE public.trust_actor_identifiers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  actor_id uuid NOT NULL,
  identifier_type text NOT NULL,
  normalized_value text NOT NULL,
  label text,
  is_primary boolean NOT NULL DEFAULT false,
  verification_status text NOT NULL DEFAULT 'unverified',
  verified_at timestamptz,
  verification_method text,
  valid_from timestamptz NOT NULL DEFAULT now(),
  valid_until timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (actor_id, workspace_id)
    REFERENCES public.trust_actors(id, workspace_id) ON DELETE CASCADE,
  CONSTRAINT trust_identifier_type_check CHECK (
    identifier_type IN ('phone', 'email', 'auth_user', 'voiceprint')
  ),
  CONSTRAINT trust_identifier_value_check CHECK (
    (identifier_type = 'phone' AND normalized_value ~ '^\+[1-9][0-9]{7,14}$')
    OR (identifier_type = 'email' AND normalized_value = lower(normalized_value)
        AND normalized_value LIKE '%@%')
    OR (identifier_type IN ('auth_user', 'voiceprint') AND btrim(normalized_value) <> '')
  ),
  CONSTRAINT trust_identifier_status_check CHECK (
    verification_status IN ('unverified', 'verified', 'revoked')
  ),
  CONSTRAINT trust_identifier_verified_check CHECK (
    verification_status <> 'verified' OR verified_at IS NOT NULL
  ),
  CONSTRAINT trust_identifier_validity_check CHECK (
    valid_until IS NULL OR valid_until > valid_from
  )
);

CREATE UNIQUE INDEX trust_identifier_active_workspace_value_idx
  ON public.trust_actor_identifiers (workspace_id, identifier_type, normalized_value)
  WHERE verification_status <> 'revoked' AND valid_until IS NULL;

CREATE UNIQUE INDEX trust_identifier_primary_actor_type_idx
  ON public.trust_actor_identifiers (actor_id, identifier_type)
  WHERE is_primary AND verification_status <> 'revoked' AND valid_until IS NULL;

CREATE TABLE public.onboarding_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.application_users(id) ON DELETE CASCADE,
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'in_progress',
  current_topic integer,
  completed_topics integer[] NOT NULL DEFAULT '{}'::integer[],
  checkpoint jsonb NOT NULL DEFAULT '{}'::jsonb,
  completion_percentage integer NOT NULL DEFAULT 0,
  last_channel text,
  last_external_session_ref text,
  started_at timestamptz NOT NULL DEFAULT now(),
  last_activity_at timestamptz NOT NULL DEFAULT now(),
  minimum_completed_at timestamptz,
  completed_at timestamptz,
  CONSTRAINT onboarding_session_status_check CHECK (
    status IN ('in_progress', 'paused', 'minimum_complete', 'completed', 'abandoned')
  ),
  CONSTRAINT onboarding_session_topic_check CHECK (current_topic IS NULL OR current_topic BETWEEN 1 AND 7),
  CONSTRAINT onboarding_session_completed_topics_check CHECK (
    completed_topics <@ ARRAY[1,2,3,4,5,6,7]
  ),
  CONSTRAINT onboarding_session_checkpoint_check CHECK (jsonb_typeof(checkpoint) = 'object'),
  CONSTRAINT onboarding_session_percentage_check CHECK (completion_percentage BETWEEN 0 AND 100),
  CONSTRAINT onboarding_session_channel_check CHECK (
    last_channel IS NULL OR last_channel IN ('phone', 'sms', 'email', 'web')
  ),
  CONSTRAINT onboarding_session_completion_check CHECK (
    (status = 'completed' AND completed_at IS NOT NULL) OR status <> 'completed'
  )
);

CREATE UNIQUE INDEX onboarding_one_open_session_per_user_idx
  ON public.onboarding_sessions (user_id)
  WHERE status IN ('in_progress', 'paused', 'minimum_complete');

CREATE TABLE public.onboarding_interactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  onboarding_session_id uuid NOT NULL REFERENCES public.onboarding_sessions(id) ON DELETE CASCADE,
  channel text NOT NULL,
  external_session_ref text NOT NULL,
  topics_advanced integer[] NOT NULL DEFAULT '{}'::integer[],
  started_at timestamptz NOT NULL DEFAULT now(),
  ended_at timestamptz,
  UNIQUE (channel, external_session_ref),
  CONSTRAINT onboarding_interaction_channel_check CHECK (channel IN ('phone', 'sms', 'email', 'web')),
  CONSTRAINT onboarding_interaction_ref_check CHECK (btrim(external_session_ref) <> ''),
  CONSTRAINT onboarding_interaction_topics_check CHECK (topics_advanced <@ ARRAY[1,2,3,4,5,6,7]),
  CONSTRAINT onboarding_interaction_time_check CHECK (ended_at IS NULL OR ended_at >= started_at)
);

CREATE TABLE public.workspace_memory_stores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  provider text NOT NULL,
  namespace text NOT NULL,
  external_store_ref text,
  status text NOT NULL DEFAULT 'provisioning',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, provider),
  UNIQUE (provider, namespace),
  CONSTRAINT workspace_memory_provider_check CHECK (btrim(provider) <> ''),
  CONSTRAINT workspace_memory_namespace_check CHECK (btrim(namespace) <> ''),
  CONSTRAINT workspace_memory_status_check CHECK (status IN ('provisioning', 'active', 'suspended', 'deleting', 'deleted'))
);

CREATE TABLE public.user_acceptances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.application_users(id) ON DELETE CASCADE,
  document_type text NOT NULL,
  document_version text NOT NULL,
  channel text NOT NULL,
  accepted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, document_type, document_version),
  CONSTRAINT user_acceptance_type_check CHECK (btrim(document_type) <> ''),
  CONSTRAINT user_acceptance_version_check CHECK (btrim(document_version) <> ''),
  CONSTRAINT user_acceptance_channel_check CHECK (channel IN ('phone', 'sms', 'email', 'web'))
);

CREATE OR REPLACE FUNCTION public.create_onboarding_invite(
  p_code_digest text,
  p_invite_type text,
  p_delivery_channel text,
  p_identifier_type text,
  p_identifier text,
  p_expires_at timestamptz,
  p_max_attempts integer DEFAULT 5,
  p_auth_user_id uuid DEFAULT NULL,
  p_created_by_actor_id uuid DEFAULT NULL,
  p_invite_id uuid DEFAULT gen_random_uuid()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_invite public.onboarding_invites%ROWTYPE;
BEGIN
  IF p_code_digest IS NULL OR p_code_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid code digest';
  END IF;
  IF p_expires_at IS NULL OR p_expires_at <= now() THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invite expiry must be in the future';
  END IF;

  INSERT INTO public.onboarding_invites (
    id, code_digest, invite_type, delivery_channel, intended_identifier_type,
    intended_identifier, auth_user_id, max_attempts, expires_at, created_by_actor_id
  ) VALUES (
    p_invite_id, p_code_digest, p_invite_type, p_delivery_channel, p_identifier_type,
    CASE WHEN p_identifier_type = 'email' THEN lower(btrim(p_identifier)) ELSE btrim(p_identifier) END,
    p_auth_user_id, p_max_attempts, p_expires_at, p_created_by_actor_id
  ) RETURNING * INTO v_invite;

  RETURN jsonb_build_object(
    'invite_id', v_invite.id,
    'status', v_invite.status,
    'expires_at', v_invite.expires_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.verify_and_provision_onboarding(
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
  v_invite public.onboarding_invites%ROWTYPE;
  v_existing_attempt public.onboarding_validation_attempts%ROWTYPE;
  v_user_id uuid;
  v_workspace_id uuid;
  v_actor_id uuid;
  v_onboarding_session_id uuid;
  v_trust_session_id uuid;
  v_identifier text;
  v_reason text;
  v_outcome text;
  v_next_attempt_count integer;
BEGIN
  IF p_invite_id IS NULL OR p_request_id IS NULL OR btrim(p_request_id) = ''
     OR length(p_request_id) > 200 OR p_code_digest IS NULL
     OR p_code_digest !~ '^[0-9a-f]{64}$'
     OR p_external_session_ref IS NULL OR btrim(p_external_session_ref) = ''
     OR length(p_external_session_ref) > 200 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid verification request';
  END IF;
  IF p_identifier_type NOT IN ('phone', 'email') OR p_channel NOT IN ('phone', 'sms', 'email', 'web') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid verification channel';
  END IF;

  v_identifier := CASE
    WHEN p_identifier_type = 'email' THEN lower(btrim(p_identifier))
    ELSE btrim(p_identifier)
  END;

  SELECT * INTO v_existing_attempt
    FROM public.onboarding_validation_attempts
   WHERE invite_id = p_invite_id AND request_id = p_request_id;

  IF FOUND THEN
    SELECT * INTO v_invite FROM public.onboarding_invites WHERE id = p_invite_id;
    IF v_existing_attempt.outcome = 'confirmed' AND v_invite.consumed_by_user_id IS NOT NULL THEN
      SELECT actor.id, actor.workspace_id, session.id, trust_session.id
        INTO v_actor_id, v_workspace_id, v_onboarding_session_id, v_trust_session_id
        FROM public.trust_actors actor
        JOIN public.onboarding_sessions session
          ON session.user_id = actor.application_user_id AND session.workspace_id = actor.workspace_id
        LEFT JOIN public.trust_sessions trust_session
          ON trust_session.workspace_id = actor.workspace_id
         AND trust_session.authenticated_actor_id = actor.id
         AND trust_session.external_session_ref = btrim(p_external_session_ref)
       WHERE actor.application_user_id = v_invite.consumed_by_user_id
       ORDER BY session.started_at DESC LIMIT 1;
      RETURN jsonb_build_object(
        'status', 'confirmed', 'replayed', true,
        'user_id', v_invite.consumed_by_user_id,
        'actor_ref', 'user:' || v_invite.consumed_by_user_id::text,
        'workspace_id', v_workspace_id,
        'onboarding_session_id', v_onboarding_session_id,
        'trust_session_id', v_trust_session_id,
        'onboarding_state', 'in_progress'
      );
    END IF;
    RETURN jsonb_build_object(
      'status', CASE WHEN v_existing_attempt.outcome = 'locked' THEN 'locked' ELSE 'retry' END,
      'reason_code', v_existing_attempt.failure_reason,
      'replayed', true
    );
  END IF;

  SELECT * INTO v_invite
    FROM public.onboarding_invites
   WHERE id = p_invite_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'retry', 'reason_code', 'invite_not_found', 'replayed', false);
  END IF;

  IF v_invite.status = 'consumed' THEN
    v_reason := 'already_consumed'; v_outcome := 'already_consumed';
  ELSIF v_invite.status = 'revoked' THEN
    v_reason := 'invite_revoked'; v_outcome := 'revoked';
  ELSIF v_invite.status = 'locked' THEN
    v_reason := 'attempt_limit_reached'; v_outcome := 'locked';
  ELSIF v_invite.status = 'expired' OR v_invite.expires_at <= now() THEN
    UPDATE public.onboarding_invites SET status = 'expired', updated_at = now() WHERE id = v_invite.id;
    v_reason := 'invite_expired'; v_outcome := 'expired';
  ELSIF v_invite.intended_identifier_type <> p_identifier_type
     OR v_invite.intended_identifier <> v_identifier THEN
    v_reason := 'identifier_mismatch'; v_outcome := 'rejected';
  ELSIF v_invite.code_digest <> p_code_digest THEN
    v_reason := 'code_mismatch'; v_outcome := 'rejected';
  END IF;

  IF v_reason IS NOT NULL THEN
    IF v_outcome = 'rejected' THEN
      v_next_attempt_count := LEAST(v_invite.attempt_count + 1, v_invite.max_attempts);
      UPDATE public.onboarding_invites
         SET attempt_count = v_next_attempt_count,
             status = CASE WHEN v_next_attempt_count >= max_attempts THEN 'locked' ELSE status END,
             updated_at = now()
       WHERE id = v_invite.id;
      IF v_next_attempt_count >= v_invite.max_attempts THEN
        v_outcome := 'locked'; v_reason := 'attempt_limit_reached';
      END IF;
    END IF;

    INSERT INTO public.onboarding_validation_attempts (
      invite_id, request_id, external_session_ref, presented_identifier_type,
      presented_identifier, outcome, failure_reason
    ) VALUES (
      v_invite.id, p_request_id, btrim(p_external_session_ref), p_identifier_type,
      v_identifier, v_outcome, v_reason
    );

    RETURN jsonb_build_object(
      'status', CASE WHEN v_outcome = 'locked' THEN 'locked' ELSE 'retry' END,
      'reason_code', v_reason,
      'replayed', false
    );
  END IF;

  v_user_id := gen_random_uuid();
  v_workspace_id := gen_random_uuid();

  INSERT INTO public.application_users (
    id, auth_user_id, status, onboarding_status, created_from_invite_id
  ) VALUES (
    v_user_id, v_invite.auth_user_id, 'onboarding', 'in_progress', v_invite.id
  );

  INSERT INTO public.workspaces (id, slug, name)
  VALUES (v_workspace_id, 'user-' || replace(v_user_id::text, '-', ''), 'Personal workspace');

  UPDATE public.application_users SET default_workspace_id = v_workspace_id WHERE id = v_user_id;

  INSERT INTO public.trust_actors (workspace_id, application_user_id, actor_ref, actor_type)
  VALUES (v_workspace_id, v_user_id, 'user:' || v_user_id::text, 'person')
  RETURNING id INTO v_actor_id;

  INSERT INTO public.trust_role_assignments (
    actor_id, role_key, clearance_level, compartments, permissions
  ) VALUES (
    v_actor_id, 'owner', 3,
    ARRAY['personal', 'family', 'business', 'travel'],
    ARRAY['read', 'use', 'disclose', 'write', 'correct', 'delegate']
  );

  INSERT INTO public.trust_actor_identifiers (
    workspace_id, actor_id, identifier_type, normalized_value, label,
    is_primary, verification_status, verified_at, verification_method
  ) VALUES (
    v_workspace_id, v_actor_id, p_identifier_type, v_identifier,
    CASE WHEN p_identifier_type = 'phone' THEN 'mobile' ELSE 'personal' END,
    true, 'verified', now(), 'invite_code'
  );

  INSERT INTO public.onboarding_sessions (
    user_id, workspace_id, status, current_topic, completion_percentage,
    last_channel, last_external_session_ref
  ) VALUES (
    v_user_id, v_workspace_id, 'in_progress', 1, 0,
    p_channel, btrim(p_external_session_ref)
  ) RETURNING id INTO v_onboarding_session_id;

  INSERT INTO public.onboarding_interactions (
    onboarding_session_id, channel, external_session_ref
  ) VALUES (v_onboarding_session_id, p_channel, btrim(p_external_session_ref));

  INSERT INTO public.workspace_memory_stores (
    workspace_id, provider, namespace, status
  ) VALUES (
    v_workspace_id, btrim(p_memory_provider), 'workspace:' || v_workspace_id::text, 'provisioning'
  );

  INSERT INTO public.trust_sessions (
    workspace_id, external_session_ref, authenticated_actor_id,
    auth_assurance, identity_confidence, present_actor_refs,
    unknown_speaker_count, evidence, expires_at
  ) VALUES (
    v_workspace_id, btrim(p_external_session_ref), v_actor_id,
    3, 1.0, ARRAY['user:' || v_user_id::text], 0,
    jsonb_build_object('method', 'invite_code', 'invite_id', v_invite.id),
    now() + interval '12 hours'
  ) RETURNING id INTO v_trust_session_id;

  UPDATE public.onboarding_invites
     SET status = 'consumed', verified_at = now(), consumed_at = now(),
         consumed_by_user_id = v_user_id, consumed_request_id = p_request_id,
         updated_at = now()
   WHERE id = v_invite.id;

  INSERT INTO public.onboarding_validation_attempts (
    invite_id, request_id, external_session_ref, presented_identifier_type,
    presented_identifier, outcome
  ) VALUES (
    v_invite.id, p_request_id, btrim(p_external_session_ref),
    p_identifier_type, v_identifier, 'confirmed'
  );

  RETURN jsonb_build_object(
    'status', 'confirmed', 'replayed', false,
    'user_id', v_user_id,
    'actor_ref', 'user:' || v_user_id::text,
    'workspace_id', v_workspace_id,
    'onboarding_session_id', v_onboarding_session_id,
    'trust_session_id', v_trust_session_id,
    'onboarding_state', 'in_progress'
  );
END;
$$;

ALTER TABLE public.application_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.onboarding_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.onboarding_validation_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trust_actor_identifiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.onboarding_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.onboarding_interactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workspace_memory_stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_acceptances ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.application_users, public.onboarding_invites,
  public.onboarding_validation_attempts, public.trust_actor_identifiers,
  public.onboarding_sessions, public.onboarding_interactions,
  public.workspace_memory_stores, public.user_acceptances
FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.application_users,
  public.onboarding_invites, public.onboarding_validation_attempts,
  public.trust_actor_identifiers, public.onboarding_sessions,
  public.onboarding_interactions, public.workspace_memory_stores,
  public.user_acceptances TO service_role;

REVOKE ALL ON FUNCTION public.create_onboarding_invite(text, text, text, text, text, timestamptz, integer, uuid, uuid, uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_onboarding_invite(text, text, text, text, text, timestamptz, integer, uuid, uuid, uuid)
TO service_role;

REVOKE ALL ON FUNCTION public.verify_and_provision_onboarding(uuid, text, text, text, text, text, text, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_and_provision_onboarding(uuid, text, text, text, text, text, text, text)
TO service_role;
