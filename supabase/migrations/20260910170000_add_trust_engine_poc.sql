-- Deterministic trust-engine POC. Policy is versioned; live identity and
-- session data remain outside Git. All access is service-role only.

CREATE TABLE public.trust_policy_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version text NOT NULL UNIQUE,
  content_hash text NOT NULL UNIQUE,
  bundle jsonb NOT NULL,
  status text NOT NULL DEFAULT 'draft',
  activated_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT trust_policy_version_check CHECK (btrim(version) <> ''),
  CONSTRAINT trust_policy_hash_check CHECK (btrim(content_hash) <> ''),
  CONSTRAINT trust_policy_bundle_check CHECK (jsonb_typeof(bundle) = 'object'),
  CONSTRAINT trust_policy_status_check CHECK (status IN ('draft', 'active', 'retired')),
  CONSTRAINT trust_policy_activation_check CHECK (
    (status = 'active' AND activated_at IS NOT NULL) OR status <> 'active'
  )
);

CREATE UNIQUE INDEX trust_policy_one_active_idx
  ON public.trust_policy_versions ((status)) WHERE status = 'active';

CREATE TABLE public.trust_actors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  actor_ref text NOT NULL,
  actor_type text NOT NULL DEFAULT 'person',
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, actor_ref),
  CONSTRAINT trust_actor_ref_check CHECK (btrim(actor_ref) <> ''),
  CONSTRAINT trust_actor_type_check CHECK (actor_type IN ('person', 'service', 'organization')),
  CONSTRAINT trust_actor_status_check CHECK (status IN ('active', 'suspended', 'revoked'))
);

CREATE TABLE public.trust_role_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid NOT NULL REFERENCES public.trust_actors(id) ON DELETE CASCADE,
  role_key text NOT NULL,
  clearance_level integer NOT NULL DEFAULT 1,
  compartments text[] NOT NULL DEFAULT '{}'::text[],
  permissions text[] NOT NULL DEFAULT '{}'::text[],
  valid_from timestamptz NOT NULL DEFAULT now(),
  valid_until timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (actor_id, role_key),
  CONSTRAINT trust_role_key_check CHECK (btrim(role_key) <> ''),
  CONSTRAINT trust_role_clearance_check CHECK (clearance_level BETWEEN 1 AND 3),
  CONSTRAINT trust_role_permissions_check CHECK (
    permissions <@ ARRAY['read', 'use', 'disclose', 'write', 'correct', 'delegate']::text[]
  ),
  CONSTRAINT trust_role_validity_check CHECK (valid_until IS NULL OR valid_until > valid_from)
);

CREATE TABLE public.trust_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  external_session_ref text NOT NULL,
  authenticated_actor_id uuid REFERENCES public.trust_actors(id) ON DELETE SET NULL,
  auth_assurance integer NOT NULL DEFAULT 0,
  identity_confidence numeric(5,4),
  present_actor_refs text[] NOT NULL DEFAULT '{}'::text[],
  unknown_speaker_count integer NOT NULL DEFAULT 0,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, external_session_ref),
  CONSTRAINT trust_session_ref_check CHECK (btrim(external_session_ref) <> ''),
  CONSTRAINT trust_session_assurance_check CHECK (auth_assurance BETWEEN 0 AND 4),
  CONSTRAINT trust_session_confidence_check CHECK (
    identity_confidence IS NULL OR identity_confidence BETWEEN 0 AND 1
  ),
  CONSTRAINT trust_session_unknown_check CHECK (unknown_speaker_count >= 0),
  CONSTRAINT trust_session_evidence_check CHECK (jsonb_typeof(evidence) = 'object')
);

CREATE TABLE public.trust_authority_grants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  principal_actor_id uuid NOT NULL REFERENCES public.trust_actors(id) ON DELETE CASCADE,
  task_id uuid REFERENCES public.tasks(id) ON DELETE CASCADE,
  action_key text NOT NULL,
  permissions text[] NOT NULL DEFAULT '{}'::text[],
  compartments text[] NOT NULL DEFAULT '{}'::text[],
  constraints jsonb NOT NULL DEFAULT '{}'::jsonb,
  confirmation_satisfied boolean NOT NULL DEFAULT false,
  granted_by_actor_id uuid REFERENCES public.trust_actors(id) ON DELETE RESTRICT,
  policy_version text NOT NULL,
  valid_from timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT trust_grant_action_check CHECK (btrim(action_key) <> ''),
  CONSTRAINT trust_grant_permissions_check CHECK (
    permissions <@ ARRAY['read', 'use', 'disclose', 'write', 'correct', 'delegate']::text[]
  ),
  CONSTRAINT trust_grant_constraints_check CHECK (jsonb_typeof(constraints) = 'object'),
  CONSTRAINT trust_grant_validity_check CHECK (expires_at > valid_from)
);

