-- Durable side-effect outbox. Wake/decision paths enqueue intent; a bounded
-- worker claims one row at a time and records completion or a scheduled retry.

CREATE TABLE public.task_dispatches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  dispatch_type text NOT NULL,
  dedupe_key text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending',
  available_at timestamptz NOT NULL DEFAULT now(),
  attempt_count integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 3,
  locked_at timestamptz,
  locked_by text,
  last_error text,
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CONSTRAINT task_dispatches_type_check CHECK (btrim(dispatch_type) <> ''),
  CONSTRAINT task_dispatches_dedupe_key_check CHECK (btrim(dedupe_key) <> ''),
  CONSTRAINT task_dispatches_payload_check CHECK (jsonb_typeof(payload) = 'object'),
  CONSTRAINT task_dispatches_result_check CHECK (
    result IS NULL OR jsonb_typeof(result) = 'object'
  ),
  CONSTRAINT task_dispatches_status_check CHECK (
    status IN ('pending', 'processing', 'completed', 'failed', 'cancelled')
  ),
  CONSTRAINT task_dispatches_attempt_count_check CHECK (attempt_count >= 0),
  CONSTRAINT task_dispatches_max_attempts_check CHECK (max_attempts BETWEEN 1 AND 10),
  CONSTRAINT task_dispatches_lock_check CHECK (
    (status = 'processing' AND locked_at IS NOT NULL AND locked_by IS NOT NULL)
    OR (status <> 'processing' AND locked_at IS NULL AND locked_by IS NULL)
  ),
  CONSTRAINT task_dispatches_completion_check CHECK (
    (status = 'completed' AND completed_at IS NOT NULL)
    OR (status <> 'completed' AND completed_at IS NULL)
  ),
  CONSTRAINT task_dispatches_task_dedupe_key_key UNIQUE (task_id, dedupe_key)
);

ALTER TABLE public.task_dispatches ENABLE ROW LEVEL SECURITY;

CREATE INDEX task_dispatches_pending_idx
  ON public.task_dispatches (available_at, created_at, id)
  WHERE status = 'pending';

CREATE TRIGGER task_dispatches_updated_at
  BEFORE UPDATE ON public.task_dispatches
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at();

REVOKE ALL ON TABLE public.task_dispatches FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.task_dispatches TO service_role;

CREATE OR REPLACE FUNCTION public.enqueue_task_dispatch(
  p_task_id uuid,
  p_dispatch_type text,
  p_dedupe_key text,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_available_at timestamptz DEFAULT now(),
  p_max_attempts integer DEFAULT 3
)
RETURNS public.task_dispatches
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_dispatch public.task_dispatches%ROWTYPE;
BEGIN
  IF p_dispatch_type IS NULL OR btrim(p_dispatch_type) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'dispatch_type is required';
  END IF;
  IF p_dedupe_key IS NULL OR btrim(p_dedupe_key) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'dedupe_key is required';
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'payload must be a JSON object';
  END IF;
  IF p_available_at IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'available_at is required';
  END IF;
  IF p_max_attempts IS NULL OR p_max_attempts NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'max_attempts must be between 1 and 10';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.tasks WHERE id = p_task_id) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'task not found';
  END IF;

  INSERT INTO public.task_dispatches (
    task_id, dispatch_type, dedupe_key, payload, available_at, max_attempts
  ) VALUES (
    p_task_id, btrim(p_dispatch_type), btrim(p_dedupe_key), p_payload,
    p_available_at, p_max_attempts
  )
  ON CONFLICT (task_id, dedupe_key) DO NOTHING
  RETURNING * INTO v_dispatch;

  IF NOT FOUND THEN
    SELECT * INTO v_dispatch
      FROM public.task_dispatches
     WHERE task_id = p_task_id
       AND dedupe_key = btrim(p_dedupe_key);
  END IF;

  RETURN v_dispatch;
END;
$$;

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

CREATE OR REPLACE FUNCTION public.complete_task_dispatch(
  p_dispatch_id uuid,
  p_worker_id text,
  p_result jsonb DEFAULT '{}'::jsonb
)
RETURNS public.task_dispatches
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_dispatch public.task_dispatches%ROWTYPE;
BEGIN
  IF p_worker_id IS NULL OR btrim(p_worker_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'worker_id is required';
  END IF;
  IF p_result IS NULL OR jsonb_typeof(p_result) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'result must be a JSON object';
  END IF;

  SELECT * INTO v_dispatch
    FROM public.task_dispatches
   WHERE id = p_dispatch_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'dispatch not found';
  END IF;
  IF v_dispatch.status = 'completed' THEN
    RETURN v_dispatch;
  END IF;
  IF v_dispatch.status <> 'processing' OR v_dispatch.locked_by <> btrim(p_worker_id) THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'dispatch is not owned by worker';
  END IF;

  UPDATE public.task_dispatches
     SET status = 'completed',
         result = p_result,
         locked_at = NULL,
         locked_by = NULL,
         completed_at = now()
   WHERE id = p_dispatch_id
  RETURNING * INTO v_dispatch;

  RETURN v_dispatch;
END;
$$;

CREATE OR REPLACE FUNCTION public.retry_task_dispatch(
  p_dispatch_id uuid,
  p_worker_id text,
  p_error text,
  p_delay_seconds integer DEFAULT 30
)
RETURNS public.task_dispatches
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_dispatch public.task_dispatches%ROWTYPE;
BEGIN
  IF p_worker_id IS NULL OR btrim(p_worker_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'worker_id is required';
  END IF;
  IF p_error IS NULL OR btrim(p_error) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'error is required';
  END IF;
  IF p_delay_seconds IS NULL OR p_delay_seconds NOT BETWEEN 1 AND 3600 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'delay_seconds must be between 1 and 3600';
  END IF;

  SELECT * INTO v_dispatch
    FROM public.task_dispatches
   WHERE id = p_dispatch_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'dispatch not found';
  END IF;
  IF v_dispatch.status <> 'processing' OR v_dispatch.locked_by <> btrim(p_worker_id) THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'dispatch is not owned by worker';
  END IF;

  UPDATE public.task_dispatches
     SET status = CASE
           WHEN attempt_count >= max_attempts THEN 'failed'
           ELSE 'pending'
         END,
         available_at = CASE
           WHEN attempt_count >= max_attempts THEN available_at
           ELSE now() + make_interval(secs => p_delay_seconds)
         END,
         locked_at = NULL,
         locked_by = NULL,
         last_error = btrim(p_error)
   WHERE id = p_dispatch_id
  RETURNING * INTO v_dispatch;

  RETURN v_dispatch;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_task_dispatch(uuid, text, text, jsonb, timestamptz, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_task_dispatch(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_task_dispatch(uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.retry_task_dispatch(uuid, text, text, integer)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.enqueue_task_dispatch(uuid, text, text, jsonb, timestamptz, integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_task_dispatch(text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_task_dispatch(uuid, text, jsonb)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.retry_task_dispatch(uuid, text, text, integer)
  TO service_role;

