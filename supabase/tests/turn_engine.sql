BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;

SELECT plan(30);

SELECT lives_ok(
  $$
    SELECT public.create_task(
      'research',
      'Find a useful answer',
      'test-create-call',
      'test-runner',
      '{"topic":"turn engines"}'::jsonb,
      2
    )
  $$,
  'a valid request creates a task'
);

SELECT results_eq(
  $$
    SELECT task.task_type, task.goal, task.status, task.priority, task.context->>'topic'
      FROM public.tasks AS task
      JOIN public.task_events AS event ON event.task_id = task.id
     WHERE event.event_type = 'task.created'
       AND event.call_id = 'test-create-call'
  $$,
  $$
    VALUES (
      'research'::text,
      'Find a useful answer'::text,
      'new'::text,
      2,
      'turn engines'::text
    )
  $$,
  'task creation stores the requested snapshot'
);

SELECT is(
  (
    SELECT event.outcome
      FROM public.task_events AS event
     WHERE event.event_type = 'task.created'
       AND event.call_id = 'test-create-call'
  ),
  'created',
  'task creation appends its provenance event'
);

SELECT is(
  (
    SELECT event.extracted_data->>'goal'
      FROM public.task_events AS event
     WHERE event.event_type = 'task.created'
       AND event.call_id = 'test-create-call'
  ),
  'Find a useful answer',
  'the creation event preserves the goal'
);

SELECT lives_ok(
  $$
    SELECT public.create_task(
      'different-type',
      'A conflicting replay must not replace the task',
      'test-create-call'
    )
  $$,
  'a repeated creation call is an idempotent success'
);

SELECT is(
  (
    SELECT count(*)::integer
      FROM public.task_events
     WHERE event_type = 'task.created'
       AND call_id = 'test-create-call'
  ),
  1,
  'a repeated creation call creates no duplicate task or event'
);

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

SELECT is(
  (
    SELECT extracted_data->>'result'
      FROM public.task_events
     WHERE task_id = '00000000-0000-0000-0000-000000000001'
       AND event_type = 'turn.completed'
  ),
  'done',
  'completion preserves its result on the event'
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

INSERT INTO public.tasks (id, task_type, goal)
VALUES ('00000000-0000-4000-8000-000000000100', 'test', 'Process one waiting turn');

SELECT lives_ok(
  $$
    SELECT public.process_task_turn(
      '00000000-0000-4000-8000-000000000100',
      'process-wait',
      'new',
      'waiting_user',
      'test-runner',
      'Which date works?',
      'User supplies a date'
    )
  $$,
  'one transaction can start and pause a turn'
);

SELECT is(
  (
    SELECT status
      FROM public.tasks
     WHERE id = '00000000-0000-4000-8000-000000000100'
  ),
  'waiting_user',
  'the processed turn finishes in waiting_user'
);

SELECT is(
  (
    SELECT count(*)::integer
      FROM public.task_events
     WHERE task_id = '00000000-0000-4000-8000-000000000100'
  ),
  2,
  'the processed waiting turn records start and decision events'
);

SELECT ok(
  (
    SELECT decision.parent_event_id = started.id
      FROM public.task_events AS decision
      JOIN public.task_events AS started
        ON started.task_id = decision.task_id
       AND started.event_type = 'turn.started'
     WHERE decision.task_id = '00000000-0000-4000-8000-000000000100'
       AND decision.event_type = 'turn.waiting_for_user'
  ),
  'the decision event links to its start event'
);

SELECT lives_ok(
  $$
    SELECT public.process_task_turn(
      '00000000-0000-4000-8000-000000000100',
      'process-wait',
      'new',
      'waiting_user',
      'test-runner',
      'A conflicting replay?',
      'Must not replace the original decision'
    )
  $$,
  'replaying a processed turn is an idempotent success'
);

SELECT is(
  (
    SELECT count(*)::integer
      FROM public.task_events
     WHERE task_id = '00000000-0000-4000-8000-000000000100'
  ),
  2,
  'replaying a processed turn creates no duplicate events'
);

INSERT INTO public.tasks (id, task_type, goal, status)
VALUES (
  '00000000-0000-4000-8000-000000000101',
  'test',
  'Process one completing turn',
  'ready'
);

SELECT lives_ok(
  $$
    SELECT public.process_task_turn(
      '00000000-0000-4000-8000-000000000101',
      'process-complete',
      'ready',
      'completed',
      'test-runner',
      NULL,
      NULL,
      'Atomic turn verified'
    )
  $$,
  'one transaction can start and complete a resumed turn'
);

SELECT results_eq(
  $$
    SELECT task.status, task.completed_at IS NOT NULL, event.extracted_data->>'result'
      FROM public.tasks AS task
      JOIN public.task_events AS event ON event.task_id = task.id
     WHERE task.id = '00000000-0000-4000-8000-000000000101'
       AND event.event_type = 'turn.completed'
  $$,
  $$ VALUES ('completed'::text, true, 'Atomic turn verified'::text) $$,
  'the processed completion stores its timestamp and result'
);

SELECT * FROM finish();
ROLLBACK;
