CREATE OR REPLACE FUNCTION public.fail_task_step(
  p_step_id uuid,
  p_claim_token uuid,
  p_idempotency_key text,
  p_error text,
  p_retry_delay_seconds integer DEFAULT 60
)
RETURNS public.task_steps
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_step public.task_steps%ROWTYPE;
  v_next_status text;
  v_event_type text;
BEGIN
  IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'idempotency_key is required';
  END IF;
  IF p_error IS NULL OR btrim(p_error) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'error is required';
  END IF;
  IF p_retry_delay_seconds IS NULL OR p_retry_delay_seconds < 0
     OR p_retry_delay_seconds > 86400 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'retry_delay_seconds must be between 0 and 86400';
  END IF;

  SELECT step.* INTO v_step
    FROM public.task_steps AS step
   WHERE step.id = p_step_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'task step not found';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.task_step_events
     WHERE step_id = p_step_id AND idempotency_key = btrim(p_idempotency_key)
  ) THEN
    RETURN v_step;
  END IF;

  IF v_step.status <> 'running' OR v_step.claim_token IS DISTINCT FROM p_claim_token THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'task step claim is stale';
  END IF;
  IF v_step.lease_expires_at <= now() THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'task step lease expired';
  END IF;

  IF v_step.attempt_count < v_step.max_attempts THEN
    v_next_status := 'ready';
    v_event_type := 'step.retry_scheduled';
  ELSE
    v_next_status := 'failed';
    v_event_type := 'step.failed';
  END IF;

  UPDATE public.task_steps
     SET status = v_next_status,
         available_at = CASE
           WHEN v_next_status = 'ready'
             THEN now() + make_interval(secs => p_retry_delay_seconds)
           ELSE available_at
         END,
         claim_token = NULL,
         claimed_by = NULL,
         claimed_at = NULL,
         lease_expires_at = NULL,
         last_error = btrim(p_error)
   WHERE id = p_step_id
   RETURNING * INTO v_step;

  INSERT INTO public.task_step_events (
    task_id, step_id, event_type, actor, idempotency_key, data
  ) VALUES (
    v_step.task_id, v_step.id, v_event_type, 'task-step-worker',
    btrim(p_idempotency_key),
    jsonb_build_object(
      'error', btrim(p_error),
      'attempt_count', v_step.attempt_count,
      'max_attempts', v_step.max_attempts,
      'retry_delay_seconds', p_retry_delay_seconds
    )
  );

  RETURN v_step;
END;
$$;

REVOKE ALL ON FUNCTION public.fail_task_step(uuid, uuid, text, text, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_task_step(uuid, uuid, text, text, integer)
  TO service_role;
