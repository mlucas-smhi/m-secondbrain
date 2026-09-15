-- Provider-neutral, privacy-preserving context for one live call. This is the
-- read boundary used before any interruption or merge proposal is considered.

CREATE OR REPLACE FUNCTION public.get_live_call_context(
  p_workspace_id uuid,
  p_provider_call_ref text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_session public.live_call_sessions%ROWTYPE;
  v_other_sessions jsonb;
BEGIN
  IF p_provider_call_ref IS NULL OR btrim(p_provider_call_ref) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'provider_call_ref is required';
  END IF;

  SELECT * INTO v_session
    FROM public.live_call_sessions
   WHERE workspace_id = p_workspace_id
     AND provider = 'twilio'
     AND provider_call_ref = btrim(p_provider_call_ref);

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'live call session not found';
  END IF;

  SELECT COALESCE(jsonb_agg(candidate.context ORDER BY candidate.started_at), '[]'::jsonb)
    INTO v_other_sessions
    FROM (
      SELECT
        COALESCE(other.started_at, other.created_at) AS started_at,
        jsonb_build_object(
          'session_id', other.id,
          'direction', other.direction,
          'status', other.status,
          'started_at', other.started_at,
          'identity_state', CASE
            WHEN verified.actor_ref IS NOT NULL THEN 'verified'
            ELSE 'withheld'
          END,
          'actor_ref', verified.actor_ref
        ) AS context
      FROM public.live_call_sessions AS other
      LEFT JOIN LATERAL (
        SELECT participant.actor_ref
          FROM public.live_call_participants AS participant
         WHERE participant.session_id = other.id
           AND participant.role IN ('caller', 'owner', 'guest')
           AND participant.identity_state = 'verified'
           AND participant.actor_ref IS NOT NULL
         ORDER BY participant.updated_at DESC
         LIMIT 1
      ) AS verified ON true
      WHERE other.workspace_id = p_workspace_id
        AND other.id <> v_session.id
        AND other.status IN ('ringing', 'active', 'held', 'merging')
    ) AS candidate;

  RETURN jsonb_build_object(
    'session', jsonb_build_object(
      'session_id', v_session.id,
      'direction', v_session.direction,
      'status', v_session.status,
      'started_at', v_session.started_at
    ),
    'other_live_sessions', v_other_sessions,
    'other_live_session_count', jsonb_array_length(v_other_sessions),
    'handling', CASE
      WHEN jsonb_array_length(v_other_sessions) = 0 THEN 'NO_OTHER_LIVE_SESSION'
      ELSE 'OTHER_LIVE_SESSION_PRESENT'
    END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_live_call_context(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_live_call_context(uuid, text)
  TO service_role;
