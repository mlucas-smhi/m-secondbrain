-- Extend atomic task planning with provider-neutral tool requirements without
-- duplicating the graph-building implementation.

ALTER FUNCTION public.create_task_plan(jsonb, text, text)
  RENAME TO create_task_plan_base;

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
      FROM public.task_decisions AS decision WHERE decision.task_id = task.id), '[]'::jsonb),
    'tool_requirements', COALESCE((
      SELECT jsonb_agg(to_jsonb(requirement) ORDER BY step.created_at, step.id, requirement.capability)
        FROM public.task_step_tool_requirements AS requirement
        JOIN public.task_steps AS step ON step.id = requirement.step_id
       WHERE requirement.task_id = task.id
    ), '[]'::jsonb)
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
  v_existing_task_id uuid;
  v_snapshot jsonb;
  v_task_id uuid;
  v_workspace_id uuid;
  v_step_id uuid;
  v_adapter_id uuid;
  v_item jsonb;
  v_capability text;
BEGIN
  IF p_call_id IS NULL OR btrim(p_call_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'call_id is required';
  END IF;

  -- Preserve the original planner's replay-before-revalidation behavior.
  SELECT event.task_id INTO v_existing_task_id
    FROM public.task_events AS event
   WHERE event.event_type = 'task.planned' AND event.call_id = btrim(p_call_id);
  IF FOUND THEN
    RETURN public.task_plan_snapshot(v_existing_task_id);
  END IF;

  IF p_plan IS NULL OR jsonb_typeof(p_plan) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'plan must be a JSON object';
  END IF;
  IF jsonb_typeof(COALESCE(p_plan->'tool_requirements', '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'tool_requirements must be a JSON array';
  END IF;

  v_snapshot := public.create_task_plan_base(p_plan, p_call_id, p_actor);
  v_task_id := (v_snapshot->'task'->>'id')::uuid;
  v_workspace_id := (v_snapshot->'thread'->>'workspace_id')::uuid;

  FOR v_item IN
    SELECT value FROM jsonb_array_elements(COALESCE(p_plan->'tool_requirements', '[]'::jsonb))
  LOOP
    IF jsonb_typeof(v_item) <> 'object' THEN
      RAISE EXCEPTION USING ERRCODE = '22023',
        MESSAGE = 'tool requirement must be a JSON object';
    END IF;
    v_capability := btrim(v_item->>'capability');
    IF v_capability IS NULL OR v_capability = '' THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'tool capability is required';
    END IF;

    SELECT step.id INTO v_step_id
      FROM public.task_steps AS step
     WHERE step.task_id = v_task_id
       AND step.step_key = btrim(v_item->>'step_key');
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = '22023',
        MESSAGE = 'tool requirement references an unknown step';
    END IF;

    v_adapter_id := NULL;
    IF NULLIF(btrim(v_item->>'preferred_adapter_key'), '') IS NOT NULL THEN
      SELECT adapter.id INTO v_adapter_id
        FROM public.tool_adapters AS adapter
       WHERE adapter.workspace_id = v_workspace_id
         AND adapter.adapter_key = btrim(v_item->>'preferred_adapter_key')
         AND adapter.status = 'active'
         AND v_capability = ANY (adapter.capabilities);
      IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = '22023',
          MESSAGE = 'preferred adapter is unavailable or lacks the required capability';
      END IF;
    END IF;

    INSERT INTO public.task_step_tool_requirements (
      task_id, step_id, capability, access_mode, required,
      preferred_adapter_id, constraints
    ) VALUES (
      v_task_id, v_step_id, v_capability,
      COALESCE(NULLIF(btrim(v_item->>'access_mode'), ''), 'read'),
      COALESCE((v_item->>'required')::boolean, true),
      v_adapter_id,
      COALESCE(v_item->'constraints', '{}'::jsonb)
    );
  END LOOP;

  RETURN public.task_plan_snapshot(v_task_id);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION USING ERRCODE = '22023',
    MESSAGE = 'tool requirements must be unique per step and capability';
END;
$$;

REVOKE ALL ON FUNCTION public.create_task_plan_base(jsonb, text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.task_plan_snapshot(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_task_plan(jsonb, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_task_plan_base(jsonb, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.task_plan_snapshot(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.create_task_plan(jsonb, text, text) TO service_role;
