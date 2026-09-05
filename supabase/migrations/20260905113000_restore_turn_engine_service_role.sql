-- Reopen the turn engine only to the trusted Edge Function runtime after the
-- non-retryable conflict and replay-gating hardening has been deployed.

REVOKE EXECUTE ON FUNCTION public.advance_task(
  uuid, text, text, text, text, jsonb, text, jsonb, uuid
) FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.process_task_turn(
  uuid, text, text, text, text, text, text, text
) FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.wake_task(
  uuid, text, text, jsonb, text
) FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.wake_task_delivery(
  uuid, text, text, jsonb, text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.advance_task(
  uuid, text, text, text, text, jsonb, text, jsonb, uuid
) TO service_role;

GRANT EXECUTE ON FUNCTION public.process_task_turn(
  uuid, text, text, text, text, text, text, text
) TO service_role;

GRANT EXECUTE ON FUNCTION public.wake_task(
  uuid, text, text, jsonb, text
) TO service_role;

GRANT EXECUTE ON FUNCTION public.wake_task_delivery(
  uuid, text, text, jsonb, text
) TO service_role;

