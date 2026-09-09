-- Persist the RouteStack adapter that was proven by the hosted canary and let
-- an actively claimed worker recover only the safe canonical result on replay.

INSERT INTO public.tool_adapters (
  workspace_id, adapter_key, provider, transport, status, capabilities,
  credential_ref, configuration, selection_priority
)
VALUES (
  '00000000-0000-4000-8000-000000000001',
  'travel-inventory-routestack', 'routestack', 'mcp', 'active',
  ARRAY[
    'travel.flight.search', 'travel.flight.place_suggest',
    'travel.hotel.search', 'travel.hotel.place_suggest',
    'travel.car.search', 'travel.car.place_suggest'
  ],
  'n8n:Travel MCP',
  '{
    "endpoint":"https://apozwrkkomowdaocwfmm.supabase.co/functions/v1/routestack-travel-mcp",
    "operations":{
      "travel.flight.search":"travel_flight_search",
      "travel.flight.place_suggest":"travel_flight_place_suggest",
      "travel.hotel.search":"travel_hotel_search",
      "travel.hotel.place_suggest":"travel_hotel_place_suggest",
      "travel.car.search":"travel_car_search",
      "travel.car.place_suggest":"travel_car_place_suggest"
    }
  }'::jsonb,
  50
)
ON CONFLICT (workspace_id, adapter_key) DO UPDATE SET
  provider = EXCLUDED.provider,
  transport = EXCLUDED.transport,
  status = EXCLUDED.status,
  capabilities = EXCLUDED.capabilities,
  credential_ref = EXCLUDED.credential_ref,
  configuration = EXCLUDED.configuration,
  selection_priority = EXCLUDED.selection_priority;

CREATE OR REPLACE FUNCTION public.read_task_step_tool_result(
  p_step_id uuid,
  p_claim_token uuid,
  p_result_ref text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_step public.task_steps%ROWTYPE;
  v_result public.task_step_tool_results%ROWTYPE;
  v_result_id uuid;
BEGIN
  IF p_result_ref IS NULL OR p_result_ref !~ '^tool-result:[0-9a-fA-F-]{36}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid tool result reference';
  END IF;
  v_result_id := substring(p_result_ref FROM 13)::uuid;

  SELECT step.* INTO v_step
    FROM public.task_steps AS step
   WHERE step.id = p_step_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'task step not found';
  END IF;
  IF v_step.status <> 'running'
     OR v_step.claim_token IS DISTINCT FROM p_claim_token
     OR v_step.lease_expires_at IS NULL
     OR v_step.lease_expires_at <= now() THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'task step claim is not active';
  END IF;

  SELECT result.* INTO v_result
    FROM public.task_step_tool_results AS result
   WHERE result.id = v_result_id
     AND result.step_id = p_step_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'tool result not found for task step';
  END IF;

  RETURN jsonb_build_object(
    'result_ref', p_result_ref,
    'result_type', v_result.result_type,
    'provider', v_result.provider,
    'canonical_result', v_result.canonical_result,
    'retrieved_at', v_result.retrieved_at,
    'expires_at', v_result.expires_at,
    'expired', v_result.expires_at <= now()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.read_task_step_tool_result(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.read_task_step_tool_result(uuid, uuid, text)
  TO service_role;
