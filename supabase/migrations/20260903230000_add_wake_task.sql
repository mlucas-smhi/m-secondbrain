-- Resume a paused task from one universal, idempotent trigger contract.

CREATE OR REPLACE FUNCTION public.wake_task(
  p_task_id uuid,
  p_trigger_type text,
  p_call_id text,
  p_data jsonb DEFAULT '{}'::jsonb,
  p_actor text DEFAULT 'wake-task'
)
RETURNS public.tasks
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_task public.tasks%ROWTYPE;
  v_expected_status text;
  v_event_type text;
  v_existing_task_id uuid;
BEGIN
  IF p_call_id IS NULL OR btrim(p_call_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'call_id is required';
  END IF;

  IF p_trigger_type NOT IN ('user_response', 'external_event', 'scheduled_time') THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'trigger_type must be user_response, external_event, or scheduled_time';
  END IF;

  IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'data must be a JSON object';
  END IF;

  SELECT * INTO v_task FROM public.tasks WHERE id = p_task_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'task not found';
  END IF;

  SELECT task_id INTO v_existing_task_id
    FROM public.task_events
   WHERE task_id = p_task_id AND call_id = btrim(p_call_id);
  IF FOUND THEN
    RETURN v_task;
  END IF;

  CASE p_trigger_type
    WHEN 'user_response' THEN
      v_expected_status := 'waiting_user';
      v_event_type := 'user.responded';
    WHEN 'external_event' THEN
      v_expected_status := 'waiting_external';
      v_event_type := 'external.received';
    WHEN 'scheduled_time' THEN
      v_expected_status := 'retry_scheduled';
      v_event_type := 'timer.elapsed';
  END CASE;

  IF v_task.status <> v_expected_status THEN
    RAISE EXCEPTION USING
      ERRCODE = '40001',
      MESSAGE = format('trigger %s cannot wake task in status %s', p_trigger_type, v_task.status);
  END IF;

  IF p_trigger_type = 'scheduled_time'
     AND v_task.next_action_at IS NOT NULL
     AND v_task.next_action_at > now() THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'scheduled task is not due';
  END IF;

  SELECT * INTO v_task
    FROM public.advance_task(
      p_task_id => p_task_id,
      p_event_type => v_event_type,
      p_actor => NULLIF(btrim(p_actor), ''),
      p_call_id => btrim(p_call_id),
      p_expected_status => v_expected_status,
      p_patch => '{
        "status":"ready",
        "current_step":"trigger-received",
        "next_action":"Continue task",
        "waiting_for":null,
        "pending_question":null,
        "resume_condition":null,
        "next_action_at":null
      }'::jsonb,
      p_outcome => 'resumed',
      p_extracted_data => p_data
    );

  RETURN v_task;
END;
$$;

REVOKE ALL ON FUNCTION public.wake_task(uuid, text, text, jsonb, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.wake_task(uuid, text, text, jsonb, text)
  TO service_role;
