CREATE UNIQUE INDEX task_events_plan_call_id_key
  ON public.task_events (call_id)
  WHERE event_type = 'task.planned' AND call_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.task_plan_snapshot(p_task_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'thread', to_jsonb(thread),
    'task', to_jsonb(task),
    'steps', COALESCE((SELECT jsonb_agg(to_jsonb(step) ORDER BY step.created_at, step.id)
      FROM public.task_steps AS step WHERE step.task_id = task.id), '[]'::jsonb),
    'decisions', COALESCE((SELECT jsonb_agg(to_jsonb(decision) ORDER BY decision.created_at, decision.id)
      FROM public.task_decisions AS decision WHERE decision.task_id = task.id), '[]'::jsonb)
  )
  FROM public.tasks AS task
  JOIN public.threads AS thread ON thread.id = task.thread_id
  WHERE task.id = p_task_id;
$$;

CREATE OR REPLACE FUNCTION public.create_task_plan(
  p_plan jsonb,
  p_call_id text,
  p_actor text DEFAULT 'task-planner'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_thread public.threads%ROWTYPE;
  v_task public.tasks%ROWTYPE;
  v_item jsonb;
  v_option jsonb;
  v_step_id uuid;
  v_depends_on_id uuid;
  v_gate_id uuid;
  v_decision_id uuid;
  v_existing_task_id uuid;
  v_roles text[];
BEGIN
  IF p_call_id IS NULL OR btrim(p_call_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'call_id is required';
  END IF;

  SELECT event.task_id INTO v_existing_task_id
    FROM public.task_events AS event
   WHERE event.event_type = 'task.planned' AND event.call_id = btrim(p_call_id);
  IF FOUND THEN
    RETURN public.task_plan_snapshot(v_existing_task_id);
  END IF;

  IF p_plan IS NULL OR jsonb_typeof(p_plan) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'plan must be a JSON object';
  END IF;
  IF jsonb_typeof(p_plan->'thread') <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'thread must be a JSON object';
  END IF;
  IF jsonb_typeof(p_plan->'task') <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'task must be a JSON object';
  END IF;
  IF jsonb_typeof(p_plan->'steps') <> 'array' OR jsonb_array_length(p_plan->'steps') = 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'steps must be a non-empty JSON array';
  END IF;
  IF jsonb_typeof(COALESCE(p_plan->'dependencies', '[]'::jsonb)) <> 'array'
     OR jsonb_typeof(COALESCE(p_plan->'decisions', '[]'::jsonb)) <> 'array'
     OR jsonb_typeof(COALESCE(p_plan->'participants', '[]'::jsonb)) <> 'array'
     OR jsonb_typeof(COALESCE(p_plan->'closure_recipients', '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'plan collections must be JSON arrays';
  END IF;

  BEGIN
    INSERT INTO public.threads (
      workspace_id, subject, desired_outcome, status, current_owner_ref,
      next_action, deadline
    ) VALUES (
      COALESCE(NULLIF(p_plan->'thread'->>'workspace_id', '')::uuid,
        '00000000-0000-4000-8000-000000000001'::uuid),
      btrim(p_plan->'thread'->>'subject'),
      btrim(p_plan->'thread'->>'desired_outcome'),
      'active',
      NULLIF(btrim(p_plan->'thread'->>'owner_ref'), ''),
      NULLIF(btrim(p_plan->'thread'->>'next_action'), ''),
      NULLIF(p_plan->'thread'->>'deadline', '')::timestamptz
    ) RETURNING * INTO v_thread;

    INSERT INTO public.tasks (
      thread_id, task_type, goal, status, context, priority
    ) VALUES (
      v_thread.id,
      btrim(p_plan->'task'->>'task_type'),
      btrim(p_plan->'task'->>'goal'),
      'ready',
      COALESCE(p_plan->'task'->'context', '{}'::jsonb),
      COALESCE((p_plan->'task'->>'priority')::integer, 3)
    ) RETURNING * INTO v_task;

    FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(p_plan->'participants', '[]'::jsonb))
    LOOP
      IF jsonb_typeof(v_item) <> 'object' OR jsonb_typeof(COALESCE(v_item->'roles', '[]'::jsonb)) <> 'array' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'participant must contain a roles array';
      END IF;
      SELECT COALESCE(array_agg(value), '{}'::text[]) INTO v_roles
        FROM jsonb_array_elements_text(COALESCE(v_item->'roles', '[]'::jsonb));
      INSERT INTO public.thread_participants (
        thread_id, actor_type, actor_ref, identity_confidence, roles
      ) VALUES (
        v_thread.id, btrim(v_item->>'actor_type'), btrim(v_item->>'actor_ref'),
        COALESCE(NULLIF(btrim(v_item->>'identity_confidence'), ''), 'unverified'), v_roles
      );
    END LOOP;

    FOR v_item IN SELECT value FROM jsonb_array_elements(p_plan->'steps')
    LOOP
      IF jsonb_typeof(v_item) <> 'object' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'step must be a JSON object';
      END IF;
      INSERT INTO public.task_steps (
        task_id, step_key, step_type, status, input, priority, available_at,
        max_attempts, idempotency_key
      ) VALUES (
        v_task.id, btrim(v_item->>'key'), btrim(v_item->>'type'), 'pending',
        COALESCE(v_item->'input', '{}'::jsonb),
        COALESCE((v_item->>'priority')::integer, v_task.priority),
        COALESCE(NULLIF(v_item->>'available_at', '')::timestamptz, now()),
        COALESCE((v_item->>'max_attempts')::integer, 3),
        COALESCE(NULLIF(btrim(v_item->>'idempotency_key'), ''),
          btrim(p_call_id) || ':step:' || btrim(v_item->>'key'))
      );
    END LOOP;

    FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(p_plan->'dependencies', '[]'::jsonb))
    LOOP
      SELECT id INTO v_step_id FROM public.task_steps
       WHERE task_id = v_task.id AND step_key = btrim(v_item->>'step_key');
      SELECT id INTO v_depends_on_id FROM public.task_steps
       WHERE task_id = v_task.id AND step_key = btrim(v_item->>'depends_on_step_key');
      IF v_step_id IS NULL OR v_depends_on_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'dependency references an unknown step';
      END IF;
      INSERT INTO public.task_step_dependencies (task_id, step_id, depends_on_step_id)
      VALUES (v_task.id, v_step_id, v_depends_on_id);
    END LOOP;

    FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(p_plan->'decisions', '[]'::jsonb))
    LOOP
      IF jsonb_typeof(COALESCE(v_item->'options', '[]'::jsonb)) <> 'array'
         OR jsonb_array_length(COALESCE(v_item->'options', '[]'::jsonb)) = 0
         OR jsonb_typeof(COALESCE(v_item->'blocks', '[]'::jsonb)) <> 'array'
         OR jsonb_array_length(COALESCE(v_item->'blocks', '[]'::jsonb)) = 0 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'decision requires options and blocked steps';
      END IF;
      INSERT INTO public.task_gates (task_id, gate_key, gate_type, condition, deadline)
      VALUES (
        v_task.id, btrim(v_item->>'key'), 'decision',
        jsonb_build_object('question', v_item->>'question'),
        NULLIF(v_item->>'deadline', '')::timestamptz
      ) RETURNING id INTO v_gate_id;
      INSERT INTO public.task_decisions (
        task_id, gate_id, title, owner_ref, requested_by_ref, question,
        preference_dimension, recommendation_key, deadline
      ) VALUES (
        v_task.id, v_gate_id, btrim(v_item->>'title'), btrim(v_item->>'owner_ref'),
        btrim(v_item->>'requested_by_ref'), btrim(v_item->>'question'),
        NULLIF(btrim(v_item->>'preference_dimension'), ''),
        NULLIF(btrim(v_item->>'recommendation_key'), ''),
        NULLIF(v_item->>'deadline', '')::timestamptz
      ) RETURNING id INTO v_decision_id;
      FOR v_option IN SELECT value FROM jsonb_array_elements(v_item->'options')
      LOOP
        INSERT INTO public.task_decision_options (
          decision_id, option_key, label, tradeoffs, rank
        ) VALUES (
          v_decision_id, btrim(v_option->>'key'), btrim(v_option->>'label'),
          COALESCE(v_option->'tradeoffs', '{}'::jsonb),
          NULLIF(v_option->>'rank', '')::integer
        );
      END LOOP;
      FOR v_option IN SELECT value FROM jsonb_array_elements(v_item->'blocks')
      LOOP
        SELECT id INTO v_step_id FROM public.task_steps
         WHERE task_id = v_task.id AND step_key = v_option #>> '{}';
        IF v_step_id IS NULL THEN
          RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'decision references an unknown blocked step';
        END IF;
        INSERT INTO public.task_step_gates (task_id, step_id, gate_id)
        VALUES (v_task.id, v_step_id, v_gate_id);
      END LOOP;
    END LOOP;

    FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(p_plan->'closure_recipients', '[]'::jsonb))
    LOOP
      INSERT INTO public.task_closure_recipients (
        task_id, recipient_ref, channel, delivery_policy, channel_config
      ) VALUES (
        v_task.id, btrim(v_item->>'recipient_ref'), btrim(v_item->>'channel'),
        COALESCE(NULLIF(btrim(v_item->>'delivery_policy'), ''), 'on_terminal'),
        COALESCE(v_item->'channel_config', '{}'::jsonb)
      );
    END LOOP;

    INSERT INTO public.task_events (
      task_id, event_type, actor, call_id, outcome, extracted_data
    ) VALUES (
      v_task.id, 'task.planned', NULLIF(btrim(p_actor), ''), btrim(p_call_id),
      'planned', jsonb_build_object('thread_id', v_thread.id)
    );
  EXCEPTION WHEN unique_violation THEN
    SELECT event.task_id INTO v_existing_task_id
      FROM public.task_events AS event
     WHERE event.event_type = 'task.planned' AND event.call_id = btrim(p_call_id);
    IF NOT FOUND THEN RAISE; END IF;
    RETURN public.task_plan_snapshot(v_existing_task_id);
  END;

  RETURN public.task_plan_snapshot(v_task.id);
END;
$$;

REVOKE ALL ON FUNCTION public.task_plan_snapshot(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_task_plan(jsonb, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.task_plan_snapshot(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.create_task_plan(jsonb, text, text) TO service_role;
