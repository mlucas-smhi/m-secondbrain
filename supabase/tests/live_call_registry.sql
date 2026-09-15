BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;

SELECT plan(13);

SELECT lives_ok(
  $$
    SELECT public.record_live_call_status(
      '00000000-0000-4000-8000-000000000001',
      'CA-live-test:0', 'CA-live-test', 'ringing', 'inbound',
      '2026-09-15T12:00:00Z', 0,
      'hmac-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'hmac-sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    )
  $$,
  'a signed-boundary callback can create an isolated live session'
);

SELECT is(
  (SELECT status FROM public.live_call_sessions WHERE provider_call_ref = 'CA-live-test'),
  'ringing',
  'ringing callback creates ringing state'
);

SELECT is(
  (SELECT count(*)::integer FROM public.live_call_participants
    WHERE session_id = (SELECT id FROM public.live_call_sessions WHERE provider_call_ref = 'CA-live-test')),
  2,
  'callback creates two private participant records'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM public.live_call_participants
     WHERE phone_ref LIKE '%+1555%'
  ),
  'participant records contain no raw phone numbers'
);

SELECT lives_ok(
  $$
    SELECT public.record_live_call_status(
      '00000000-0000-4000-8000-000000000001',
      'CA-live-test:1', 'CA-live-test', 'in-progress', 'inbound',
      '2026-09-15T12:00:05Z', 1
    )
  $$,
  'answered callback advances the session'
);

SELECT results_eq(
  $$ SELECT status, last_sequence_number, started_at IS NOT NULL
       FROM public.live_call_sessions WHERE provider_call_ref = 'CA-live-test' $$,
  $$ VALUES ('active'::text, 1, true) $$,
  'answered callback records active state and its sequence'
);

SELECT is(
  (
    SELECT public.record_live_call_status(
      '00000000-0000-4000-8000-000000000001',
      'CA-live-test:late', 'CA-live-test', 'ringing', 'inbound',
      '2026-09-15T12:00:03Z', 0
    )->>'state_applied'
  )::boolean,
  false,
  'an out-of-order callback is audited but does not regress state'
);

SELECT is(
  (SELECT status FROM public.live_call_sessions WHERE provider_call_ref = 'CA-live-test'),
  'active',
  'late ringing callback leaves the active session unchanged'
);

SELECT is(
  (
    SELECT public.record_live_call_status(
      '00000000-0000-4000-8000-000000000001',
      'CA-live-test:1', 'CA-live-test', 'in-progress', 'inbound',
      '2026-09-15T12:00:05Z', 1
    )->>'replayed'
  )::boolean,
  true,
  'a repeated provider event is an idempotent replay'
);

SELECT is(
  (SELECT count(*)::integer FROM public.live_call_events
    WHERE session_id = (SELECT id FROM public.live_call_sessions WHERE provider_call_ref = 'CA-live-test')),
  3,
  'replay creates no duplicate event'
);

SELECT lives_ok(
  $$
    SELECT public.record_live_call_status(
      '00000000-0000-4000-8000-000000000001',
      'CA-live-test:2', 'CA-live-test', 'completed', 'inbound',
      '2026-09-15T12:01:00Z', 2
    )
  $$,
  'completed callback terminates the session'
);

SELECT results_eq(
  $$ SELECT status, ended_at IS NOT NULL
       FROM public.live_call_sessions WHERE provider_call_ref = 'CA-live-test' $$,
  $$ VALUES ('ended'::text, true) $$,
  'completed callback records ended state'
);

SELECT throws_ok(
  $$
    SELECT public.record_live_call_status(
      '00000000-0000-4000-8000-000000000001',
      'bad-status', 'CA-other', 'mystery', 'inbound', now(), 0
    )
  $$,
  '22023',
  'invalid provider_status',
  'unknown provider states fail closed'
);

SELECT * FROM finish();
ROLLBACK;