CREATE TABLE public.trust_decision_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  session_id uuid REFERENCES public.trust_sessions(id) ON DELETE SET NULL,
  task_id uuid REFERENCES public.tasks(id) ON DELETE SET NULL,
  actor_ref text,
  action_key text NOT NULL,
  requested_permission text NOT NULL,
  resource_owner_ref text,
  resource_sensitivity integer NOT NULL,
  compartment text NOT NULL,
  decision text NOT NULL,
  reason_codes text[] NOT NULL,
  constraints jsonb NOT NULL DEFAULT '{}'::jsonb,
  request_context jsonb NOT NULL DEFAULT '{}'::jsonb,
  policy_version text NOT NULL,
  policy_hash text NOT NULL,
  request_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, request_id),
  CONSTRAINT trust_audit_action_check CHECK (btrim(action_key) <> ''),
  CONSTRAINT trust_audit_permission_check CHECK (
    requested_permission IN ('read', 'use', 'disclose', 'write', 'correct', 'delegate')
  ),
  CONSTRAINT trust_audit_sensitivity_check CHECK (resource_sensitivity BETWEEN 1 AND 3),
  CONSTRAINT trust_audit_compartment_check CHECK (btrim(compartment) <> ''),
  CONSTRAINT trust_audit_decision_check CHECK (
    decision IN ('ALLOW', 'ALLOW_WITH_CONSTRAINTS', 'DENY', 'CHALLENGE', 'CONFIRM', 'REDACT', 'DEFER', 'ESCALATE')
  ),
  CONSTRAINT trust_audit_constraints_check CHECK (jsonb_typeof(constraints) = 'object'),
  CONSTRAINT trust_audit_context_check CHECK (jsonb_typeof(request_context) = 'object'),
  CONSTRAINT trust_audit_request_check CHECK (btrim(request_id) <> '')
);

INSERT INTO public.trust_policy_versions (
  version, content_hash, bundle, status, activated_at
) VALUES (
  'trust-v1',
  'sha256:15e2d2466ca23bf7ed143db7788b7cd3f970c6df286fcfcdf06c8730f37230d2',
  $policy${
    "version":"trust-v1",
    "sensitivity":{"1":"shared","2":"confidential","3":"private"},
    "authentication_assurance":{"0":"unidentified","1":"claimed","2":"channel_associated","3":"strongly_authenticated","4":"step_up_authenticated"},
    "actions":{
      "travel.research":{"risk_level":0,"minimum_auth_assurance":1,"minimum_identity_confidence":0.5,"permissions":["use"],"confirmation_required":false,"owner_only":false},
      "memory.read":{"risk_level":2,"minimum_auth_assurance":3,"minimum_identity_confidence":0.9,"permissions":["read","use"],"confirmation_required":false,"owner_only":false},
      "memory.disclose":{"risk_level":2,"minimum_auth_assurance":3,"minimum_identity_confidence":0.9,"permissions":["disclose"],"confirmation_required":false,"owner_only":false},
      "communication.send":{"risk_level":3,"minimum_auth_assurance":3,"minimum_identity_confidence":0.95,"permissions":["write"],"confirmation_required":true,"owner_only":false},
      "travel.book":{"risk_level":5,"minimum_auth_assurance":4,"minimum_identity_confidence":0.98,"permissions":["write"],"confirmation_required":true,"owner_only":true}
    }
  }$policy$::jsonb,
  'active',
  now()
);

