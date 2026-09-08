-- Durable execution graph beneath the goal-level tasks table. Work is claimed
-- at step granularity; tasks remain the parent snapshot and roll-up boundary.

CREATE TABLE public.workspaces (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,
  name text NOT NULL,
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT workspaces_slug_check CHECK (btrim(slug) <> ''),
  CONSTRAINT workspaces_name_check CHECK (btrim(name) <> ''),
  CONSTRAINT workspaces_status_check CHECK (status IN ('active', 'suspended', 'closed'))
);

INSERT INTO public.workspaces (id, slug, name)
VALUES (
  '00000000-0000-4000-8000-000000000001',
  'm-secondbrain',
  'm-secondbrain'
);

CREATE TABLE public.threads (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE RESTRICT,
  subject text NOT NULL,
  desired_outcome text NOT NULL,
  status text NOT NULL DEFAULT 'open',
  current_owner_ref text,
  next_action text,
  deadline timestamptz,
  resolution jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  CONSTRAINT threads_subject_check CHECK (btrim(subject) <> ''),
  CONSTRAINT threads_outcome_check CHECK (btrim(desired_outcome) <> ''),
  CONSTRAINT threads_status_check CHECK (
    status IN ('open', 'active', 'waiting', 'monitoring', 'resolved', 'cancelled')
  ),
  CONSTRAINT threads_resolution_check CHECK (
    resolution IS NULL OR jsonb_typeof(resolution) = 'object'
  ),
  CONSTRAINT threads_resolved_at_check CHECK (
    (status = 'resolved' AND resolved_at IS NOT NULL)
    OR (status <> 'resolved' AND resolved_at IS NULL)
  )
);

ALTER TABLE public.tasks ADD COLUMN thread_id uuid;
ALTER TABLE public.tasks
  ADD COLUMN execution_status text NOT NULL DEFAULT 'unplanned',
  ADD COLUMN execution_rollup jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN execution_updated_at timestamptz NOT NULL DEFAULT now(),
  ADD CONSTRAINT tasks_execution_status_check CHECK (
    execution_status IN ('unplanned', 'ready', 'running', 'waiting', 'completed', 'failed', 'cancelled')
  ),
  ADD CONSTRAINT tasks_execution_rollup_check CHECK (
    jsonb_typeof(execution_rollup) = 'object'
  );

INSERT INTO public.threads (
  id, workspace_id, subject, desired_outcome, status, created_at, updated_at, resolved_at
)
SELECT
  task.id,
  '00000000-0000-4000-8000-000000000001'::uuid,
  left(task.goal, 200),
  task.goal,
  CASE task.status
    WHEN 'completed' THEN 'resolved'
    WHEN 'cancelled' THEN 'cancelled'
    WHEN 'waiting_user' THEN 'waiting'
    WHEN 'waiting_external' THEN 'waiting'
    WHEN 'retry_scheduled' THEN 'monitoring'
    ELSE 'active'
  END,
  task.created_at,
  task.updated_at,
  CASE WHEN task.status = 'completed' THEN task.completed_at ELSE NULL END
FROM public.tasks AS task;

UPDATE public.tasks SET thread_id = id WHERE thread_id IS NULL;
ALTER TABLE public.tasks ALTER COLUMN thread_id SET NOT NULL;
ALTER TABLE public.tasks
  ADD CONSTRAINT tasks_thread_id_fkey
  FOREIGN KEY (thread_id) REFERENCES public.threads(id) ON DELETE CASCADE;
ALTER TABLE public.tasks
  ADD CONSTRAINT tasks_id_thread_id_key UNIQUE (id, thread_id);
CREATE INDEX tasks_thread_idx ON public.tasks (thread_id, created_at, id);

CREATE OR REPLACE FUNCTION public.ensure_task_thread()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.thread_id IS NULL THEN
    NEW.thread_id := gen_random_uuid();
    INSERT INTO public.threads (
      id, workspace_id, subject, desired_outcome, status
    ) VALUES (
      NEW.thread_id,
      '00000000-0000-4000-8000-000000000001',
      left(NEW.goal, 200),
      NEW.goal,
      'active'
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER tasks_ensure_thread
  BEFORE INSERT ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.ensure_task_thread();

CREATE TABLE public.thread_participants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id uuid NOT NULL REFERENCES public.threads(id) ON DELETE CASCADE,
  actor_type text NOT NULL,
  actor_ref text NOT NULL,
  identity_confidence text NOT NULL DEFAULT 'unverified',
  roles text[] NOT NULL DEFAULT '{}'::text[],
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (thread_id, actor_ref),
  CONSTRAINT thread_participants_actor_type_check CHECK (btrim(actor_type) <> ''),
  CONSTRAINT thread_participants_actor_ref_check CHECK (btrim(actor_ref) <> ''),
  CONSTRAINT thread_participants_confidence_check CHECK (
    identity_confidence IN ('unverified', 'claimed', 'verified', 'trusted')
  ),
  CONSTRAINT thread_participants_roles_check CHECK (
    roles <@ ARRAY['initiator', 'requester', 'owner', 'approver', 'delegate', 'recipient']::text[]
  )
);

