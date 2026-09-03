-- Task creation is atomic and idempotent: the initial task snapshot and its
-- provenance event either both exist or neither exists.

CREATE UNIQUE INDEX task_events_creation_call_id_key
  ON public.task_events (call_id)
  WHERE event_type = 'task.created' AND call_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.create_task(
  p_task_type text,
  p_goal text,
  p_call_id text,
  p_actor text DEFAULT 'create-task',
  p_context jsonb DEFAULT '{}'::jsonb,
  p_priority integer DEFAULT 3
)
RETURNS public.tasks
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_task public.tasks%ROWTYPE;
BEGIN
  IF p_task_type IS NULL OR btrim(p_task_type) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'task_type is required';
  END IF;

  IF p_goal IS NULL OR btrim(p_goal) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'goal is required';
  END IF;

  IF p_call_id IS NULL OR btrim(p_call_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'call_id is required';
  END IF;

  IF p_context IS NULL OR jsonb_typeof(p_context) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'context must be a JSON object';
  END IF;

  IF p_priority IS NULL OR p_priority NOT BETWEEN 1 AND 5 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'priority must be between 1 and 5';
  END IF;

  SELECT task.* INTO v_task
    FROM public.task_events AS event
    JOIN public.tasks AS task ON task.id = event.task_id
   WHERE event.event_type = 'task.created'
     AND event.call_id = btrim(p_call_id);

  IF FOUND THEN
    RETURN v_task;
  END IF;

  BEGIN
    INSERT INTO public.tasks (task_type, goal, context, priority)
    VALUES (btrim(p_task_type), btrim(p_goal), p_context, p_priority)
    RETURNING * INTO v_task;

    INSERT INTO public.task_events (
      task_id, event_type, actor, call_id, outcome, extracted_data
    ) VALUES (
      v_task.id,
      'task.created',
      NULLIF(btrim(p_actor), ''),
      btrim(p_call_id),
      'created',
      jsonb_build_object(
        'task_type', v_task.task_type,
        'goal', v_task.goal,
        'priority', v_task.priority
      )
    );
  EXCEPTION WHEN unique_violation THEN
    -- A concurrent request with the same call ID won the race. The sub-block
    -- rolled back this request's insert, so return the winner.
    SELECT task.* INTO v_task
      FROM public.task_events AS event
      JOIN public.tasks AS task ON task.id = event.task_id
     WHERE event.event_type = 'task.created'
       AND event.call_id = btrim(p_call_id);

    IF NOT FOUND THEN
      RAISE;
    END IF;
  END;

  RETURN v_task;
END;
$$;

REVOKE ALL ON FUNCTION public.create_task(text, text, text, text, jsonb, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_task(text, text, text, text, jsonb, integer)
  TO service_role;
