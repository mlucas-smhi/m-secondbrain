-- Provider execution boundary for approved live-call merges. Claiming is
-- serialized and bound to the call that received the owner's approval.

ALTER TABLE public.live_call_merge_requests
  ADD COLUMN room_ref text,
  ADD COLUMN agent_provider_call_ref text,
  ADD COLUMN execution_evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN failure_code text,
  ADD COLUMN execution_started_at timestamptz,
  ADD COLUMN execution_completed_at timestamptz,
  ADD CONSTRAINT live_call_merge_room_ref_check CHECK (
    room_ref IS NULL OR room_ref ~ '^merge-[0-9a-f-]{36}$'
  ),
  ADD CONSTRAINT live_call_merge_execution_evidence_check CHECK (
    jsonb_typeof(execution_evidence) = 'object'
  );

CREATE OR REPLACE FUNCTION public.claim_live_call_merge_execution(
  p_workspace_id uuid,
  p_merge_request_id uuid,
  p_requesting_provider_call_ref text
)
RETURNS jsonb
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

  SELECT * INTO v_merge
    FROM public.live_call_merge_requests
   WHERE workspace_id = p_workspace_id AND id = p_merge_request_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'merge request not found';
  END IF;

  SELECT * INTO v_requesting
    FROM public.live_call_sessions
   WHERE id = v_merge.requesting_session_id
     AND workspace_id = p_workspace_id
     AND provider = 'twilio'
     AND provider_call_ref = btrim(p_requesting_provider_call_ref)
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'execution is not bound to the requesting call';
  END IF;

  SELECT * INTO v_target
    FROM public.live_call_sessions
   WHERE id = v_merge.target_session_id
     AND workspace_id = p_workspace_id
     AND provider = 'twilio'
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'target call session not found';
  END IF;

  IF v_merge.status IN ('executing', 'joined') THEN
    RETURN jsonb_build_object(
      'merge_request', to_jsonb(v_merge),
      'requesting_provider_call_ref', v_requesting.provider_call_ref,
      'target_provider_call_ref', v_target.provider_call_ref,
      'room_ref', v_merge.room_ref,
      'replayed', true
    );
  END IF;
  IF v_merge.status <> 'approved' THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'merge request is not approved';
  END IF;
  IF v_merge.expires_at <= now() THEN
    UPDATE public.live_call_merge_requests
       SET status = 'expired', updated_at = now()
     WHERE id = v_merge.id RETURNING * INTO v_merge;
    RETURN jsonb_build_object(
      'merge_request', to_jsonb(v_merge),
      'requesting_provider_call_ref', v_requesting.provider_call_ref,
      'target_provider_call_ref', v_target.provider_call_ref,
      'room_ref', v_merge.room_ref,
      'replayed', true
    );
  END IF;
  IF v_requesting.status NOT IN ('ringing', 'active', 'held')
     OR v_target.status NOT IN ('ringing', 'active', 'held') THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'both call sessions must still be live';
  END IF;

  UPDATE public.live_call_merge_requests
     SET status = 'executing',
         room_ref = COALESCE(room_ref, 'merge-' || id::text),
         execution_started_at = COALESCE(execution_started_at, now()),
         updated_at = now()
   WHERE id = v_merge.id
   RETURNING * INTO v_merge;

  UPDATE public.live_call_sessions
     SET status = 'merging', room_ref = v_merge.room_ref, updated_at = now()
   WHERE id IN (v_merge.requesting_session_id, v_merge.target_session_id);

  RETURN jsonb_build_object(
    'merge_request', to_jsonb(v_merge),
    'requesting_provider_call_ref', v_requesting.provider_call_ref,
    'target_provider_call_ref', v_target.provider_call_ref,
    'room_ref', v_merge.room_ref,
    'replayed', false
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_live_call_merge_execution(
  p_workspace_id uuid,
  p_merge_request_id uuid,
  p_succeeded boolean,
  p_agent_provider_call_ref text DEFAULT NULL,
  p_failure_code text DEFAULT NULL,
  p_execution_evidence jsonb DEFAULT '{}'::jsonb
)
RETURNS public.live_call_merge_requests
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_merge public.live_call_merge_requests%ROWTYPE;
BEGIN
  IF p_execution_evidence IS NULL OR jsonb_typeof(p_execution_evidence) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'execution_evidence must be an object';
  END IF;
  IF p_succeeded AND (p_agent_provider_call_ref IS NULL OR btrim(p_agent_provider_call_ref) = '') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'agent provider_call_ref is required on success';
  END IF;
  IF NOT p_succeeded AND (p_failure_code IS NULL OR btrim(p_failure_code) = '') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'failure_code is required on failure';
  END IF;

  SELECT * INTO v_merge
    FROM public.live_call_merge_requests
   WHERE workspace_id = p_workspace_id AND id = p_merge_request_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'merge request not found';
  END IF;
  IF v_merge.status IN ('joined', 'failed') THEN
    RETURN v_merge;
  END IF;
  IF v_merge.status <> 'executing' THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'merge request is not executing';
  END IF;

  UPDATE public.live_call_merge_requests
     SET status = CASE WHEN p_succeeded THEN 'joined' ELSE 'failed' END,
         agent_provider_call_ref = NULLIF(btrim(p_agent_provider_call_ref), ''),
         failure_code = CASE WHEN p_succeeded THEN NULL ELSE btrim(p_failure_code) END,
         execution_evidence = p_execution_evidence,
         execution_completed_at = now(),
         updated_at = now()
   WHERE id = v_merge.id
   RETURNING * INTO v_merge;

  UPDATE public.live_call_sessions
     SET status = 'active', updated_at = now()
   WHERE id IN (v_merge.requesting_session_id, v_merge.target_session_id)
     AND status = 'merging';

  RETURN v_merge;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_live_call_merge_execution(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_live_call_merge_execution(uuid, uuid, text)
  TO service_role;

REVOKE ALL ON FUNCTION public.complete_live_call_merge_execution(
  uuid, uuid, boolean, text, text, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_live_call_merge_execution(
  uuid, uuid, boolean, text, text, jsonb
) TO service_role;
