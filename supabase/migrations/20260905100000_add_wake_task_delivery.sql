-- Give integration callers an atomic indication of whether a wake was newly
-- applied or was an idempotent replay. Downstream side effects must only run
-- when replayed is false.

CREATE OR REPLACE FUNCTION public.wake_task_delivery(
  p_task_id uuid,
  p_trigger_type text,
  p_call_id text,
  p_data jsonb DEFAULT '{}'::jsonb,
  p_actor text DEFAULT 'wake-task'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_task public.tasks%ROWTYPE;
  v_replayed boolean;
BEGIN
  IF p_call_id IS NULL OR btrim(p_call_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'call_id is required';
  END IF;

  -- Serialize the replay check with the wake transition. A concurrent delivery
  -- with the same call ID waits here, then observes the event created by the
  -- first delivery.
  SELECT * INTO v_task
    FROM public.tasks
   WHERE id = p_task_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'task not found';
  END IF;

  SELECT EXISTS (
    SELECT 1
      FROM public.task_events
     WHERE task_id = p_task_id
       AND call_id = btrim(p_call_id)
  ) INTO v_replayed;

  IF NOT v_replayed THEN
    SELECT * INTO v_task
      FROM public.wake_task(
        p_task_id,
        p_trigger_type,
        btrim(p_call_id),
        p_data,
        p_actor
      );
  END IF;

  RETURN jsonb_build_object(
    'task', to_jsonb(v_task),
    'replayed', v_replayed
  );
END;
$$;

-- Keep the incident circuit breaker closed. The restoration migration will
-- grant this wrapper and its contained dependencies only to service_role.
REVOKE ALL ON FUNCTION public.wake_task_delivery(uuid, text, text, jsonb, text)
  FROM PUBLIC, anon, authenticated, service_role;
