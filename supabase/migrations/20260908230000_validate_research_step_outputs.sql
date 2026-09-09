-- Give research workers a stable, provider-neutral result contract before
-- their output can unlock dependent task steps.

CREATE OR REPLACE FUNCTION public.validate_task_step_output(
  p_step_type text,
  p_output jsonb
)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_recommendation_key text;
BEGIN
  IF p_output IS NULL OR jsonb_typeof(p_output) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'output must be a JSON object';
  END IF;

  -- Other step types retain their existing open output contract. Each new
  -- durable worker type can add a versioned contract here when introduced.
  IF p_step_type <> 'research.travel' THEN
    RETURN;
  END IF;

  IF p_output->>'schema_version' IS DISTINCT FROM 'research.v1' THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'research output schema_version must be research.v1';
  END IF;
  IF NULLIF(btrim(p_output->>'summary'), '') IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'research output summary is required';
  END IF;
  IF jsonb_typeof(p_output->'options') IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_output->'options') = 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'research output options must be a non-empty array';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(p_output->'options') AS item(value)
     WHERE jsonb_typeof(item.value) <> 'object'
        OR NULLIF(btrim(item.value->>'key'), '') IS NULL
        OR NULLIF(btrim(item.value->>'label'), '') IS NULL
        OR NULLIF(btrim(item.value->>'summary'), '') IS NULL
        OR (
          item.value ? 'attributes'
          AND jsonb_typeof(item.value->'attributes') <> 'object'
        )
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'each research option requires key, label, summary, and optional object attributes';
  END IF;
  IF (
    SELECT count(*) <> count(DISTINCT item.value->>'key')
      FROM jsonb_array_elements(p_output->'options') AS item(value)
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'research option keys must be unique';
  END IF;

  IF jsonb_typeof(p_output->'recommendation') IS DISTINCT FROM 'object'
     OR NULLIF(btrim(p_output->'recommendation'->>'option_key'), '') IS NULL
     OR NULLIF(btrim(p_output->'recommendation'->>'rationale'), '') IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'research output recommendation requires option_key and rationale';
  END IF;
  v_recommendation_key := p_output->'recommendation'->>'option_key';
  IF NOT EXISTS (
    SELECT 1
      FROM jsonb_array_elements(p_output->'options') AS item(value)
     WHERE item.value->>'key' = v_recommendation_key
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'research recommendation must reference a declared option';
  END IF;

  IF jsonb_typeof(p_output->'sources') IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_output->'sources') = 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'research output sources must be a non-empty array';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(p_output->'sources') AS source(value)
     WHERE jsonb_typeof(source.value) <> 'object'
        OR NULLIF(btrim(source.value->>'key'), '') IS NULL
        OR NULLIF(btrim(source.value->>'title'), '') IS NULL
        OR NULLIF(btrim(source.value->>'url'), '') IS NULL
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'each research source requires key, title, and url';
  END IF;
  IF (
    SELECT count(*) <> count(DISTINCT source.value->>'key')
      FROM jsonb_array_elements(p_output->'sources') AS source(value)
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'research source keys must be unique';
  END IF;
  IF p_output ? 'constraints'
     AND jsonb_typeof(p_output->'constraints') <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'research output constraints must be an object';
  END IF;
  IF p_output ? 'caveats'
     AND jsonb_typeof(p_output->'caveats') <> 'array' THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'research output caveats must be an array';
  END IF;
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

  PERFORM public.validate_task_step_output(v_step.step_type, p_output);

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

REVOKE ALL ON FUNCTION public.validate_task_step_output(text, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_task_step(uuid, uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.validate_task_step_output(text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_task_step(uuid, uuid, text, jsonb) TO service_role;