CREATE TABLE public.thread_interactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id uuid NOT NULL REFERENCES public.threads(id) ON DELETE CASCADE,
  channel text NOT NULL,
  direction text NOT NULL,
  actor_ref text,
  external_id text,
  content jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (thread_id, channel, external_id),
  CONSTRAINT thread_interactions_channel_check CHECK (btrim(channel) <> ''),
  CONSTRAINT thread_interactions_direction_check CHECK (
    direction IN ('inbound', 'outbound', 'system')
  ),
  CONSTRAINT thread_interactions_content_check CHECK (jsonb_typeof(content) = 'object')
);

CREATE TABLE public.thread_entities (
  thread_id uuid NOT NULL REFERENCES public.threads(id) ON DELETE CASCADE,
  entity_ref text NOT NULL,
  entity_type text NOT NULL,
  role text NOT NULL DEFAULT 'subject',
  salience integer NOT NULL DEFAULT 50,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (thread_id, entity_ref, role),
  CONSTRAINT thread_entities_ref_check CHECK (btrim(entity_ref) <> ''),
  CONSTRAINT thread_entities_type_check CHECK (btrim(entity_type) <> ''),
  CONSTRAINT thread_entities_role_check CHECK (btrim(role) <> ''),
  CONSTRAINT thread_entities_salience_check CHECK (salience BETWEEN 0 AND 100)
);

CREATE TABLE public.task_steps (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  step_key text NOT NULL,
  step_type text NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  input jsonb NOT NULL DEFAULT '{}'::jsonb,
  output jsonb,
  priority integer NOT NULL DEFAULT 3,
  available_at timestamptz NOT NULL DEFAULT now(),
  attempt_count integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 3,
  idempotency_key text NOT NULL,
  claim_token uuid,
  claimed_by text,
  claimed_at timestamptz,
  lease_expires_at timestamptz,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  UNIQUE (task_id, step_key),
  UNIQUE (task_id, idempotency_key),
  UNIQUE (id, task_id),
  CONSTRAINT task_steps_key_check CHECK (btrim(step_key) <> ''),
  CONSTRAINT task_steps_type_check CHECK (btrim(step_type) <> ''),
  CONSTRAINT task_steps_status_check CHECK (
    status IN (
      'pending', 'ready', 'running', 'waiting_user', 'waiting_approval',
      'waiting_external', 'waiting_timer', 'completed', 'failed', 'cancelled'
    )
  ),
  CONSTRAINT task_steps_input_check CHECK (jsonb_typeof(input) = 'object'),
  CONSTRAINT task_steps_output_check CHECK (
    output IS NULL OR jsonb_typeof(output) = 'object'
  ),
  CONSTRAINT task_steps_priority_check CHECK (priority BETWEEN 1 AND 5),
  CONSTRAINT task_steps_attempt_count_check CHECK (attempt_count >= 0),
  CONSTRAINT task_steps_max_attempts_check CHECK (max_attempts BETWEEN 1 AND 10),
  CONSTRAINT task_steps_idempotency_key_check CHECK (btrim(idempotency_key) <> ''),
  CONSTRAINT task_steps_claim_check CHECK (
    (
      status = 'running' AND claim_token IS NOT NULL AND claimed_by IS NOT NULL
      AND claimed_at IS NOT NULL AND lease_expires_at IS NOT NULL
    ) OR (
      status <> 'running' AND claim_token IS NULL AND claimed_by IS NULL
      AND claimed_at IS NULL AND lease_expires_at IS NULL
    )
  ),
  CONSTRAINT task_steps_completion_check CHECK (
    (status = 'completed' AND completed_at IS NOT NULL)
    OR (status <> 'completed' AND completed_at IS NULL)
  )
);

CREATE TABLE public.task_step_dependencies (
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  step_id uuid NOT NULL,
  depends_on_step_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (step_id, depends_on_step_id),
  FOREIGN KEY (step_id, task_id)
    REFERENCES public.task_steps(id, task_id) ON DELETE CASCADE,
  FOREIGN KEY (depends_on_step_id, task_id)
    REFERENCES public.task_steps(id, task_id) ON DELETE CASCADE,
  CONSTRAINT task_step_dependencies_no_self_check CHECK (step_id <> depends_on_step_id)
);

