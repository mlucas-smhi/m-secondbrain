DROP FUNCTION public.claim_task_step(text, integer);

CREATE FUNCTION public.claim_task_step(
  p_worker_id text,
  p_lease_seconds integer DEFAULT 300,
  p_step_types text[] DEFAULT NULL
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
  IF p_step_types IS NOT NULL AND (
    cardinality(p_step_types) = 0 OR EXISTS (
      SELECT 1 FROM unnest(p_step_types) AS step_type
       WHERE step_type IS NULL OR btrim(step_type) = ''
    )
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'step_types must contain non-empty values';
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
     AND (p_step_types IS NULL OR step.step_type = ANY (p_step_types))
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
      'lease_expires_at', v_step.lease_expires_at,
      'worker_step_types', to_jsonb(p_step_types)
    )
  );

  RETURN NEXT v_step;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_task_step(text, integer, text[])
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_task_step(text, integer, text[])
  TO service_role;
