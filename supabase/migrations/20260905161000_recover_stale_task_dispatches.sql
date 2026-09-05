-- Make worker leases self-healing. Each claim first releases abandoned work;
-- exhausted rows become terminal and eligible rows return to the pending queue.

CREATE OR REPLACE FUNCTION public.claim_task_dispatch(p_worker_id text)
RETURNS SETOF public.task_dispatches
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_worker_id IS NULL OR btrim(p_worker_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'worker_id is required';
  END IF;

  UPDATE public.task_dispatches
     SET status = CASE
           WHEN attempt_count >= max_attempts THEN 'failed'
           ELSE 'pending'
         END,
         available_at = CASE
           WHEN attempt_count >= max_attempts THEN available_at
           ELSE now()
         END,
         locked_at = NULL,
         locked_by = NULL,
         last_error = 'worker lease expired'
   WHERE status = 'processing'
     AND locked_at <= now() - interval '5 minutes';

  RETURN QUERY
  WITH candidate AS (
    SELECT id
      FROM public.task_dispatches
     WHERE status = 'pending'
       AND available_at <= now()
       AND attempt_count < max_attempts
     ORDER BY available_at, created_at, id
     FOR UPDATE SKIP LOCKED
     LIMIT 1
  )
  UPDATE public.task_dispatches AS dispatch
     SET status = 'processing',
         attempt_count = dispatch.attempt_count + 1,
         locked_at = now(),
         locked_by = btrim(p_worker_id),
         last_error = NULL
    FROM candidate
   WHERE dispatch.id = candidate.id
  RETURNING dispatch.*;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_task_dispatch(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_task_dispatch(text)
  TO service_role;