CREATE TABLE public.task_gates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  gate_key text NOT NULL,
  gate_type text NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  condition jsonb NOT NULL DEFAULT '{}'::jsonb,
  resolution jsonb,
  deadline timestamptz,
  satisfied_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (task_id, gate_key),
  UNIQUE (id, task_id),
  CONSTRAINT task_gates_key_check CHECK (btrim(gate_key) <> ''),
  CONSTRAINT task_gates_type_check CHECK (
    gate_type IN ('decision', 'approval', 'commitment', 'external_event', 'timer')
  ),
  CONSTRAINT task_gates_status_check CHECK (
    status IN ('pending', 'satisfied', 'expired', 'cancelled')
  ),
  CONSTRAINT task_gates_condition_check CHECK (jsonb_typeof(condition) = 'object'),
  CONSTRAINT task_gates_resolution_check CHECK (
    resolution IS NULL OR jsonb_typeof(resolution) = 'object'
  ),
  CONSTRAINT task_gates_satisfied_check CHECK (
    (status = 'satisfied' AND satisfied_at IS NOT NULL)
    OR (status <> 'satisfied' AND satisfied_at IS NULL)
  )
);

CREATE TABLE public.task_step_gates (
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  step_id uuid NOT NULL,
  gate_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (step_id, gate_id),
  FOREIGN KEY (step_id, task_id)
    REFERENCES public.task_steps(id, task_id) ON DELETE CASCADE,
  FOREIGN KEY (gate_id, task_id)
    REFERENCES public.task_gates(id, task_id) ON DELETE CASCADE
);

CREATE TABLE public.task_step_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  step_id uuid NOT NULL,
  event_type text NOT NULL,
  actor text,
  idempotency_key text NOT NULL,
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (step_id, task_id)
    REFERENCES public.task_steps(id, task_id) ON DELETE CASCADE,
  UNIQUE (step_id, idempotency_key),
  CONSTRAINT task_step_events_type_check CHECK (btrim(event_type) <> ''),
  CONSTRAINT task_step_events_idempotency_check CHECK (btrim(idempotency_key) <> ''),
  CONSTRAINT task_step_events_data_check CHECK (jsonb_typeof(data) = 'object')
);

CREATE OR REPLACE FUNCTION public.prevent_task_step_dependency_cycle()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF EXISTS (
    WITH RECURSIVE prerequisites(id) AS (
      SELECT NEW.depends_on_step_id
      UNION
      SELECT dependency.depends_on_step_id
        FROM public.task_step_dependencies AS dependency
        JOIN prerequisites ON prerequisites.id = dependency.step_id
       WHERE dependency.task_id = NEW.task_id
    )
    SELECT 1 FROM prerequisites WHERE id = NEW.step_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'task step dependency cycle detected';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER task_step_dependencies_prevent_cycle
  BEFORE INSERT OR UPDATE ON public.task_step_dependencies
  FOR EACH ROW EXECUTE FUNCTION public.prevent_task_step_dependency_cycle();

CREATE TABLE public.task_authority_grants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  grantee_ref text NOT NULL,
  granted_by_ref text NOT NULL,
  scope jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'active',
  expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  CONSTRAINT task_authority_grants_grantee_check CHECK (btrim(grantee_ref) <> ''),
  CONSTRAINT task_authority_grants_grantor_check CHECK (btrim(granted_by_ref) <> ''),
  CONSTRAINT task_authority_grants_scope_check CHECK (jsonb_typeof(scope) = 'object'),
  CONSTRAINT task_authority_grants_status_check CHECK (
    status IN ('active', 'revoked', 'expired')
  )
);

CREATE TABLE public.task_decisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  gate_id uuid NOT NULL,
  title text NOT NULL,
  owner_ref text NOT NULL,
  requested_by_ref text NOT NULL,
  question text NOT NULL,
  preference_dimension text,
  recommendation_key text,
  status text NOT NULL DEFAULT 'pending',
  selected_option_key text,
  resolution_note text,
  source_interaction_id uuid REFERENCES public.thread_interactions(id) ON DELETE SET NULL,
  supersedes_decision_id uuid REFERENCES public.task_decisions(id) ON DELETE SET NULL,
  deadline timestamptz,
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (gate_id, task_id)
    REFERENCES public.task_gates(id, task_id) ON DELETE CASCADE,
  UNIQUE (gate_id),
  CONSTRAINT task_decisions_title_check CHECK (btrim(title) <> ''),
  CONSTRAINT task_decisions_owner_check CHECK (btrim(owner_ref) <> ''),
  CONSTRAINT task_decisions_requester_check CHECK (btrim(requested_by_ref) <> ''),
  CONSTRAINT task_decisions_question_check CHECK (btrim(question) <> ''),
  CONSTRAINT task_decisions_status_check CHECK (
    status IN ('draft', 'pending', 'resolved', 'expired', 'superseded', 'cancelled')
  ),
  CONSTRAINT task_decisions_resolution_check CHECK (
    (status = 'resolved' AND selected_option_key IS NOT NULL AND resolved_at IS NOT NULL)
    OR (status <> 'resolved' AND resolved_at IS NULL)
  )
);

