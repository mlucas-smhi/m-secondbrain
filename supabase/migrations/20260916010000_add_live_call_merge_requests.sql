-- Durable, provider-neutral approval boundary for live call merges. This
-- migration deliberately stops at approval; provider execution is a separate
-- feature-gated step.

CREATE TABLE public.live_call_merge_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  requesting_session_id uuid NOT NULL,
  target_session_id uuid NOT NULL,
  requested_by_actor_ref text,
  answered_by_actor_ref text,
  reason_summary text,
  status text NOT NULL DEFAULT 'offered',
  decision_id uuid REFERENCES public.task_decisions(id) ON DELETE SET NULL,
  policy_evaluation_id uuid REFERENCES public.trust_decision_audit(id) ON DELETE SET NULL,
  idempotency_key text NOT NULL,
  approval_evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (requesting_session_id, workspace_id)
    REFERENCES public.live_call_sessions(id, workspace_id) ON DELETE CASCADE,
  FOREIGN KEY (target_session_id, workspace_id)
    REFERENCES public.live_call_sessions(id, workspace_id) ON DELETE CASCADE,
  UNIQUE (workspace_id, idempotency_key),
  CONSTRAINT live_call_merge_distinct_sessions CHECK (
    requesting_session_id <> target_session_id
  ),
  CONSTRAINT live_call_merge_idempotency_key_check CHECK (
    btrim(idempotency_key) <> ''
  ),
  CONSTRAINT live_call_merge_status_check CHECK (
    status IN (
      'offered', 'approved', 'denied', 'expired', 'executing', 'joined',
      'failed', 'separated'
    )
  ),
  CONSTRAINT live_call_merge_evidence_check CHECK (
    jsonb_typeof(approval_evidence) = 'object'
  ),
  CONSTRAINT live_call_merge_resolution_check CHECK (
    (status = 'offered' AND resolved_at IS NULL)
    OR (status <> 'offered' AND resolved_at IS NOT NULL)
  )
);

CREATE INDEX live_call_merge_requests_open_idx
  ON public.live_call_merge_requests (workspace_id, expires_at, created_at)
  WHERE status = 'offered';

CREATE OR REPLACE FUNCTION public.propose_live_call_merge(
  p_workspace_id uuid,
  p_requesting_provider_call_ref text,
  p_target_session_id uuid,
  p_idempotency_key text,
  p_reason_summary text DEFAULT NULL,
  p_ttl_seconds integer DEFAULT 90
)
RETURNS public.live_call_merge_requests
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_requesting public.live_call_sessions%ROWTYPE;
  v_target public.live_call_sessions%ROWTYPE;
  v_merge public.live_call_merge_requests%ROWTYPE;
BEGIN
  IF p_requesting_provider_call_ref IS NULL
     OR btrim(p_requesting_provider_call_ref) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'requesting provider_call_ref is required';
  END IF;
  IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'idempotency_key is required';
  END IF;
  IF p_ttl_seconds NOT BETWEEN 15 AND 180 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'ttl_seconds must be between 15 and 180';
  END IF;

  SELECT * INTO v_requesting
    FROM public.live_call_sessions
   WHERE workspace_id = p_workspace_id
     AND provider = 'twilio'
     AND provider_call_ref = btrim(p_requesting_provider_call_ref)
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'requesting live call session not found';
  END IF;

  SELECT * INTO v_target
    FROM public.live_call_sessions
   WHERE workspace_id = p_workspace_id
     AND id = p_target_session_id
     AND provider = 'twilio'
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'target live call session not found';
  END IF;

  IF v_requesting.status NOT IN ('ringing', 'active', 'held')
     OR v_target.status NOT IN ('ringing', 'active', 'held') THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'both call sessions must be live';
  END IF;
  IF v_requesting.id = v_target.id THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'call sessions must be distinct';
  END IF;

  INSERT INTO public.live_call_merge_requests (
    workspace_id, requesting_session_id, target_session_id, reason_summary,
    idempotency_key, expires_at
  ) VALUES (
    p_workspace_id, v_requesting.id, v_target.id,
    NULLIF(btrim(p_reason_summary), ''), btrim(p_idempotency_key),
    now() + make_interval(secs => p_ttl_seconds)
  )
  ON CONFLICT (workspace_id, idempotency_key) DO NOTHING
  RETURNING * INTO v_merge;

  IF NOT FOUND THEN
    SELECT * INTO v_merge
      FROM public.live_call_merge_requests
     WHERE workspace_id = p_workspace_id
       AND idempotency_key = btrim(p_idempotency_key);
    IF v_merge.requesting_session_id <> v_requesting.id
       OR v_merge.target_session_id <> v_target.id THEN
      RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'idempotency key belongs to a different merge';
    END IF;
  END IF;

  RETURN v_merge;
