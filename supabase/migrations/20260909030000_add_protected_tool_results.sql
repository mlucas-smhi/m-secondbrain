-- Keep provider execution handles out of agent-facing evidence while retaining
-- a durable, short-lived reference for a later explicitly authorized action.

CREATE TABLE public.task_step_tool_results (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tool_run_id uuid NOT NULL UNIQUE
    REFERENCES public.task_step_tool_runs(id) ON DELETE CASCADE,
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  step_id uuid NOT NULL,
  provider text NOT NULL,
  result_type text NOT NULL,
  canonical_result jsonb NOT NULL,
  protected_refs jsonb NOT NULL,
  retrieved_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (step_id, task_id)
    REFERENCES public.task_steps(id, task_id) ON DELETE CASCADE,
  CONSTRAINT task_step_tool_results_provider_check CHECK (btrim(provider) <> ''),
  CONSTRAINT task_step_tool_results_type_check CHECK (result_type = 'travel.flight_search.v1'),
  CONSTRAINT task_step_tool_results_canonical_check CHECK (jsonb_typeof(canonical_result) = 'object'),
  CONSTRAINT task_step_tool_results_refs_check CHECK (jsonb_typeof(protected_refs) = 'object'),
  CONSTRAINT task_step_tool_results_expiry_check CHECK (expires_at > retrieved_at)
);

CREATE INDEX task_step_tool_results_expiry_idx
  ON public.task_step_tool_results (expires_at);

ALTER TABLE public.task_step_tool_results ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_step_tool_results FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON TABLE public.task_step_tool_results TO service_role;

CREATE OR REPLACE FUNCTION public.validate_flight_search_result(p_result jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_result IS NULL OR jsonb_typeof(p_result) <> 'object'
     OR p_result->>'schema_version' IS DISTINCT FROM 'travel.flight_search.v1' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid flight search result schema';
  END IF;
  IF NULLIF(btrim(p_result->>'provider'), '') IS NULL
     OR (p_result->>'retrieved_at')::timestamptz IS NULL
     OR (p_result->>'valid_until')::timestamptz IS NULL
     OR (p_result->>'valid_until')::timestamptz <= (p_result->>'retrieved_at')::timestamptz THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'flight search provenance and validity are required';
  END IF;
  IF jsonb_typeof(p_result->'offers') IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_result->'offers') NOT BETWEEN 1 AND 12 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'flight search must contain 1 to 12 offers';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_result->'offers') AS offer(value)
     WHERE NULLIF(btrim(offer.value->>'offer_key'), '') IS NULL
        OR COALESCE(jsonb_typeof(offer.value->'total_amount'), '') NOT IN ('number', 'string')
        OR (offer.value->>'total_amount')::numeric <= 0
        OR COALESCE(offer.value->>'total_currency', '') !~ '^[A-Z]{3}$'
        OR jsonb_typeof(offer.value->'segments') IS DISTINCT FROM 'array'
        OR jsonb_array_length(offer.value->'segments') = 0
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'flight offers require price, ISO currency, and segments';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(p_result->'offers') AS offer(value),
           jsonb_array_elements(offer.value->'segments') AS segment(value)
     WHERE COALESCE(segment.value->>'origin', '') !~ '^[A-Z]{3}$'
        OR COALESCE(segment.value->>'destination', '') !~ '^[A-Z]{3}$'
        OR NULLIF(segment.value->>'departing_at', '') IS NULL
        OR NULLIF(segment.value->>'arriving_at', '') IS NULL
        OR (segment.value->>'departing_at')::timestamptz >= (segment.value->>'arriving_at')::timestamptz
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'flight offer segments are malformed';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.store_flight_search_result(
  p_tool_run_id uuid,
  p_provider text,
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
  SELECT run.* INTO v_run
    FROM public.task_step_tool_runs AS run
   WHERE run.id = p_tool_run_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'tool run not found';
  END IF;
  SELECT provider INTO v_adapter_provider
    FROM public.tool_adapters WHERE id = v_run.adapter_id;
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
  PERFORM public.validate_flight_search_result(p_canonical_result);
  IF p_expires_at IS DISTINCT FROM (p_canonical_result->>'valid_until')::timestamptz
     OR p_expires_at <= now() OR p_expires_at > now() + interval '1 hour' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid tool result expiry';
  END IF;

  SELECT id INTO v_result_id
    FROM public.task_step_tool_results WHERE tool_run_id = p_tool_run_id;
  IF v_result_id IS NULL THEN
    INSERT INTO public.task_step_tool_results (
      tool_run_id, task_id, step_id, provider, result_type,
      canonical_result, protected_refs, retrieved_at, expires_at
    ) VALUES (
      p_tool_run_id, v_run.task_id, v_run.step_id, p_provider,
      'travel.flight_search.v1', p_canonical_result, p_protected_refs,
      (p_canonical_result->>'retrieved_at')::timestamptz, p_expires_at
    ) RETURNING id INTO v_result_id;
  END IF;

  UPDATE public.task_step_tool_runs
     SET result_ref = 'tool-result:' || v_result_id::text
   WHERE id = p_tool_run_id;
  RETURN 'tool-result:' || v_result_id::text;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_flight_search_result(jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.store_flight_search_result(uuid, text, jsonb, jsonb, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.validate_flight_search_result(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.store_flight_search_result(uuid, text, jsonb, jsonb, timestamptz)
  TO service_role;