CREATE TABLE public.task_decision_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  decision_id uuid NOT NULL REFERENCES public.task_decisions(id) ON DELETE CASCADE,
  option_key text NOT NULL,
  label text NOT NULL,
  tradeoffs jsonb NOT NULL DEFAULT '{}'::jsonb,
  rank integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (decision_id, option_key),
  CONSTRAINT task_decision_options_key_check CHECK (btrim(option_key) <> ''),
  CONSTRAINT task_decision_options_label_check CHECK (btrim(label) <> ''),
  CONSTRAINT task_decision_options_tradeoffs_check CHECK (jsonb_typeof(tradeoffs) = 'object')
);

CREATE TABLE public.task_decision_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  decision_id uuid NOT NULL REFERENCES public.task_decisions(id) ON DELETE CASCADE,
  event_type text NOT NULL,
  actor_ref text,
  idempotency_key text NOT NULL,
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (decision_id, idempotency_key),
  CONSTRAINT task_decision_events_type_check CHECK (btrim(event_type) <> ''),
  CONSTRAINT task_decision_events_idempotency_check CHECK (btrim(idempotency_key) <> ''),
  CONSTRAINT task_decision_events_data_check CHECK (jsonb_typeof(data) = 'object')
);

CREATE TABLE public.task_delegations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  gate_id uuid NOT NULL,
  requested_by_ref text NOT NULL,
  delegate_ref text NOT NULL,
  requested_outcome text NOT NULL,
  status text NOT NULL DEFAULT 'requested',
  promised_at timestamptz,
  follow_up_at timestamptz,
  escalate_at timestamptz,
  follow_up_policy jsonb NOT NULL DEFAULT '{}'::jsonb,
  deliverable jsonb,
  source_interaction_id uuid REFERENCES public.thread_interactions(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  FOREIGN KEY (gate_id, task_id)
    REFERENCES public.task_gates(id, task_id) ON DELETE CASCADE,
  UNIQUE (gate_id),
  CONSTRAINT task_delegations_requester_check CHECK (btrim(requested_by_ref) <> ''),
  CONSTRAINT task_delegations_delegate_check CHECK (btrim(delegate_ref) <> ''),
  CONSTRAINT task_delegations_outcome_check CHECK (btrim(requested_outcome) <> ''),
  CONSTRAINT task_delegations_status_check CHECK (
    status IN ('requested', 'acknowledged', 'committed', 'delivered', 'overdue', 'escalated', 'closed', 'cancelled')
  ),
  CONSTRAINT task_delegations_policy_check CHECK (jsonb_typeof(follow_up_policy) = 'object'),
  CONSTRAINT task_delegations_deliverable_check CHECK (
    deliverable IS NULL OR jsonb_typeof(deliverable) = 'object'
  )
);

CREATE TABLE public.task_research_artifacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  step_id uuid,
  question text NOT NULL,
  purpose text NOT NULL,
  findings jsonb NOT NULL DEFAULT '{}'::jsonb,
  evidence jsonb NOT NULL DEFAULT '[]'::jsonb,
  confidence text NOT NULL DEFAULT 'unknown',
  valid_until timestamptz,
  memory_status text NOT NULL DEFAULT 'task_only',
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (step_id, task_id)
    REFERENCES public.task_steps(id, task_id) ON DELETE CASCADE,
  CONSTRAINT task_research_question_check CHECK (btrim(question) <> ''),
  CONSTRAINT task_research_purpose_check CHECK (btrim(purpose) <> ''),
  CONSTRAINT task_research_findings_check CHECK (jsonb_typeof(findings) = 'object'),
  CONSTRAINT task_research_evidence_check CHECK (jsonb_typeof(evidence) = 'array'),
  CONSTRAINT task_research_confidence_check CHECK (
    confidence IN ('unknown', 'low', 'medium', 'high', 'verified')
  ),
  CONSTRAINT task_research_memory_status_check CHECK (
    memory_status IN ('task_only', 'candidate', 'promoted', 'rejected', 'expired')
  )
);

