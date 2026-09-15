-- Provider-neutral live-call registry. Twilio callbacks are authenticated at
-- the Edge Function boundary and applied here idempotently. Phone numbers are
-- represented only by keyed hashes generated before this function is called.

CREATE TABLE public.live_call_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  provider text NOT NULL,
  provider_call_ref text NOT NULL,
  conversation_ref text,
  thread_id uuid REFERENCES public.threads(id) ON DELETE SET NULL,
  direction text NOT NULL,
  status text NOT NULL DEFAULT 'ringing',
  room_ref text,
  last_sequence_number integer NOT NULL DEFAULT -1,
  started_at timestamptz,
  ended_at timestamptz,
  heartbeat_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, provider, provider_call_ref),
  UNIQUE (id, workspace_id),
  CONSTRAINT live_call_sessions_provider_check CHECK (btrim(provider) <> ''),
  CONSTRAINT live_call_sessions_call_ref_check CHECK (btrim(provider_call_ref) <> ''),
  CONSTRAINT live_call_sessions_direction_check CHECK (
    direction IN ('inbound', 'outbound')
  ),
  CONSTRAINT live_call_sessions_status_check CHECK (
    status IN ('ringing', 'active', 'held', 'merging', 'ended', 'failed')
  ),
  CONSTRAINT live_call_sessions_sequence_check CHECK (last_sequence_number >= -1),
  CONSTRAINT live_call_sessions_end_check CHECK (
    (status IN ('ended', 'failed') AND ended_at IS NOT NULL)
    OR (status NOT IN ('ended', 'failed') AND ended_at IS NULL)
  )
);

CREATE INDEX live_call_sessions_active_idx
  ON public.live_call_sessions (workspace_id, status, heartbeat_at DESC)
  WHERE status IN ('ringing', 'active', 'held', 'merging');

CREATE TABLE public.live_call_participants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES public.live_call_sessions(id) ON DELETE CASCADE,
  participant_label text NOT NULL,
  provider_leg_ref text,
  actor_ref text,
  phone_ref text,
  role text NOT NULL,
  identity_state text NOT NULL DEFAULT 'unknown',
  joined_at timestamptz,
  left_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (session_id, participant_label),
  CONSTRAINT live_call_participants_label_check CHECK (btrim(participant_label) <> ''),
  CONSTRAINT live_call_participants_phone_ref_check CHECK (
    phone_ref IS NULL OR phone_ref ~ '^hmac-sha256:[0-9a-f]{64}$'
  ),
  CONSTRAINT live_call_participants_role_check CHECK (
    role IN ('caller', 'owner', 'guest', 'agent')
  ),
  CONSTRAINT live_call_participants_identity_check CHECK (
    identity_state IN ('unknown', 'claimed', 'challenged', 'evidenced', 'verified')
  ),
  CONSTRAINT live_call_participants_presence_check CHECK (
    left_at IS NULL OR (joined_at IS NOT NULL AND left_at >= joined_at)
  )
);

CREATE TABLE public.live_call_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  session_id uuid NOT NULL,
  provider text NOT NULL,
  provider_event_id text NOT NULL,
  event_type text NOT NULL,
  provider_status text NOT NULL,
  sequence_number integer,
  occurred_at timestamptz NOT NULL,
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (session_id, workspace_id)
    REFERENCES public.live_call_sessions(id, workspace_id) ON DELETE CASCADE,
  UNIQUE (workspace_id, provider, provider_event_id),
  CONSTRAINT live_call_events_provider_check CHECK (btrim(provider) <> ''),
  CONSTRAINT live_call_events_event_id_check CHECK (btrim(provider_event_id) <> ''),
  CONSTRAINT live_call_events_type_check CHECK (btrim(event_type) <> ''),
  CONSTRAINT live_call_events_status_check CHECK (btrim(provider_status) <> ''),
  CONSTRAINT live_call_events_sequence_check CHECK (
    sequence_number IS NULL OR sequence_number >= 0
  ),
  CONSTRAINT live_call_events_data_check CHECK (jsonb_typeof(data) = 'object')
);

CREATE INDEX live_call_events_session_idx
  ON public.live_call_events (session_id, occurred_at, sequence_number);

