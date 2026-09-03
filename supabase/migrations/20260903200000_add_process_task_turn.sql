-- Execute a complete deterministic turn in one database transaction. Both the
-- start event and final decision commit together, or neither does.

CREATE OR REPLACE FUNCTION public.process_task_turn(
  p_task_id uuid,
  p_call_id text,
  p_expected_status text,
  p_outcome text,
  p_actor text DEFAULT 'process-task',
  p_question text DEFAULT NULL,
  p_resume_condition text DEFAULT NULL,
  p_result text DEFAULT NULL
)
RETURNS public.tasks
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_task public.tasks%ROWTYPE;
  v_started_event_id uuid;
BEGIN
  IF p_call_id IS NULL OR btrim(p_call_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'call_id is required';
  END IF;

  IF p_expected_status NOT IN ('new', 'ready') THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'expected_status must be new or ready';
  END IF;

  IF p_outcome NOT IN ('waiting_user', 'completed') THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'outcome must be waiting_user or completed';
  END IF;

  IF p_outcome = 'waiting_user' AND (p_question IS NULL OR btrim(p_question) = '') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'question is required';
  END IF;

  IF p_outcome = 'waiting_user'
     AND (p_resume_condition IS NULL OR btrim(p_resume_condition) = '') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'resume_condition is required';
  END IF;

  IF p_outcome = 'completed' AND (p_result IS NULL OR btrim(p_result) = '') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'result is required';
  END IF;

  SELECT * INTO v_task
    FROM public.advance_task(
      p_task_id => p_task_id,
      p_event_type => 'turn.started',
      p_actor => NULLIF(btrim(p_actor), ''),
      p_call_id => btrim(p_call_id) || ':started',
      p_expected_status => p_expected_status,
      p_patch => '{"status":"running","current_step":"process-task"}'::jsonb
    );

  SELECT id INTO v_started_event_id
    FROM public.task_events
   WHERE task_id = p_task_id
     AND call_id = btrim(p_call_id) || ':started';

  IF p_outcome = 'waiting_user' THEN
    SELECT * INTO v_task
      FROM public.advance_task(
        p_task_id => p_task_id,
        p_event_type => 'turn.waiting_for_user',
        p_actor => NULLIF(btrim(p_actor), ''),
        p_call_id => btrim(p_call_id) || ':decision',
        p_expected_status => 'running',
        p_patch => jsonb_build_object(
          'status', 'waiting_user',
          'current_step', 'wait-for-user',
          'next_action', 'Await user response',
          'waiting_for', 'user',
          'pending_question', btrim(p_question),
          'resume_condition', btrim(p_resume_condition)
        ),
        p_outcome => 'needs_input',
        p_parent_event_id => v_started_event_id
      );
  ELSE
    SELECT * INTO v_task
      FROM public.advance_task(
        p_task_id => p_task_id,
        p_event_type => 'turn.completed',
        p_actor => NULLIF(btrim(p_actor), ''),
        p_call_id => btrim(p_call_id) || ':decision',
        p_expected_status => 'running',
        p_patch => '{
          "status":"completed",
          "current_step":"completed",
          "next_action":null,
          "waiting_for":null,
          "pending_question":null,
          "resume_condition":null,
          "next_action_at":null
        }'::jsonb,
        p_outcome => 'completed',
        p_extracted_data => jsonb_build_object('result', btrim(p_result)),
        p_parent_event_id => v_started_event_id
      );
  END IF;

  RETURN v_task;
END;
$$;

REVOKE ALL ON FUNCTION public.process_task_turn(uuid, text, text, text, text, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_task_turn(uuid, text, text, text, text, text, text, text)
  TO service_role;