CREATE TABLE public.thread_exceptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id uuid NOT NULL REFERENCES public.threads(id) ON DELETE CASCADE,
  task_id uuid,
  exception_type text NOT NULL,
  severity text NOT NULL DEFAULT 'medium',
  status text NOT NULL DEFAULT 'detected',
  context jsonb NOT NULL DEFAULT '{}'::jsonb,
  response_plan jsonb,
  source_interaction_id uuid REFERENCES public.thread_interactions(id) ON DELETE SET NULL,
  detected_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  FOREIGN KEY (task_id, thread_id)
    REFERENCES public.tasks(id, thread_id) ON DELETE CASCADE,
  CONSTRAINT thread_exceptions_type_check CHECK (btrim(exception_type) <> ''),
  CONSTRAINT thread_exceptions_severity_check CHECK (
    severity IN ('low', 'medium', 'high', 'critical')
  ),
  CONSTRAINT thread_exceptions_status_check CHECK (
    status IN ('detected', 'triaged', 'mitigating', 'resolved', 'ignored')
  ),
  CONSTRAINT thread_exceptions_context_check CHECK (jsonb_typeof(context) = 'object'),
  CONSTRAINT thread_exceptions_plan_check CHECK (
    response_plan IS NULL OR jsonb_typeof(response_plan) = 'object'
  )
);

CREATE TABLE public.task_approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  step_id uuid,
  requested_from_ref text NOT NULL,
  scope jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending',
  decision_data jsonb,
  request_idempotency_key text NOT NULL,
  requested_at timestamptz NOT NULL DEFAULT now(),
  decided_at timestamptz,
  expires_at timestamptz,
  FOREIGN KEY (step_id, task_id)
    REFERENCES public.task_steps(id, task_id) ON DELETE CASCADE,
  UNIQUE (task_id, request_idempotency_key),
  CONSTRAINT task_approvals_requester_check CHECK (btrim(requested_from_ref) <> ''),
  CONSTRAINT task_approvals_scope_check CHECK (jsonb_typeof(scope) = 'object'),
  CONSTRAINT task_approvals_decision_check CHECK (
    decision_data IS NULL OR jsonb_typeof(decision_data) = 'object'
  ),
  CONSTRAINT task_approvals_status_check CHECK (
    status IN ('pending', 'approved', 'rejected', 'expired', 'cancelled')
  ),
  CONSTRAINT task_approvals_decided_at_check CHECK (
    (status IN ('approved', 'rejected') AND decided_at IS NOT NULL)
    OR (status NOT IN ('approved', 'rejected') AND decided_at IS NULL)
  )
);

CREATE TABLE public.task_closure_recipients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  recipient_ref text NOT NULL,
  channel text NOT NULL,
  delivery_policy text NOT NULL DEFAULT 'on_terminal',
  channel_config jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (task_id, recipient_ref, channel, delivery_policy),
  CONSTRAINT task_closure_recipient_ref_check CHECK (btrim(recipient_ref) <> ''),
  CONSTRAINT task_closure_channel_check CHECK (btrim(channel) <> ''),
  CONSTRAINT task_closure_policy_check CHECK (
    delivery_policy IN ('on_terminal', 'on_success', 'on_failure', 'on_decision')
  ),
  CONSTRAINT task_closure_config_check CHECK (jsonb_typeof(channel_config) = 'object')
);

CREATE TABLE public.task_memory_refs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  provider text NOT NULL,
  namespace text NOT NULL,
  external_ref text NOT NULL,
  purpose text NOT NULL DEFAULT 'context',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (task_id, provider, namespace, external_ref),
  CONSTRAINT task_memory_refs_provider_check CHECK (btrim(provider) <> ''),
  CONSTRAINT task_memory_refs_namespace_check CHECK (btrim(namespace) <> ''),
  CONSTRAINT task_memory_refs_external_ref_check CHECK (btrim(external_ref) <> ''),
  CONSTRAINT task_memory_refs_purpose_check CHECK (btrim(purpose) <> '')
);