CREATE OR REPLACE FUNCTION public.record_live_call_status(
  p_workspace_id uuid,
  p_provider_event_id text,
  p_provider_call_ref text,
  p_provider_status text,
  p_direction text,
  p_occurred_at timestamptz,
  p_sequence_number integer DEFAULT NULL,
  p_from_phone_ref text DEFAULT NULL,
  p_to_phone_ref text DEFAULT NULL,
  p_data jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_session public.live_call_sessions%ROWTYPE;
  v_existing_event public.live_call_events%ROWTYPE;
  v_status text;
  v_direction text;
  v_event_type text;
  v_should_apply boolean;
  v_terminal boolean;
  v_inserted boolean := false;
BEGIN
  IF p_provider_event_id IS NULL OR btrim(p_provider_event_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'provider_event_id is required';
  END IF;
  IF p_provider_call_ref IS NULL OR btrim(p_provider_call_ref) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'provider_call_ref is required';
  END IF;
  IF p_provider_status NOT IN (
    'queued', 'initiated', 'ringing', 'in-progress', 'completed',
    'busy', 'failed', 'no-answer', 'canceled'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid provider_status';
  END IF;
  IF p_direction NOT IN ('inbound', 'outbound-api', 'outbound-dial', 'outbound') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid direction';
  END IF;
  IF p_sequence_number IS NOT NULL AND p_sequence_number < 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid sequence_number';
  END IF;
  IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'data must be a JSON object';
  END IF;
  IF p_from_phone_ref IS NOT NULL
     AND p_from_phone_ref !~ '^hmac-sha256:[0-9a-f]{64}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid from_phone_ref';
  END IF;
  IF p_to_phone_ref IS NOT NULL
     AND p_to_phone_ref !~ '^hmac-sha256:[0-9a-f]{64}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid to_phone_ref';
  END IF;

  SELECT event.* INTO v_existing_event
    FROM public.live_call_events AS event
   WHERE event.workspace_id = p_workspace_id
     AND event.provider = 'twilio'
     AND event.provider_event_id = btrim(p_provider_event_id);
  IF FOUND THEN
    SELECT * INTO v_session FROM public.live_call_sessions
     WHERE id = v_existing_event.session_id;
    RETURN jsonb_build_object(
      'session', to_jsonb(v_session),
      'event', to_jsonb(v_existing_event),
      'replayed', true,
      'state_applied', false
    );
  END IF;

  v_direction := CASE WHEN p_direction = 'inbound' THEN 'inbound' ELSE 'outbound' END;
  v_status := CASE
    WHEN p_provider_status IN ('queued', 'initiated', 'ringing') THEN 'ringing'
    WHEN p_provider_status = 'in-progress' THEN 'active'
    WHEN p_provider_status = 'completed' THEN 'ended'
    ELSE 'failed'
  END;
  v_event_type := CASE
    WHEN p_provider_status IN ('queued', 'initiated') THEN 'call.started'
    WHEN p_provider_status = 'ringing' THEN 'call.ringing'
    WHEN p_provider_status = 'in-progress' THEN 'call.answered'
    ELSE 'call.ended'
  END;
  v_terminal := v_status IN ('ended', 'failed');

  INSERT INTO public.live_call_sessions (
    workspace_id, provider, provider_call_ref, direction, status,
    last_sequence_number, started_at, ended_at, heartbeat_at
  ) VALUES (
    p_workspace_id, 'twilio', btrim(p_provider_call_ref), v_direction, v_status,
    COALESCE(p_sequence_number, -1),
    CASE WHEN v_status = 'active' THEN p_occurred_at ELSE NULL END,
    CASE WHEN v_terminal THEN p_occurred_at ELSE NULL END,
    p_occurred_at
  )
  ON CONFLICT (workspace_id, provider, provider_call_ref) DO NOTHING
  RETURNING * INTO v_session;

  v_inserted := FOUND;

  IF NOT v_inserted THEN
    SELECT * INTO v_session FROM public.live_call_sessions
     WHERE workspace_id = p_workspace_id
       AND provider = 'twilio'
       AND provider_call_ref = btrim(p_provider_call_ref)
     FOR UPDATE;
  END IF;

  -- A concurrent delivery may have inserted this event while this transaction
  -- waited for the session lock. Recheck inside the serialized boundary.
  SELECT event.* INTO v_existing_event
    FROM public.live_call_events AS event
   WHERE event.workspace_id = p_workspace_id
     AND event.provider = 'twilio'
     AND event.provider_event_id = btrim(p_provider_event_id);
  IF FOUND THEN
    RETURN jsonb_build_object(
      'session', to_jsonb(v_session),
      'event', to_jsonb(v_existing_event),
      'replayed', true,
      'state_applied', false
    );
  END IF;

  v_should_apply := v_inserted OR (v_session.status NOT IN ('ended', 'failed')
    AND (
      p_sequence_number IS NULL
      OR p_sequence_number > v_session.last_sequence_number
    ));

  IF v_should_apply AND NOT v_inserted THEN
    UPDATE public.live_call_sessions
       SET status = v_status,
           direction = v_direction,
           last_sequence_number = GREATEST(last_sequence_number, COALESCE(p_sequence_number, -1)),
           started_at = CASE
             WHEN v_status = 'active' THEN COALESCE(started_at, p_occurred_at)
             ELSE started_at
           END,
           ended_at = CASE WHEN v_terminal THEN p_occurred_at ELSE NULL END,
           heartbeat_at = GREATEST(heartbeat_at, p_occurred_at),
           updated_at = now()
     WHERE id = v_session.id
     RETURNING * INTO v_session;
  END IF;

  INSERT INTO public.live_call_events (
    workspace_id, session_id, provider, provider_event_id, event_type,
    provider_status, sequence_number, occurred_at, data
  ) VALUES (
    p_workspace_id, v_session.id, 'twilio', btrim(p_provider_event_id),
    v_event_type, p_provider_status, p_sequence_number, p_occurred_at, p_data
  ) RETURNING * INTO v_existing_event;

  INSERT INTO public.live_call_participants (
    session_id, participant_label, phone_ref, role, joined_at, left_at
  ) VALUES
    (
      v_session.id, 'originator', p_from_phone_ref,
      CASE WHEN v_direction = 'inbound' THEN 'caller' ELSE 'agent' END,
      CASE WHEN v_status = 'active' OR p_provider_status = 'completed'
        THEN p_occurred_at ELSE NULL END,
      CASE WHEN p_provider_status = 'completed' THEN p_occurred_at ELSE NULL END
    ),
    (
      v_session.id, 'recipient', p_to_phone_ref,
      CASE WHEN v_direction = 'inbound' THEN 'agent' ELSE 'caller' END,
      CASE WHEN v_status = 'active' OR p_provider_status = 'completed'
        THEN p_occurred_at ELSE NULL END,
      CASE WHEN p_provider_status = 'completed' THEN p_occurred_at ELSE NULL END
    )
  ON CONFLICT (session_id, participant_label) DO UPDATE
    SET phone_ref = COALESCE(EXCLUDED.phone_ref, live_call_participants.phone_ref),
        joined_at = CASE
          WHEN v_status = 'active' OR p_provider_status = 'completed'
            THEN COALESCE(live_call_participants.joined_at, p_occurred_at)
          ELSE live_call_participants.joined_at
        END,
        left_at = CASE
          WHEN v_terminal AND (
            live_call_participants.joined_at IS NOT NULL
            OR p_provider_status = 'completed'
          ) THEN p_occurred_at
          ELSE live_call_participants.left_at
        END,
        updated_at = now();

  RETURN jsonb_build_object(
    'session', to_jsonb(v_session),
    'event', to_jsonb(v_existing_event),
    'replayed', false,
    'state_applied', v_should_apply
  );
END;
$$;

ALTER TABLE public.live_call_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.live_call_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.live_call_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.live_call_sessions, public.live_call_participants,
  public.live_call_events FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.live_call_sessions,
  public.live_call_participants, public.live_call_events TO service_role;

REVOKE ALL ON FUNCTION public.record_live_call_status(
  uuid, text, text, text, text, timestamptz, integer, text, text, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_live_call_status(
  uuid, text, text, text, text, timestamptz, integer, text, text, jsonb
) TO service_role;