END;
$$;

CREATE OR REPLACE FUNCTION public.answer_live_call_merge(
  p_workspace_id uuid,
  p_merge_request_id uuid,
  p_requesting_provider_call_ref text,
  p_approved boolean,
  p_actor_ref text,
  p_approval_evidence jsonb DEFAULT '{}'::jsonb
)
RETURNS public.live_call_merge_requests
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_merge public.live_call_merge_requests%ROWTYPE;
  v_requesting public.live_call_sessions%ROWTYPE;
  v_target public.live_call_sessions%ROWTYPE;
BEGIN
  IF p_requesting_provider_call_ref IS NULL
     OR btrim(p_requesting_provider_call_ref) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'requesting provider_call_ref is required';
  END IF;
  IF p_actor_ref IS NULL OR btrim(p_actor_ref) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'actor_ref is required';
  END IF;
  IF p_approval_evidence IS NULL OR jsonb_typeof(p_approval_evidence) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'approval_evidence must be an object';
  END IF;

  SELECT * INTO v_merge
    FROM public.live_call_merge_requests
   WHERE workspace_id = p_workspace_id AND id = p_merge_request_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'merge request not found';
  END IF;
  IF v_merge.status <> 'offered' THEN
    RETURN v_merge;
  END IF;

  SELECT * INTO v_requesting
    FROM public.live_call_sessions
   WHERE id = v_merge.requesting_session_id
     AND workspace_id = p_workspace_id
     AND provider = 'twilio'
     AND provider_call_ref = btrim(p_requesting_provider_call_ref)
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'answer is not bound to the requesting call';
  END IF;

  IF v_merge.expires_at <= now() THEN
    UPDATE public.live_call_merge_requests
       SET status = 'expired', resolved_at = now(), updated_at = now()
     WHERE id = v_merge.id RETURNING * INTO v_merge;
    RETURN v_merge;
  END IF;

  SELECT * INTO v_target
    FROM public.live_call_sessions
   WHERE id = v_merge.target_session_id AND workspace_id = p_workspace_id
   FOR UPDATE;
  IF v_requesting.status NOT IN ('ringing', 'active', 'held')
     OR NOT FOUND
     OR v_target.status NOT IN ('ringing', 'active', 'held') THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'both call sessions must still be live';
  END IF;

  UPDATE public.live_call_merge_requests
     SET status = CASE WHEN p_approved THEN 'approved' ELSE 'denied' END,
         requested_by_actor_ref = btrim(p_actor_ref),
         answered_by_actor_ref = btrim(p_actor_ref),
         approval_evidence = p_approval_evidence,
         resolved_at = now(),
         updated_at = now()
   WHERE id = v_merge.id
   RETURNING * INTO v_merge;
  RETURN v_merge;
END;
$$;

ALTER TABLE public.live_call_merge_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.live_call_merge_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.live_call_merge_requests TO service_role;

REVOKE ALL ON FUNCTION public.propose_live_call_merge(
  uuid, text, uuid, text, text, integer
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.propose_live_call_merge(
  uuid, text, uuid, text, text, integer
) TO service_role;

REVOKE ALL ON FUNCTION public.answer_live_call_merge(
  uuid, uuid, text, boolean, text, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.answer_live_call_merge(
  uuid, uuid, text, boolean, text, jsonb
) TO service_role;