CREATE OR REPLACE FUNCTION public.security_check(
  p_workspace_id uuid,
  p_request_id text,
  p_action_key text,
  p_requested_permission text,
  p_resource_sensitivity integer,
  p_compartment text,
  p_actor_ref text DEFAULT NULL,
  p_session_id uuid DEFAULT NULL,
  p_task_id uuid DEFAULT NULL,
  p_resource_owner_ref text DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_policy public.trust_policy_versions%ROWTYPE;
  v_action jsonb;
  v_actor public.trust_actors%ROWTYPE;
  v_session public.trust_sessions%ROWTYPE;
  v_clearance integer := 0;
  v_compartments text[] := '{}'::text[];
  v_permissions text[] := '{}'::text[];
  v_decision text := 'DENY';
  v_reasons text[] := '{}'::text[];
  v_constraints jsonb := '{}'::jsonb;
  v_min_auth integer;
  v_min_confidence numeric;
  v_confirmation_required boolean;
  v_owner_only boolean;
  v_grant public.trust_authority_grants%ROWTYPE;
  v_existing public.trust_decision_audit%ROWTYPE;
BEGIN
  IF p_request_id IS NULL OR btrim(p_request_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'request_id is required';
  END IF;
  IF p_requested_permission NOT IN ('read', 'use', 'disclose', 'write', 'correct', 'delegate') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid requested_permission';
  END IF;
  IF p_resource_sensitivity NOT BETWEEN 1 AND 3 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'resource_sensitivity must be between 1 and 3';
  END IF;
  IF p_compartment IS NULL OR btrim(p_compartment) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'compartment is required';
  END IF;
  IF p_context IS NULL OR jsonb_typeof(p_context) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'context must be a JSON object';
  END IF;

  SELECT * INTO v_existing FROM public.trust_decision_audit
   WHERE workspace_id = p_workspace_id AND request_id = p_request_id;
  IF FOUND THEN
    IF v_existing.session_id IS DISTINCT FROM p_session_id
       OR v_existing.task_id IS DISTINCT FROM p_task_id
       OR v_existing.actor_ref IS DISTINCT FROM p_actor_ref
       OR v_existing.action_key IS DISTINCT FROM p_action_key
       OR v_existing.requested_permission IS DISTINCT FROM p_requested_permission
       OR v_existing.resource_owner_ref IS DISTINCT FROM p_resource_owner_ref
       OR v_existing.resource_sensitivity IS DISTINCT FROM p_resource_sensitivity
       OR v_existing.compartment IS DISTINCT FROM p_compartment
       OR v_existing.request_context IS DISTINCT FROM p_context THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'request_id reused with different security input';
    END IF;
    RETURN jsonb_build_object(
      'decision', v_existing.decision, 'reason_codes', v_existing.reason_codes,
      'constraints', v_existing.constraints, 'policy_version', v_existing.policy_version,
      'policy_hash', v_existing.policy_hash, 'replayed', true
    );
  END IF;

  SELECT * INTO v_policy FROM public.trust_policy_versions WHERE status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'active trust policy not found';
  END IF;
  v_action := v_policy.bundle->'actions'->p_action_key;

  IF v_action IS NULL THEN
    v_reasons := ARRAY['unknown_action'];
  ELSIF p_actor_ref IS NULL THEN
    v_decision := 'CHALLENGE'; v_reasons := ARRAY['identity_required'];
  ELSE
    SELECT * INTO v_actor FROM public.trust_actors
     WHERE workspace_id = p_workspace_id AND actor_ref = p_actor_ref AND status = 'active';
    IF NOT FOUND THEN
      v_decision := 'CHALLENGE'; v_reasons := ARRAY['identity_not_recognized'];
    ELSE
      SELECT COALESCE(max(clearance_level), 0),
             COALESCE(array_agg(DISTINCT c) FILTER (WHERE c IS NOT NULL), '{}'::text[]),
             COALESCE(array_agg(DISTINCT permission) FILTER (WHERE permission IS NOT NULL), '{}'::text[])
        INTO v_clearance, v_compartments, v_permissions
        FROM public.trust_role_assignments assignment
        LEFT JOIN LATERAL unnest(assignment.compartments) c ON true
        LEFT JOIN LATERAL unnest(assignment.permissions) permission ON true
       WHERE assignment.actor_id = v_actor.id
         AND assignment.valid_from <= now()
         AND (assignment.valid_until IS NULL OR assignment.valid_until > now());

      IF p_session_id IS NOT NULL THEN
        SELECT * INTO v_session FROM public.trust_sessions
         WHERE id = p_session_id AND workspace_id = p_workspace_id
           AND authenticated_actor_id = v_actor.id AND expires_at > now();
      END IF;
      v_min_auth := (v_action->>'minimum_auth_assurance')::integer;
      v_min_confidence := (v_action->>'minimum_identity_confidence')::numeric;
      v_confirmation_required := (v_action->>'confirmation_required')::boolean;
      v_owner_only := (v_action->>'owner_only')::boolean;

      IF v_session.id IS NULL OR v_session.auth_assurance < v_min_auth THEN
        v_decision := 'CHALLENGE'; v_reasons := ARRAY['insufficient_authentication'];
      ELSIF v_session.identity_confidence IS NULL OR v_session.identity_confidence < v_min_confidence THEN
        v_decision := 'CHALLENGE'; v_reasons := ARRAY['identity_confidence_insufficient'];
      ELSIF NOT (v_action->'permissions' ? p_requested_permission) THEN
        v_reasons := ARRAY['permission_not_supported_by_action'];
      ELSIF NOT (p_requested_permission = ANY(v_permissions)) THEN
        v_reasons := ARRAY['permission_not_assigned'];
      ELSIF p_resource_sensitivity > v_clearance THEN
        v_reasons := ARRAY['clearance_insufficient'];
      ELSIF NOT (p_compartment = ANY(v_compartments)) THEN
        v_reasons := ARRAY['compartment_not_assigned'];
      ELSIF p_resource_sensitivity = 3 AND p_actor_ref IS DISTINCT FROM p_resource_owner_ref THEN
        v_reasons := ARRAY['private_owner_only'];
      ELSIF v_owner_only AND p_actor_ref IS DISTINCT FROM p_resource_owner_ref THEN
        v_reasons := ARRAY['action_owner_only'];
      ELSIF p_requested_permission = 'disclose' AND v_session.unknown_speaker_count > 0 THEN
        v_decision := 'DEFER'; v_reasons := ARRAY['unknown_listener_present'];
      ELSE
        SELECT * INTO v_grant FROM public.trust_authority_grants
         WHERE workspace_id = p_workspace_id AND principal_actor_id = v_actor.id
           AND action_key = p_action_key AND revoked_at IS NULL
           AND valid_from <= now() AND expires_at > now()
           AND policy_version = v_policy.version
           AND (task_id IS NULL OR task_id = p_task_id)
           AND p_requested_permission = ANY(permissions)
           AND p_compartment = ANY(compartments)
         ORDER BY task_id NULLS LAST, expires_at LIMIT 1;

        IF v_confirmation_required AND (v_grant.id IS NULL OR NOT v_grant.confirmation_satisfied) THEN
          v_decision := 'CONFIRM'; v_reasons := ARRAY['explicit_confirmation_required'];
        ELSIF v_grant.id IS NOT NULL
          AND (
            (v_grant.constraints ? 'maximum_amount' AND (
              NOT (p_context ? 'amount')
              OR (p_context->>'amount')::numeric > (v_grant.constraints->>'maximum_amount')::numeric
            ))
            OR (v_grant.constraints ? 'currency' AND (
              NOT (p_context ? 'currency')
              OR upper(p_context->>'currency') <> upper(v_grant.constraints->>'currency')
            ))
          ) THEN
          v_decision := 'DENY'; v_reasons := ARRAY['grant_constraints_not_satisfied'];
        ELSIF v_grant.id IS NOT NULL AND v_grant.constraints <> '{}'::jsonb THEN
          v_decision := 'ALLOW_WITH_CONSTRAINTS'; v_reasons := ARRAY['authorized_by_scoped_grant'];
          v_constraints := v_grant.constraints;
        ELSE
          v_decision := 'ALLOW'; v_reasons := ARRAY['policy_requirements_satisfied'];
        END IF;
      END IF;
    END IF;
  END IF;

  INSERT INTO public.trust_decision_audit (
    workspace_id, session_id, task_id, actor_ref, action_key,
    requested_permission, resource_owner_ref, resource_sensitivity,
    compartment, decision, reason_codes, constraints, request_context, policy_version,
    policy_hash, request_id
  ) VALUES (
    p_workspace_id, p_session_id, p_task_id, p_actor_ref, p_action_key,
    p_requested_permission, p_resource_owner_ref, p_resource_sensitivity,
    p_compartment, v_decision, v_reasons, v_constraints, p_context, v_policy.version,
    v_policy.content_hash, p_request_id
  );

  RETURN jsonb_build_object(
    'decision', v_decision, 'reason_codes', v_reasons,
    'constraints', v_constraints, 'policy_version', v_policy.version,
    'policy_hash', v_policy.content_hash, 'replayed', false
  );
END;
$$;

ALTER TABLE public.trust_policy_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trust_actors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trust_role_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trust_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trust_authority_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trust_decision_audit ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.trust_policy_versions, public.trust_actors,
  public.trust_role_assignments, public.trust_sessions,
  public.trust_authority_grants, public.trust_decision_audit
FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.trust_policy_versions,
  public.trust_actors, public.trust_role_assignments, public.trust_sessions,
  public.trust_authority_grants, public.trust_decision_audit TO service_role;

REVOKE ALL ON FUNCTION public.security_check(uuid, text, text, text, integer, text, text, uuid, uuid, text, jsonb)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.security_check(uuid, text, text, text, integer, text, text, uuid, uuid, text, jsonb)
TO service_role;
