-- Extend protected tool results to canonical hotel and car discovery packets.

ALTER TABLE public.task_step_tool_results
  DROP CONSTRAINT task_step_tool_results_type_check;
ALTER TABLE public.task_step_tool_results
  ADD CONSTRAINT task_step_tool_results_type_check CHECK (result_type IN (
    'travel.flight_search.v1', 'travel.hotel_search.v1', 'travel.car_search.v1'
  ));

CREATE OR REPLACE FUNCTION public.store_travel_search_result(
  p_tool_run_id uuid,
  p_provider text,
  p_result_type text,
  p_canonical_result jsonb,
  p_protected_refs jsonb,
  p_expires_at timestamptz
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
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'tool run not found';
  END IF;
  SELECT provider INTO v_adapter_provider FROM public.tool_adapters WHERE id = v_run.adapter_id;
  IF v_run.status <> 'running' THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'tool run is not running';
  END IF;
  IF NULLIF(btrim(p_provider), '') IS NULL OR p_provider IS DISTINCT FROM v_adapter_provider
     OR p_canonical_result->>'provider' IS DISTINCT FROM p_provider THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'tool result provider mismatch';
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

  SELECT id INTO v_result_id FROM public.task_step_tool_results WHERE tool_run_id = p_tool_run_id;
  IF v_result_id IS NULL THEN
    INSERT INTO public.task_step_tool_results (
      tool_run_id, task_id, step_id, provider, result_type,
      canonical_result, protected_refs, retrieved_at, expires_at
    ) VALUES (
      p_tool_run_id, v_run.task_id, v_run.step_id, p_provider, p_result_type,
      p_canonical_result, p_protected_refs,
      (p_canonical_result->>'retrieved_at')::timestamptz, p_expires_at
    ) RETURNING id INTO v_result_id;
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM public.task_step_tool_results
       WHERE id = v_result_id AND result_type = p_result_type
         AND canonical_result = p_canonical_result AND protected_refs = p_protected_refs
    ) THEN
      RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'tool run already has a different result';
    END IF;
  END IF;

  UPDATE public.task_step_tool_runs SET result_ref = 'tool-result:' || v_result_id::text
   WHERE id = p_tool_run_id;
  RETURN 'tool-result:' || v_result_id::text;
END;
$$;

REVOKE ALL ON FUNCTION public.store_travel_search_result(uuid, text, text, jsonb, jsonb, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.store_travel_search_result(uuid, text, text, jsonb, jsonb, timestamptz)
  TO service_role;

CREATE OR REPLACE FUNCTION public.store_flight_search_result(
  p_tool_run_id uuid,
  p_provider text,
  p_canonical_result jsonb,
  p_protected_refs jsonb,
  p_expires_at timestamptz
)
RETURNS text
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  SELECT public.store_travel_search_result(
    p_tool_run_id, p_provider, 'travel.flight_search.v1',
    p_canonical_result, p_protected_refs, p_expires_at
  );
$$;
