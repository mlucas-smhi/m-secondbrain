-- Give workers one replay-safe entry point for resolving an adapter and
-- beginning a tool run. Provider result storage completes that run atomically.

CREATE OR REPLACE FUNCTION public.begin_task_step_tool_run(
  p_step_id uuid,
  p_claim_token uuid,
  p_capability text,
  p_operation text,
  p_idempotency_key text,
  p_request_summary jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_step public.task_steps%ROWTYPE;
  v_requirement public.task_step_tool_requirements%ROWTYPE;
  v_adapter public.tool_adapters%ROWTYPE;
  v_run public.task_step_tool_runs%ROWTYPE;
  v_capability text := btrim(p_capability);
  v_operation text := btrim(p_operation);
  v_idempotency_key text := btrim(p_idempotency_key);
BEGIN
  IF NULLIF(v_capability, '') IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'capability is required';
  END IF;
  IF NULLIF(v_operation, '') IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'operation is required';
  END IF;
  IF NULLIF(v_idempotency_key, '') IS NULL OR length(v_idempotency_key) > 200 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'valid idempotency key is required';
  END IF;
  IF p_request_summary IS NULL OR jsonb_typeof(p_request_summary) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'request summary must be a JSON object';
  END IF;

  SELECT step.* INTO v_step
    FROM public.task_steps AS step
   WHERE step.id = p_step_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'task step not found';
  END IF;
  IF v_step.status <> 'running'
     OR v_step.claim_token IS DISTINCT FROM p_claim_token
     OR v_step.lease_expires_at IS NULL
     OR v_step.lease_expires_at <= now() THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'task step claim is not active';
  END IF;

  SELECT requirement.* INTO v_requirement
    FROM public.task_step_tool_requirements AS requirement
   WHERE requirement.step_id = p_step_id
     AND requirement.capability = v_capability;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'tool requirement not found';
  END IF;

  SELECT resolved.* INTO v_adapter
    FROM public.resolve_task_step_tool_adapter(p_step_id, v_capability) AS resolved;

  INSERT INTO public.task_step_tool_runs (
    task_id, step_id, adapter_id, capability, operation,
    status, idempotency_key, request_summary
  ) VALUES (
    v_step.task_id, v_step.id, v_adapter.id, v_capability, v_operation,
    'running', v_idempotency_key, p_request_summary
  )
  ON CONFLICT (step_id, idempotency_key) DO NOTHING;

  SELECT run.* INTO v_run
    FROM public.task_step_tool_runs AS run
   WHERE run.step_id = p_step_id
     AND run.idempotency_key = v_idempotency_key;

  IF v_run.adapter_id IS DISTINCT FROM v_adapter.id
     OR v_run.capability IS DISTINCT FROM v_capability
     OR v_run.operation IS DISTINCT FROM v_operation
     OR v_run.request_summary IS DISTINCT FROM p_request_summary THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409',
      MESSAGE = 'tool run idempotency key was reused with different input';
  END IF;

  RETURN jsonb_build_object(
    'tool_run', to_jsonb(v_run),
    'adapter', jsonb_build_object(
      'id', v_adapter.id,
      'adapter_key', v_adapter.adapter_key,
      'provider', v_adapter.provider,
      'transport', v_adapter.transport,
      'credential_ref', v_adapter.credential_ref,
      'configuration', v_adapter.configuration
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.begin_task_step_tool_run(uuid, uuid, text, text, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.begin_task_step_tool_run(uuid, uuid, text, text, text, jsonb)
  TO service_role;

CREATE OR REPLACE FUNCTION public.store_travel_search_result(
  p_tool_run_id uuid, p_provider text, p_result_type text,
  p_canonical_result jsonb, p_protected_refs jsonb, p_expires_at timestamptz
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_run public.task_step_tool_runs%ROWTYPE;
  v_adapter_provider text;
  v_result_id uuid;
BEGIN
  IF p_result_type NOT IN ('travel.flight_search.v1', 'travel.hotel_search.v1', 'travel.car_search.v1')
     OR p_canonical_result->>'schema_version' IS DISTINCT FROM p_result_type THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid travel result schema';
  END IF;
  IF NULLIF(btrim(p_canonical_result->>'provider'), '') IS NULL
     OR NULLIF(btrim(p_canonical_result->>'retrieved_at'), '') IS NULL
     OR NULLIF(btrim(p_canonical_result->>'valid_until'), '') IS NULL
     OR (p_canonical_result->>'valid_until')::timestamptz <= (p_canonical_result->>'retrieved_at')::timestamptz THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'travel result provenance and validity are required';
  END IF;
  IF jsonb_typeof(p_canonical_result->'offers') IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_canonical_result->'offers') NOT BETWEEN 1 AND 12 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'travel result must contain 1 to 12 offers';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_canonical_result->'offers') AS offer(value)
     WHERE NULLIF(btrim(offer.value->>'offer_key'), '') IS NULL
        OR COALESCE(jsonb_typeof(offer.value->'total_amount'), '') NOT IN ('number', 'string')
        OR (offer.value->>'total_amount')::numeric <= 0
        OR COALESCE(offer.value->>'total_currency', '') !~ '^[A-Z]{3}$'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'travel offers require a key, price, and ISO currency';
  END IF;

  SELECT run.* INTO v_run FROM public.task_step_tool_runs AS run
   WHERE run.id = p_tool_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'tool run not found'; END IF;
  SELECT provider INTO v_adapter_provider FROM public.tool_adapters WHERE id = v_run.adapter_id;
  IF NULLIF(btrim(p_provider), '') IS NULL OR p_provider IS DISTINCT FROM v_adapter_provider
     OR p_canonical_result->>'provider' IS DISTINCT FROM p_provider THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'tool result provider mismatch';
  END IF;

  -- A completed delivery returns the first durable reference before validating
  -- fresh provider timestamps or attempting another write.
  SELECT id INTO v_result_id FROM public.task_step_tool_results WHERE tool_run_id = p_tool_run_id;
  IF v_result_id IS NOT NULL THEN
    RETURN 'tool-result:' || v_result_id::text;
  END IF;

  IF v_run.status <> 'running' THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'tool run is not running';
  END IF;
  IF p_protected_refs IS NULL OR jsonb_typeof(p_protected_refs) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'protected refs must be an object';
  END IF;
  IF p_expires_at IS DISTINCT FROM (p_canonical_result->>'valid_until')::timestamptz
     OR p_expires_at <= now() OR p_expires_at > now() + interval '1 hour' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid tool result expiry';
  END IF;
  IF p_result_type = 'travel.flight_search.v1' THEN
    PERFORM public.validate_flight_search_result(p_canonical_result);
  END IF;

  INSERT INTO public.task_step_tool_results (
    tool_run_id, task_id, step_id, provider, result_type,
    canonical_result, protected_refs, retrieved_at, expires_at
  ) VALUES (
    p_tool_run_id, v_run.task_id, v_run.step_id, p_provider, p_result_type,
    p_canonical_result, p_protected_refs,
    (p_canonical_result->>'retrieved_at')::timestamptz, p_expires_at
  ) RETURNING id INTO v_result_id;

  UPDATE public.task_step_tool_runs
     SET status = 'completed',
         result_ref = 'tool-result:' || v_result_id::text,
         evidence = jsonb_build_object(
           'schema_version', p_result_type,
           'provider', p_provider,
           'offer_count', jsonb_array_length(p_canonical_result->'offers'),
           'valid_until', p_expires_at
         ),
         completed_at = now()
   WHERE id = p_tool_run_id;

  RETURN 'tool-result:' || v_result_id::text;
END;
$$;

REVOKE ALL ON FUNCTION public.store_travel_search_result(uuid, text, text, jsonb, jsonb, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.store_travel_search_result(uuid, text, text, jsonb, jsonb, timestamptz)
  TO service_role;
