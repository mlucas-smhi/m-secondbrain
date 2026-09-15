BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;

SELECT plan(8);

SELECT lives_ok(
  $$
    SELECT public.record_live_call_status(
      '00000000-0000-4000-8000-000000000001',
      'CA-context-owner:0', 'CA-context-owner', 'in-progress', 'outbound',
      '2026-09-15T15:00:00Z', 0
    )
  $$,
  'owner session can be registered'
);

SELECT is(
  public.get_live_call_context(
    '00000000-0000-4000-8000-000000000001', 'CA-context-owner'
  )->>'handling',
  'NO_OTHER_LIVE_SESSION',
  'an isolated call reports no competing session'
);

SELECT lives_ok(
  $$
    SELECT public.record_live_call_status(
      '00000000-0000-4000-8000-000000000001',
      'CA-context-caller:0', 'CA-context-caller', 'ringing', 'inbound',
      '2026-09-15T15:00:05Z', 0,
      'hmac-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'hmac-sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    )
  $$,
  'a second inbound call can remain isolated'
);

SELECT is(
  (public.get_live_call_context(
    '00000000-0000-4000-8000-000000000001', 'CA-context-owner'
  )->>'other_live_session_count')::integer,
  1,
  'the active session can see that one other live session exists'
);

SELECT results_eq(
  $$
    SELECT
      item->>'identity_state',
      item->>'actor_ref'
    FROM jsonb_array_elements(public.get_live_call_context(
      '00000000-0000-4000-8000-000000000001', 'CA-context-owner'
    )->'other_live_sessions') AS item
  $$,
  $$ VALUES ('withheld'::text, NULL::text) $$,
  'unverified caller identity is withheld'
);

UPDATE public.live_call_participants
   SET actor_ref = 'person:curtis', identity_state = 'verified'
 WHERE session_id = (
   SELECT id FROM public.live_call_sessions
    WHERE provider_call_ref = 'CA-context-caller'
 )
   AND role = 'caller';

SELECT results_eq(
  $$
    SELECT
      item->>'identity_state',
      item->>'actor_ref'
    FROM jsonb_array_elements(public.get_live_call_context(
      '00000000-0000-4000-8000-000000000001', 'CA-context-owner'
    )->'other_live_sessions') AS item
  $$,
  $$ VALUES ('verified'::text, 'person:curtis'::text) $$,
  'verified caller identity may cross the context boundary'
);

SELECT lives_ok(
  $$
    SELECT public.record_live_call_status(
      '00000000-0000-4000-8000-000000000001',
      'CA-context-caller:1', 'CA-context-caller', 'completed', 'inbound',
      '2026-09-15T15:01:00Z', 1
    )
  $$,
  'ending the second call removes it from live consideration'
);

SELECT throws_ok(
  $$
    SELECT public.get_live_call_context(
      '00000000-0000-4000-8000-000000000001', 'CA-missing'
    )
  $$,
  'P0002',
  'live call session not found',
  'unknown sessions fail closed'
);

SELECT * FROM finish();
ROLLBACK;
