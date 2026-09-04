-- SQLSTATE 40001 means serialization_failure and may be retried automatically.
-- Turn-engine state conflicts are deterministic, so expose them as an HTTP 409
-- application conflict instead. Keep the incident circuit breaker closed.

DO $$
DECLARE
  v_advance_definition text;
  v_wake_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.advance_task(uuid,text,text,text,text,jsonb,text,jsonb,uuid)'::regprocedure
  ) INTO v_advance_definition;

  IF position('40001' IN v_advance_definition) = 0 THEN
    RAISE EXCEPTION 'advance_task does not contain the expected 40001 conflict code';
  END IF;

  EXECUTE replace(v_advance_definition, '40001', 'PT409');

  SELECT pg_get_functiondef(
    'public.wake_task(uuid,text,text,jsonb,text)'::regprocedure
  ) INTO v_wake_definition;

  IF position('40001' IN v_wake_definition) = 0 THEN
    RAISE EXCEPTION 'wake_task does not contain the expected 40001 conflict code';
  END IF;

  EXECUTE replace(v_wake_definition, '40001', 'PT409');
END;
$$;

REVOKE EXECUTE ON FUNCTION public.advance_task(
  uuid, text, text, text, text, jsonb, text, jsonb, uuid
) FROM PUBLIC, anon, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.process_task_turn(
  uuid, text, text, text, text, text, text, text
) FROM PUBLIC, anon, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.wake_task(
  uuid, text, text, jsonb, text
) FROM PUBLIC, anon, authenticated, service_role;
