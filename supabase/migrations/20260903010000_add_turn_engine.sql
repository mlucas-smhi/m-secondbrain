-- The turn engine is the only supported write path for task progress. It locks
-- the task, validates the transition, updates the snapshot, and appends the
-- corresponding event in one transaction.

ALTER TABLE public.tasks
  ADD CONSTRAINT tasks_status_check CHECK (
    status IN (
      'new', 'ready', 'running', 'waiting_user', 'waiting_external',
      'retry_scheduled', 'completed', 'failed', 'cancelled'
    )
  ),
  ADD CONSTRAINT tasks_priority_check CHECK (priority BETWEEN 1 AND 5),
  ADD CONSTRAINT tasks_retry_count_check CHECK (retry_count >= 0),
  ADD CONSTRAINT tasks_completion_check CHECK (
    (status = 'completed' AND completed_at IS NOT NULL)
    OR (status <> 'completed' AND completed_at IS NULL)
  );

CREATE UNIQUE INDEX task_events_task_call_id_key
  ON public.task_events (task_id, call_id)
  WHERE call_id IS NOT NULL;

CREATE INDEX tasks_runnable_idx
  ON public.tasks (priority, next_action_at, created_at)
  WHERE status IN ('new', 'ready', 'retry_scheduled');

CREATE INDEX task_events_task_created_idx
  ON public.task_events (task_id, created_at, id);

CREATE OR REPLACE FUNCTION public.advance_task(
  p_task_id uuid,
  p_event_type text,
  p_actor text DEFAULT NULL,
  p_call_id text DEFAULT NULL,
  p_expected_status text DEFAULT NULL,
  p_patch jsonb DEFAULT '{}'::jsonb,
  p_outcome text DEFAULT NULL,
  p_extracted_data jsonb DEFAULT '{}'::jsonb,
  p_parent_event_id uuid DEFAULT NULL
)
RETURNS public.tasks
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_task public.tasks%ROWTYPE;
  v_existing_task_id uuid;
  v_new_status text;
  v_allowed_patch_keys constant text[] := ARRAY[
    'status', 'current_step', 'next_action', 'waiting_for',
    'pending_question', 'resume_condition', 'context', 'priority',
    'retry_count', 'next_action_at', 'last_contact_attempt'
  ];
  v_unknown_key text;
BEGIN
  IF p_event_type IS NULL OR btrim(p_event_type) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'event_type is required';
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'patch must be a JSON object';
  END IF;

  IF p_extracted_data IS NULL OR jsonb_typeof(p_extracted_data) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'extracted_data must be a JSON object';
  END IF;

  IF p_patch ? 'context'
     AND (p_patch->'context' IS NULL OR jsonb_typeof(p_patch->'context') <> 'object') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'context must be a JSON object';
  END IF;

  SELECT key
    INTO v_unknown_key
    FROM jsonb_object_keys(p_patch) AS patch_key(key)
   WHERE NOT (key = ANY (v_allowed_patch_keys))
   LIMIT 1;

  IF v_unknown_key IS NOT NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = format('unsupported task patch field: %s', v_unknown_key);
  END IF;

  SELECT * INTO v_task
    FROM public.tasks
   WHERE id = p_task_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'task not found';
  END IF;

  -- A repeated provider/tool call returns the already-produced task state.
  IF p_call_id IS NOT NULL THEN
    SELECT task_id INTO v_existing_task_id
      FROM public.task_events
     WHERE task_id = p_task_id AND call_id = p_call_id;

    IF FOUND THEN
      RETURN v_task;
    END IF;
  END IF;

  IF p_expected_status IS NOT NULL AND v_task.status <> p_expected_status THEN
    RAISE EXCEPTION USING
      ERRCODE = '40001',
      MESSAGE = format(
        'stale task state: expected %s, found %s',
        p_expected_status,
        v_task.status
      );
  END IF;

  IF p_parent_event_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
      FROM public.task_events
     WHERE id = p_parent_event_id
       AND task_id = p_task_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'parent event must belong to the same task';
  END IF;

  v_new_status := COALESCE(p_patch->>'status', v_task.status);

  IF v_new_status <> v_task.status AND NOT (
    CASE v_task.status
      WHEN 'new' THEN v_new_status IN ('ready', 'running', 'cancelled', 'failed')
      WHEN 'ready' THEN v_new_status IN ('running', 'cancelled', 'failed')
      WHEN 'running' THEN v_new_status IN (
        'ready', 'waiting_user', 'waiting_external', 'retry_scheduled',
        'completed', 'failed', 'cancelled'
      )
      WHEN 'waiting_user' THEN v_new_status IN ('ready', 'running', 'cancelled', 'failed')
      WHEN 'waiting_external' THEN v_new_status IN (
        'ready', 'running', 'retry_scheduled', 'cancelled', 'failed'
      )
      WHEN 'retry_scheduled' THEN v_new_status IN ('ready', 'running', 'cancelled', 'failed')
      ELSE false
    END
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = format('invalid task transition: %s -> %s', v_task.status, v_new_status);
  END IF;

  UPDATE public.tasks
     SET status = v_new_status,
         current_step = CASE WHEN p_patch ? 'current_step' THEN p_patch->>'current_step' ELSE current_step END,
         next_action = CASE WHEN p_patch ? 'next_action' THEN p_patch->>'next_action' ELSE next_action END,
         waiting_for = CASE WHEN p_patch ? 'waiting_for' THEN p_patch->>'waiting_for' ELSE waiting_for END,
         pending_question = CASE WHEN p_patch ? 'pending_question' THEN p_patch->>'pending_question' ELSE pending_question END,
         resume_condition = CASE WHEN p_patch ? 'resume_condition' THEN p_patch->>'resume_condition' ELSE resume_condition END,
         context = CASE WHEN p_patch ? 'context' THEN p_patch->'context' ELSE context END,
         priority = CASE WHEN p_patch ? 'priority' THEN (p_patch->>'priority')::integer ELSE priority END,
         retry_count = CASE WHEN p_patch ? 'retry_count' THEN (p_patch->>'retry_count')::integer ELSE retry_count END,
         next_action_at = CASE WHEN p_patch ? 'next_action_at' THEN (p_patch->>'next_action_at')::timestamptz ELSE next_action_at END,
         last_contact_attempt = CASE WHEN p_patch ? 'last_contact_attempt' THEN (p_patch->>'last_contact_attempt')::timestamptz ELSE last_contact_attempt END,
         completed_at = CASE
           WHEN v_new_status = 'completed' AND status <> 'completed' THEN now()
           WHEN v_new_status <> 'completed' THEN NULL
           ELSE completed_at
         END
   WHERE id = p_task_id
   RETURNING * INTO v_task;

  INSERT INTO public.task_events (
    task_id, event_type, actor, call_id, parent_event_id, outcome, extracted_data
  ) VALUES (
    p_task_id, p_event_type, p_actor, p_call_id, p_parent_event_id,
    p_outcome, p_extracted_data
  );

  RETURN v_task;
END;
$$;

REVOKE ALL ON FUNCTION public.advance_task(uuid, text, text, text, text, jsonb, text, jsonb, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.advance_task(uuid, text, text, text, text, jsonb, text, jsonb, uuid)
  TO service_role;
