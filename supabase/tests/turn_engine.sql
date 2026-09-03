BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;

SELECT plan(15);

INSERT INTO public.tasks (id, task_type, goal)
VALUES ('00000000-0000-0000-0000-000000000001', 'test', 'Exercise the turn engine');

SELECT lives_ok(
  $$
    SELECT public.advance_task(
      '00000000-0000-0000-0000-000000000001',
      'turn.started',
      'test-runner',
      'call-1',
      'new',
      '{"status":"running","current_step":"execute"}'::jsonb
    )
  $$,
  'a valid turn advances the task'
);

SELECT results_eq(
  $$
    SELECT status, current_step
      FROM public.tasks
     WHERE id = '00000000-0000-0000-0000-000000000001'
  $$,
  $$ VALUES ('running'::text, 'execute'::text) $$,
  'the patch updates the task snapshot'
);

-- Replaying a call is a no-op, even if its original expected state is stale.
SELECT lives_ok(
  $$
    SELECT public.advance_task(
      '00000000-0000-0000-0000-000000000001',
      'turn.started',
      'test-runner',
      'call-1',
      'new',
      '{"status":"completed"}'::jsonb
    )
  $$,
  'an idempotent replay succeeds'
);

SELECT is(
  (
    SELECT count(*)::integer
      FROM public.task_events
     WHERE task_id = '00000000-0000-0000-0000-000000000001'
  ),
  1,
  'an idempotent replay does not append an event'
);

SELECT is(
  (
    SELECT status
      FROM public.tasks
     WHERE id = '00000000-0000-0000-0000-000000000001'
  ),
  'running',
  'an idempotent replay does not apply a different patch'
);

SELECT lives_ok(
  $$
    SELECT public.advance_task(
      '00000000-0000-0000-0000-000000000001',
      'turn.completed',
      'test-runner',
      'call-2',
      'running',
      '{"status":"completed","next_action":null}'::jsonb,
      'ok',
      '{"result":"done"}'::jsonb
    )
  $$,
  'a running task can complete'
);

SELECT is(
  (
    SELECT status
      FROM public.tasks
     WHERE id = '00000000-0000-0000-0000-000000000001'
  ),
  'completed',
  'the task reaches completed status'
);

SELECT ok(
  (
    SELECT completed_at IS NOT NULL
      FROM public.tasks
     WHERE id = '00000000-0000-0000-0000-000000000001'
  ),
  'completion records its timestamp'
);

SELECT throws_ok(
  $$
    SELECT public.advance_task(
      '00000000-0000-0000-0000-000000000001',
      'turn.reopened',
      'test-runner',
      'call-3',
      'completed',
      '{"status":"running"}'::jsonb
    )
  $$,
  '22023',
  'invalid task transition: completed -> running',
  'terminal tasks cannot be reopened'
);

INSERT INTO public.tasks (id, task_type, goal, status)
VALUES (
  '00000000-0000-4000-8000-000000000099',
  'test',
  'Exercise pause and resume',
  'running'
);

SELECT lives_ok(
  $$
    SELECT public.advance_task(
      '00000000-0000-4000-8000-000000000099',
      'turn.waiting_for_user',
      'test-runner',
      'call-wait',
      'running',
      '{
        "status":"waiting_user",
        "waiting_for":"user",
        "pending_question":"Which date works?",
        "resume_condition":"User supplies a date"
      }'::jsonb,
      'needs_input'
    )
  $$,
  'a running task can pause for user input'
);

SELECT results_eq(
  $$
    SELECT status, waiting_for, pending_question, resume_condition
      FROM public.tasks
     WHERE id = '00000000-0000-4000-8000-000000000099'
  $$,
  $$
    VALUES (
      'waiting_user'::text,
      'user'::text,
      'Which date works?'::text,
      'User supplies a date'::text
    )
  $$,
  'the question and resume condition are stored on the task'
);

SELECT lives_ok(
  $$
    SELECT public.advance_task(
      '00000000-0000-4000-8000-000000000099',
      'user.responded',
      'test-runner',
      'call-resume',
      'waiting_user',
      '{
        "status":"ready",
        "waiting_for":null,
        "pending_question":null,
        "resume_condition":null
      }'::jsonb,
      'input_received',
      '{"answer":"November 10"}'::jsonb
    )
  $$,
  'a user answer makes the task ready again'
);

SELECT results_eq(
  $$
    SELECT status, waiting_for, pending_question, resume_condition
      FROM public.tasks
     WHERE id = '00000000-0000-4000-8000-000000000099'
  $$,
  $$ VALUES ('ready'::text, NULL::text, NULL::text, NULL::text) $$,
  'resuming clears the waiting fields'
);

SELECT is(
  (
    SELECT extracted_data->>'answer'
      FROM public.task_events
     WHERE task_id = '00000000-0000-4000-8000-000000000099'
       AND event_type = 'user.responded'
  ),
  'November 10',
  'the answer is preserved on the resume event'
);

SELECT is(
  (
    SELECT count(*)::integer
      FROM public.task_events
     WHERE task_id = '00000000-0000-4000-8000-000000000099'
  ),
  2,
  'pause and resume append one event each'
);

SELECT * FROM finish();
ROLLBACK;