ALTER TABLE public.workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.thread_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.thread_interactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.thread_entities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_step_dependencies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_gates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_step_gates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_step_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_authority_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_decision_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_decision_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_delegations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_research_artifacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.thread_exceptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_closure_recipients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_memory_refs ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER workspaces_updated_at
  BEFORE UPDATE ON public.workspaces
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER threads_updated_at
  BEFORE UPDATE ON public.threads
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER thread_participants_updated_at
  BEFORE UPDATE ON public.thread_participants
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER task_steps_updated_at
  BEFORE UPDATE ON public.task_steps
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER task_gates_updated_at
  BEFORE UPDATE ON public.task_gates
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER task_decisions_updated_at
  BEFORE UPDATE ON public.task_decisions
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER task_delegations_updated_at
  BEFORE UPDATE ON public.task_delegations
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE INDEX task_steps_runnable_idx
  ON public.task_steps (priority, available_at, created_at, id)
  WHERE status IN ('pending', 'ready');
CREATE INDEX task_step_dependencies_task_idx
  ON public.task_step_dependencies (task_id, step_id);
CREATE INDEX task_step_gates_task_idx
  ON public.task_step_gates (task_id, step_id);
CREATE INDEX task_steps_expired_lease_idx
  ON public.task_steps (lease_expires_at, id)
  WHERE status = 'running';
CREATE INDEX task_step_events_step_created_idx
  ON public.task_step_events (step_id, created_at, id);
CREATE INDEX task_approvals_pending_idx
  ON public.task_approvals (task_id, expires_at)
  WHERE status = 'pending';

