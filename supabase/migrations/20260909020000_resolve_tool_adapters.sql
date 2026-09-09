-- Resolve provider-neutral capabilities at execution time. Plans reference a
-- capability; the selected provider remains replaceable workspace configuration.

ALTER TABLE public.tool_adapters
  ADD COLUMN selection_priority integer NOT NULL DEFAULT 100,
  ADD CONSTRAINT tool_adapters_selection_priority_check
    CHECK (selection_priority BETWEEN 0 AND 10000);

CREATE OR REPLACE FUNCTION public.resolve_task_step_tool_adapter(
  p_step_id uuid,
  p_capability text
)
RETURNS public.tool_adapters
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_requirement public.task_step_tool_requirements%ROWTYPE;
  v_workspace_id uuid;
  v_adapter public.tool_adapters%ROWTYPE;
BEGIN
  IF p_capability IS NULL OR btrim(p_capability) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'capability is required';
  END IF;

  SELECT requirement.*
    INTO v_requirement
    FROM public.task_step_tool_requirements AS requirement
   WHERE requirement.step_id = p_step_id
     AND requirement.capability = btrim(p_capability);
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'tool requirement not found';
  END IF;

  SELECT thread.workspace_id INTO v_workspace_id
    FROM public.tasks AS task
    JOIN public.threads AS thread ON thread.id = task.thread_id
   WHERE task.id = v_requirement.task_id;

  SELECT adapter.* INTO v_adapter
    FROM public.tool_adapters AS adapter
   WHERE adapter.workspace_id = v_workspace_id
     AND adapter.status = 'active'
     AND btrim(p_capability) = ANY (adapter.capabilities)
     AND (
       v_requirement.preferred_adapter_id IS NULL
       OR adapter.id = v_requirement.preferred_adapter_id
     )
   ORDER BY adapter.selection_priority, adapter.adapter_key, adapter.id
   LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'no active adapter supports capability';
  END IF;
  RETURN v_adapter;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_task_step_tool_adapter(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_task_step_tool_adapter(uuid, text)
  TO service_role;