CREATE OR REPLACE FUNCTION public.refresh_task_execution_rollup(p_task_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_total integer;
  v_completed integer;
  v_failed integer;
  v_cancelled integer;
  v_running integer;
  v_waiting integer;
  v_runnable integer;
  v_status text;
BEGIN
  SELECT
    count(*)::integer,
    count(*) FILTER (WHERE status = 'completed')::integer,
    count(*) FILTER (WHERE status = 'failed')::integer,
    count(*) FILTER (WHERE status = 'cancelled')::integer,
    count(*) FILTER (WHERE status = 'running')::integer,
    count(*) FILTER (WHERE status IN (
      'waiting_user', 'waiting_approval', 'waiting_external', 'waiting_timer'
    ))::integer
  INTO v_total, v_completed, v_failed, v_cancelled, v_running, v_waiting
  FROM public.task_steps
  WHERE task_id = p_task_id;

  SELECT count(*)::integer INTO v_runnable
    FROM public.task_steps AS step
   WHERE step.task_id = p_task_id
     AND step.status IN ('pending', 'ready')
     AND step.available_at <= now()
     AND step.attempt_count < step.max_attempts
     AND NOT EXISTS (
       SELECT 1
         FROM public.task_step_dependencies AS dependency
         JOIN public.task_steps AS prerequisite
           ON prerequisite.id = dependency.depends_on_step_id
          AND prerequisite.task_id = dependency.task_id
        WHERE dependency.step_id = step.id
          AND prerequisite.status <> 'completed'
     )
     AND NOT EXISTS (
       SELECT 1
         FROM public.task_step_gates AS step_gate
         JOIN public.task_gates AS gate
           ON gate.id = step_gate.gate_id
          AND gate.task_id = step_gate.task_id
        WHERE step_gate.step_id = step.id
          AND gate.status <> 'satisfied'
     );

  v_status := CASE
    WHEN v_total = 0 THEN 'unplanned'
    WHEN v_failed > 0 THEN 'failed'
    WHEN v_running > 0 THEN 'running'
    WHEN v_completed + v_cancelled = v_total THEN 'completed'
    WHEN v_runnable > 0 THEN 'ready'
    WHEN v_waiting > 0 OR v_total > v_completed + v_cancelled THEN 'waiting'
    ELSE 'unplanned'
  END;

  UPDATE public.tasks
     SET execution_status = v_status,
         execution_rollup = jsonb_build_object(
           'total', v_total,
           'completed', v_completed,
           'failed', v_failed,
           'cancelled', v_cancelled,
           'running', v_running,
           'waiting', v_waiting,
           'runnable', v_runnable
         ),
         execution_updated_at = now()
   WHERE id = p_task_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_task_execution_rollup_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.refresh_task_execution_rollup(COALESCE(NEW.task_id, OLD.task_id));
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER task_steps_refresh_rollup
  AFTER INSERT OR UPDATE OR DELETE ON public.task_steps
  FOR EACH ROW EXECUTE FUNCTION public.refresh_task_execution_rollup_trigger();
CREATE TRIGGER task_step_dependencies_refresh_rollup
  AFTER INSERT OR UPDATE OR DELETE ON public.task_step_dependencies
  FOR EACH ROW EXECUTE FUNCTION public.refresh_task_execution_rollup_trigger();
CREATE TRIGGER task_gates_refresh_rollup
  AFTER INSERT OR UPDATE OR DELETE ON public.task_gates
  FOR EACH ROW EXECUTE FUNCTION public.refresh_task_execution_rollup_trigger();
CREATE TRIGGER task_step_gates_refresh_rollup
  AFTER INSERT OR UPDATE OR DELETE ON public.task_step_gates
  FOR EACH ROW EXECUTE FUNCTION public.refresh_task_execution_rollup_trigger();

REVOKE ALL ON TABLE
  public.workspaces,
  public.threads,
  public.thread_participants,
  public.thread_interactions,
  public.thread_entities,
  public.task_steps,
  public.task_step_dependencies,
  public.task_gates,
  public.task_step_gates,
  public.task_step_events,
  public.task_authority_grants,
  public.task_approvals,
  public.task_decisions,
  public.task_decision_options,
  public.task_decision_events,
  public.task_delegations,
  public.task_research_artifacts,
  public.thread_exceptions,
  public.task_closure_recipients,
  public.task_memory_refs
FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.workspaces,
  public.threads,
  public.thread_participants,
  public.thread_interactions,
  public.thread_entities,
  public.task_steps,
  public.task_step_dependencies,
  public.task_gates,
  public.task_step_gates,
  public.task_step_events,
  public.task_authority_grants,
  public.task_approvals,
  public.task_decisions,
  public.task_decision_options,
  public.task_decision_events,
  public.task_delegations,
  public.task_research_artifacts,
  public.thread_exceptions,
  public.task_closure_recipients,
  public.task_memory_refs
TO service_role;

CREATE OR REPLACE FUNCTION public.claim_task_step(
  p_worker_id text,
  p_lease_seconds integer DEFAULT 300
)
RETURNS SETOF public.task_steps
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_step public.task_steps%ROWTYPE;
  v_claim_token uuid;
BEGIN
  IF p_worker_id IS NULL OR btrim(p_worker_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'worker_id is required';
  END IF;
  IF p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 30 AND 900 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'lease_seconds must be between 30 and 900';
  END IF;

  FOR v_step IN
    UPDATE public.task_steps
       SET status = CASE WHEN attempt_count >= max_attempts THEN 'failed' ELSE 'ready' END,
           claim_token = NULL,
           claimed_by = NULL,
           claimed_at = NULL,
           lease_expires_at = NULL,
           last_error = 'worker lease expired'
     WHERE status = 'running' AND lease_expires_at <= now()
     RETURNING *
  LOOP
    INSERT INTO public.task_step_events (
      task_id, step_id, event_type, actor, idempotency_key, data
    ) VALUES (
      v_step.task_id, v_step.id, 'step.lease_expired', 'task-step-scheduler',
      'lease-expired:' || gen_random_uuid()::text,
      jsonb_build_object('attempt_count', v_step.attempt_count, 'status', v_step.status)
    );
  END LOOP;

  SELECT step.* INTO v_step
    FROM public.task_steps AS step
    JOIN public.tasks AS task ON task.id = step.task_id
    JOIN public.threads AS thread ON thread.id = task.thread_id
   WHERE step.status IN ('pending', 'ready')
     AND task.status NOT IN ('completed', 'failed', 'cancelled')
     AND thread.status NOT IN ('resolved', 'cancelled')
     AND step.available_at <= now()
     AND step.attempt_count < step.max_attempts
     AND NOT EXISTS (
       SELECT 1
         FROM public.task_step_dependencies AS dependency
         JOIN public.task_steps AS prerequisite
           ON prerequisite.id = dependency.depends_on_step_id
          AND prerequisite.task_id = dependency.task_id
        WHERE dependency.step_id = step.id
          AND prerequisite.status <> 'completed'
     )
     AND NOT EXISTS (
       SELECT 1
         FROM public.task_step_gates AS step_gate
         JOIN public.task_gates AS gate
           ON gate.id = step_gate.gate_id
          AND gate.task_id = step_gate.task_id
        WHERE step_gate.step_id = step.id
          AND gate.status <> 'satisfied'
     )
   ORDER BY step.priority, step.available_at, step.created_at, step.id
   FOR UPDATE OF step SKIP LOCKED
   LIMIT 1;

  IF NOT FOUND THEN RETURN; END IF;

  v_claim_token := gen_random_uuid();
  UPDATE public.task_steps
     SET status = 'running',
         attempt_count = attempt_count + 1,
         claim_token = v_claim_token,
         claimed_by = btrim(p_worker_id),
         claimed_at = now(),
         lease_expires_at = now() + make_interval(secs => p_lease_seconds),
         last_error = NULL
   WHERE id = v_step.id
   RETURNING * INTO v_step;

  INSERT INTO public.task_step_events (
    task_id, step_id, event_type, actor, idempotency_key, data
  ) VALUES (
    v_step.task_id, v_step.id, 'step.claimed', btrim(p_worker_id),
    'claim:' || v_claim_token::text,
    jsonb_build_object(
      'claim_token', v_claim_token,
      'attempt_count', v_step.attempt_count,
      'lease_expires_at', v_step.lease_expires_at
    )
  );

  RETURN NEXT v_step;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_task_step(
  p_step_id uuid,
  p_claim_token uuid,
  p_idempotency_key text,
  p_output jsonb DEFAULT '{}'::jsonb
)
RETURNS public.task_steps
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE v_step public.task_steps%ROWTYPE;
BEGIN
  IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'idempotency_key is required';
  END IF;
  IF p_output IS NULL OR jsonb_typeof(p_output) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'output must be a JSON object';
  END IF;

  SELECT step.* INTO v_step
    FROM public.task_steps AS step
   WHERE step.id = p_step_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'task step not found'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.task_step_events
     WHERE step_id = p_step_id AND idempotency_key = btrim(p_idempotency_key)
  ) THEN RETURN v_step; END IF;

  IF v_step.status <> 'running' OR v_step.claim_token IS DISTINCT FROM p_claim_token THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'task step claim is stale';
  END IF;
  IF v_step.lease_expires_at <= now() THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'task step lease expired';
  END IF;

  UPDATE public.task_steps
     SET status = 'completed', output = p_output, claim_token = NULL,
         claimed_by = NULL, claimed_at = NULL, lease_expires_at = NULL,
         completed_at = now()
   WHERE id = p_step_id RETURNING * INTO v_step;

  INSERT INTO public.task_step_events (
    task_id, step_id, event_type, actor, idempotency_key, data
  ) VALUES (
    v_step.task_id, v_step.id, 'step.completed', 'task-step-worker',
    btrim(p_idempotency_key), p_output
  );
  RETURN v_step;
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_task_decision(
  p_decision_id uuid,
  p_actor_ref text,
  p_option_key text,
  p_resolution_note text,
  p_idempotency_key text
)
RETURNS public.task_decisions
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE v_decision public.task_decisions%ROWTYPE;
BEGIN
  IF p_actor_ref IS NULL OR btrim(p_actor_ref) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'actor_ref is required';
  END IF;
  IF p_option_key IS NULL OR btrim(p_option_key) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'option_key is required';
  END IF;
  IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'idempotency_key is required';
  END IF;

  SELECT decision.* INTO v_decision
    FROM public.task_decisions AS decision
   WHERE decision.id = p_decision_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'task decision not found';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.task_decision_events
     WHERE decision_id = p_decision_id
       AND idempotency_key = btrim(p_idempotency_key)
  ) THEN
    RETURN v_decision;
  END IF;

  IF v_decision.status <> 'pending' THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'task decision is not pending';
  END IF;
  IF v_decision.owner_ref <> btrim(p_actor_ref) THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'decision actor is not owner';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.task_decision_options
     WHERE decision_id = p_decision_id
       AND option_key = btrim(p_option_key)
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'decision option not found';
  END IF;

  UPDATE public.task_decisions
     SET status = 'resolved',
         selected_option_key = btrim(p_option_key),
         resolution_note = NULLIF(btrim(p_resolution_note), ''),
         resolved_at = now()
   WHERE id = p_decision_id
   RETURNING * INTO v_decision;

  UPDATE public.task_gates
     SET status = 'satisfied',
         resolution = jsonb_build_object(
           'decision_id', v_decision.id,
           'selected_option_key', v_decision.selected_option_key,
           'resolution_note', v_decision.resolution_note
         ),
         satisfied_at = now()
   WHERE id = v_decision.gate_id;

  INSERT INTO public.task_decision_events (
    decision_id, event_type, actor_ref, idempotency_key, data
  ) VALUES (
    v_decision.id, 'decision.resolved', btrim(p_actor_ref),
    btrim(p_idempotency_key),
    jsonb_build_object(
      'selected_option_key', v_decision.selected_option_key,
      'resolution_note', v_decision.resolution_note
    )
  );

  RETURN v_decision;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_task_step(text, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_task_step(uuid, uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.resolve_task_decision(uuid, text, text, text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ensure_task_thread()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.refresh_task_execution_rollup(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.refresh_task_execution_rollup_trigger()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.prevent_task_step_dependency_cycle()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_task_step(text, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_task_step(uuid, uuid, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.resolve_task_decision(uuid, text, text, text, text)
  TO service_role;
