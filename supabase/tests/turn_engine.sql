BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;

SELECT plan(124);

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

SELECT throws_ok(
  $$
    SELECT public.advance_task(
      '00000000-0000-0000-0000-000000000001',
      'turn.started',
      'test-runner',
      'stale-call',
      'new',
      '{}'::jsonb
    )
  $$,
  'PT409',
  'stale task state: expected new, found running',
  'a stale expected status raises a non-retryable conflict'
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

INSERT INTO public.tasks (
  id, task_type, goal, status, waiting_for, pending_question, resume_condition
)
VALUES (
  '00000000-0000-4000-8000-000000000102', 'test',
  'Wake from a user response', 'waiting_user', 'user',
  'Which night works?', 'User supplies a night'
);

SELECT lives_ok(
  $$ SELECT public.wake_task(
    '00000000-0000-4000-8000-000000000102', 'user_response',
    'wake-user-1', '{"answer":"Friday"}'::jsonb, 'test-runner'
  ) $$,
  'a user response wakes a waiting_user task'
);

SELECT results_eq(
  $$ SELECT status, waiting_for, pending_question, resume_condition, next_action
       FROM public.tasks WHERE id = '00000000-0000-4000-8000-000000000102' $$,
  $$ VALUES ('ready'::text, NULL::text, NULL::text, NULL::text, 'Continue task'::text) $$,
  'waking makes the task ready and clears its pause state'
);

SELECT results_eq(
  $$ SELECT event_type, outcome, extracted_data->>'answer'
       FROM public.task_events WHERE task_id = '00000000-0000-4000-8000-000000000102' $$,
  $$ VALUES ('user.responded'::text, 'resumed'::text, 'Friday'::text) $$,
  'the wake event preserves its trigger data'
);

SELECT lives_ok(
  $$ SELECT public.wake_task(
    '00000000-0000-4000-8000-000000000102', 'user_response',
    'wake-user-1', '{"answer":"Saturday"}'::jsonb
  ) $$,
  'replaying a wake is an idempotent success'
);

SELECT is(
  (SELECT count(*)::integer FROM public.task_events
    WHERE task_id = '00000000-0000-4000-8000-000000000102'),
  1,
  'replaying a wake creates no duplicate event'
);

INSERT INTO public.tasks (
  id, task_type, goal, status, waiting_for, pending_question, resume_condition
)
VALUES (
  '00000000-0000-4000-8000-000000000106', 'test',
  'Gate downstream effects after wake', 'waiting_user', 'user',
  'Which day works?', 'User supplies a day'
);

SELECT is(
  (public.wake_task_delivery(
    '00000000-0000-4000-8000-000000000106', 'user_response',
    'wake-delivery-1', '{"answer":"Monday"}'::jsonb, 'test-runner'
  )->>'replayed')::boolean,
  false,
  'a newly applied delivery is marked as new'
);

SELECT is(
  public.wake_task_delivery(
    '00000000-0000-4000-8000-000000000106', 'user_response',
    'wake-delivery-1', '{"answer":"Tuesday"}'::jsonb, 'test-runner'
  )->>'replayed',
  'true',
  'a repeated delivery is marked as replayed'
);

SELECT is(
  public.wake_task_delivery(
    '00000000-0000-4000-8000-000000000106', 'user_response',
    'wake-delivery-1', '{"answer":"Tuesday"}'::jsonb, 'test-runner'
  )->'task'->>'status',
  'ready',
  'a replay returns the current task snapshot'
);

SELECT is(
  (SELECT count(*)::integer FROM public.task_events
    WHERE task_id = '00000000-0000-4000-8000-000000000106'),
  1,
  'the delivery wrapper creates only one wake event'
);

INSERT INTO public.tasks (id, task_type, goal, status, waiting_for)
VALUES (
  '00000000-0000-4000-8000-000000000103', 'test',
  'Wake from an external event', 'waiting_external', 'calendar'
);

SELECT lives_ok(
  $$ SELECT public.wake_task(
    '00000000-0000-4000-8000-000000000103', 'external_event',
    'wake-external-1', '{"event":"calendar.confirmed"}'::jsonb
  ) $$,
  'an external event wakes a waiting_external task'
);

SELECT is(
  (SELECT event_type FROM public.task_events
    WHERE task_id = '00000000-0000-4000-8000-000000000103'),
  'external.received',
  'an external wake records the correct event type'
);

INSERT INTO public.tasks (id, task_type, goal, status, next_action_at)
VALUES (
  '00000000-0000-4000-8000-000000000104', 'test',
  'Wake when a timer expires', 'retry_scheduled', now() - interval '1 minute'
);

SELECT lives_ok(
  $$ SELECT public.wake_task(
    '00000000-0000-4000-8000-000000000104', 'scheduled_time', 'wake-timer-1'
  ) $$,
  'a due scheduled task can be woken'
);

SELECT results_eq(
  $$ SELECT task.status, task.next_action_at, event.event_type
       FROM public.tasks AS task
       JOIN public.task_events AS event ON event.task_id = task.id
      WHERE task.id = '00000000-0000-4000-8000-000000000104' $$,
  $$ VALUES ('ready'::text, NULL::timestamptz, 'timer.elapsed'::text) $$,
  'a timer wake clears its schedule and records an event'
);

INSERT INTO public.tasks (id, task_type, goal, status, next_action_at)
VALUES (
  '00000000-0000-4000-8000-000000000105', 'test',
  'Reject an early timer', 'retry_scheduled', now() + interval '1 hour'
);

SELECT throws_ok(
  $$ SELECT public.wake_task(
    '00000000-0000-4000-8000-000000000105', 'scheduled_time', 'wake-timer-early'
  ) $$,
  'PT409', 'scheduled task is not due',
  'a scheduled task cannot wake early'
);

SELECT throws_ok(
  $$ SELECT public.wake_task(
    '00000000-0000-4000-8000-000000000105', 'external_event', 'wake-wrong-trigger'
  ) $$,
  'PT409', 'trigger external_event cannot wake task in status retry_scheduled',
  'a mismatched trigger cannot wake a task'
);

SELECT throws_ok(
  $$ SELECT public.wake_task(
    '00000000-0000-4000-8000-000000000105', 'unsupported', 'wake-invalid-trigger'
  ) $$,
  '22023', 'trigger_type must be user_response, external_event, or scheduled_time',
  'unsupported trigger types are rejected'
);

SELECT ok(
  has_function_privilege(
    'service_role',
    'public.advance_task(uuid,text,text,text,text,jsonb,text,jsonb,uuid)',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'anon',
    'public.advance_task(uuid,text,text,text,text,jsonb,text,jsonb,uuid)',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'authenticated',
    'public.advance_task(uuid,text,text,text,text,jsonb,text,jsonb,uuid)',
    'EXECUTE'
  ),
  'only service_role can execute advance_task through the API'
);

SELECT ok(
  has_function_privilege(
    'service_role',
    'public.process_task_turn(uuid,text,text,text,text,text,text,text)',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'anon',
    'public.process_task_turn(uuid,text,text,text,text,text,text,text)',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'authenticated',
    'public.process_task_turn(uuid,text,text,text,text,text,text,text)',
    'EXECUTE'
  ),
  'only service_role can execute process_task_turn through the API'
);

SELECT ok(
  has_function_privilege(
    'service_role',
    'public.wake_task(uuid,text,text,jsonb,text)',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'anon',
    'public.wake_task(uuid,text,text,jsonb,text)',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'authenticated',
    'public.wake_task(uuid,text,text,jsonb,text)',
    'EXECUTE'
  ),
  'only service_role can execute wake_task through the API'
);

SELECT ok(
  has_function_privilege(
    'service_role',
    'public.wake_task_delivery(uuid,text,text,jsonb,text)',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'anon',
    'public.wake_task_delivery(uuid,text,text,jsonb,text)',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'authenticated',
    'public.wake_task_delivery(uuid,text,text,jsonb,text)',
    'EXECUTE'
  ),
  'only service_role can execute the delivery-aware wake wrapper'
);

INSERT INTO public.tasks (id, task_type, goal)
VALUES (
  '00000000-0000-4000-8000-000000000107',
  'test',
  'Exercise the durable dispatch outbox'
);

SELECT lives_ok(
  $$ SELECT public.enqueue_task_dispatch(
    '00000000-0000-4000-8000-000000000107',
    'elevenlabs.outbound_call',
    'dispatch-call-1',
    '{"to_number":"+15555550100"}'::jsonb
  ) $$,
  'a valid side effect can be enqueued'
);

SELECT results_eq(
  $$ SELECT status, attempt_count, max_attempts, payload->>'to_number'
       FROM public.task_dispatches
      WHERE task_id = '00000000-0000-4000-8000-000000000107' $$,
  $$ VALUES ('pending'::text, 0, 3, '+15555550100'::text) $$,
  'a new dispatch starts pending with a bounded attempt count'
);

SELECT lives_ok(
  $$ SELECT public.enqueue_task_dispatch(
    '00000000-0000-4000-8000-000000000107',
    'different.type',
    'dispatch-call-1',
    '{"changed":true}'::jsonb
  ) $$,
  'replaying a dispatch dedupe key is an idempotent success'
);

SELECT is(
  (SELECT count(*)::integer
     FROM public.task_dispatches
    WHERE task_id = '00000000-0000-4000-8000-000000000107'),
  1,
  'an enqueue replay creates no duplicate dispatch'
);

SELECT is(
  (SELECT dispatch_type
     FROM public.task_dispatches
    WHERE task_id = '00000000-0000-4000-8000-000000000107'),
  'elevenlabs.outbound_call',
  'an enqueue replay does not replace the original intent'
);

SELECT is(
  (SELECT count(*)::integer FROM public.claim_task_dispatch('worker-a')),
  1,
  'one worker claims the pending dispatch'
);

SELECT results_eq(
  $$ SELECT status, attempt_count, locked_by, locked_at IS NOT NULL
       FROM public.task_dispatches
      WHERE task_id = '00000000-0000-4000-8000-000000000107' $$,
  $$ VALUES ('processing'::text, 1, 'worker-a'::text, true) $$,
  'claiming records ownership and the first attempt'
);

SELECT is(
  (SELECT count(*)::integer FROM public.claim_task_dispatch('worker-b')),
  0,
  'a claimed dispatch cannot be claimed by another worker'
);

SELECT throws_ok(
  $$ SELECT public.complete_task_dispatch(
    (SELECT id FROM public.task_dispatches
      WHERE task_id = '00000000-0000-4000-8000-000000000107'),
    'worker-b'
  ) $$,
  'PT409', 'dispatch is not owned by worker',
  'a different worker cannot complete the dispatch'
);

SELECT lives_ok(
  $$ SELECT public.retry_task_dispatch(
    (SELECT id FROM public.task_dispatches
      WHERE task_id = '00000000-0000-4000-8000-000000000107'),
    'worker-a', 'provider unavailable', 1
  ) $$,
  'the owning worker can schedule a bounded retry'
);

SELECT results_eq(
  $$ SELECT status, attempt_count, locked_by, last_error, available_at > now()
       FROM public.task_dispatches
      WHERE task_id = '00000000-0000-4000-8000-000000000107' $$,
  $$ VALUES ('pending'::text, 1, NULL::text, 'provider unavailable'::text, true) $$,
  'a retry releases the lock and records its delay and error'
);

UPDATE public.task_dispatches
   SET available_at = now() - interval '1 second'
 WHERE task_id = '00000000-0000-4000-8000-000000000107';

SELECT is(
  (SELECT count(*)::integer FROM public.claim_task_dispatch('worker-a')),
  1,
  'the same worker can claim the dispatch after its delay'
);

SELECT lives_ok(
  $$ SELECT public.complete_task_dispatch(
    (SELECT id FROM public.task_dispatches
      WHERE task_id = '00000000-0000-4000-8000-000000000107'),
    'worker-a', '{"provider_id":"call-123"}'::jsonb
  ) $$,
  'the owning worker can complete the dispatch'
);

SELECT results_eq(
  $$ SELECT status, attempt_count, locked_by, completed_at IS NOT NULL,
            result->>'provider_id'
       FROM public.task_dispatches
      WHERE task_id = '00000000-0000-4000-8000-000000000107' $$,
  $$ VALUES ('completed'::text, 2, NULL::text, true, 'call-123'::text) $$,
  'completion records the provider result and clears ownership'
);

INSERT INTO public.tasks (id, task_type, goal)
VALUES
  ('00000000-0000-4000-8000-000000000108', 'test', 'Recover an abandoned dispatch'),
  ('00000000-0000-4000-8000-000000000109', 'test', 'Fail an exhausted abandoned dispatch');

SELECT public.enqueue_task_dispatch(
  '00000000-0000-4000-8000-000000000108',
  'elevenlabs.outbound_call',
  'recover-call-1',
  '{}'::jsonb
);

SELECT is(
  (SELECT count(*)::integer FROM public.claim_task_dispatch('crashed-worker')),
  1,
  'a worker can claim a dispatch that will be abandoned'
);

UPDATE public.task_dispatches
   SET locked_at = now() - interval '6 minutes'
 WHERE task_id = '00000000-0000-4000-8000-000000000108';

SELECT results_eq(
  $$ SELECT task_id, status, attempt_count, locked_by
       FROM public.claim_task_dispatch('replacement-worker') $$,
  $$ VALUES (
       '00000000-0000-4000-8000-000000000108'::uuid,
       'processing'::text,
       2,
       'replacement-worker'::text
     ) $$,
  'claiming recovers an expired worker lease and transfers ownership'
);

SELECT public.enqueue_task_dispatch(
  '00000000-0000-4000-8000-000000000109',
  'elevenlabs.outbound_call',
  'exhaust-call-1',
  '{}'::jsonb,
  now(),
  1
);

SELECT is(
  (SELECT count(*)::integer FROM public.claim_task_dispatch('last-worker')),
  1,
  'a one-attempt dispatch can be claimed once'
);

UPDATE public.task_dispatches
   SET locked_at = now() - interval '6 minutes'
 WHERE task_id = '00000000-0000-4000-8000-000000000109';

SELECT is(
  (SELECT count(*)::integer FROM public.claim_task_dispatch('too-late-worker')),
  0,
  'an expired dispatch with no attempts remaining is not reclaimed'
);

SELECT results_eq(
  $$ SELECT status, locked_by, last_error
       FROM public.task_dispatches
      WHERE task_id = '00000000-0000-4000-8000-000000000109' $$,
  $$ VALUES ('failed'::text, NULL::text, 'worker lease expired'::text) $$,
  'an exhausted expired dispatch becomes a terminal failure'
);

INSERT INTO public.tasks (id, task_type, goal, status)
VALUES (
  '00000000-0000-4000-8000-000000000110',
  'travel',
  'Plan and communicate an approved trip',
  'ready'
);

INSERT INTO public.task_steps (
  id, task_id, step_key, step_type, status, priority, idempotency_key
) VALUES
  (
    '00000000-0000-4000-8000-000000000201',
    '00000000-0000-4000-8000-000000000110',
    'research-options', 'research.travel', 'ready', 2, 'travel-research-v1'
  ),
  (
    '00000000-0000-4000-8000-000000000202',
    '00000000-0000-4000-8000-000000000110',
    'send-options', 'email.send', 'pending', 1, 'travel-email-v1'
  );

INSERT INTO public.task_step_dependencies (task_id, step_id, depends_on_step_id)
VALUES (
  '00000000-0000-4000-8000-000000000110',
  '00000000-0000-4000-8000-000000000202',
  '00000000-0000-4000-8000-000000000201'
);

SELECT throws_ok(
  $$ INSERT INTO public.task_step_dependencies (
       task_id, step_id, depends_on_step_id
     ) VALUES (
       '00000000-0000-4000-8000-000000000110',
       '00000000-0000-4000-8000-000000000201',
       '00000000-0000-4000-8000-000000000202'
     ) $$,
  '22023',
  'task step dependency cycle detected',
  'the execution graph rejects dependency cycles'
);

INSERT INTO public.task_gates (id, task_id, gate_key, gate_type, condition)
VALUES (
  '00000000-0000-4000-8000-000000000301',
  '00000000-0000-4000-8000-000000000110',
  'hotel-choice',
  'decision',
  '{"question":"Which hotel?"}'::jsonb
);

INSERT INTO public.task_step_gates (task_id, step_id, gate_id)
VALUES (
  '00000000-0000-4000-8000-000000000110',
  '00000000-0000-4000-8000-000000000202',
  '00000000-0000-4000-8000-000000000301'
);

INSERT INTO public.task_decisions (
  id, task_id, gate_id, title, owner_ref, requested_by_ref, question,
  preference_dimension, recommendation_key
) VALUES (
  '00000000-0000-4000-8000-000000000401',
  '00000000-0000-4000-8000-000000000110',
  '00000000-0000-4000-8000-000000000301',
  'Hotel for NYC', 'person:m', 'agent:11', 'Which hotel should we book?',
  'location versus loyalty points', 'langham'
);

INSERT INTO public.task_decision_options (
  decision_id, option_key, label, tradeoffs, rank
) VALUES
  (
    '00000000-0000-4000-8000-000000000401',
    'four-seasons', 'Four Seasons', '{"strength":"loyalty"}'::jsonb, 2
  ),
  (
    '00000000-0000-4000-8000-000000000401',
    'langham', 'Langham', '{"strength":"location"}'::jsonb, 1
  );

SELECT results_eq(
  $$ SELECT id, status, attempt_count
       FROM public.claim_task_step('research-worker', 300) $$,
  $$ VALUES (
       '00000000-0000-4000-8000-000000000201'::uuid,
       'running'::text,
       1
     ) $$,
  'the first runnable step is claimed with one attempt'
);

SELECT ok(
  (SELECT claim_token IS NOT NULL FROM public.task_steps
    WHERE id = '00000000-0000-4000-8000-000000000201'),
  'a claimed step receives an opaque claim token'
);

SELECT is(
  (SELECT count(*)::integer FROM public.task_step_events
    WHERE step_id = '00000000-0000-4000-8000-000000000201'
      AND event_type = 'step.claimed'),
  1,
  'claiming appends one step event'
);

SELECT is(
  (SELECT count(*)::integer FROM public.claim_task_step('email-worker', 300)),
  0,
  'a dependent step is blocked until its prerequisite completes'
);

SELECT throws_ok(
  $$ SELECT public.complete_task_step(
       '00000000-0000-4000-8000-000000000201',
       '00000000-0000-4000-8000-000000000999',
       'research-complete-v1',
       '{}'::jsonb
     ) $$,
  'PT409',
  'task step claim is stale',
  'a stale claim token cannot complete a step'
);

SELECT results_eq(
  $$ SELECT status, output->>'summary'
       FROM public.complete_task_step(
         '00000000-0000-4000-8000-000000000201',
         (SELECT claim_token FROM public.task_steps
           WHERE id = '00000000-0000-4000-8000-000000000201'),
         'research-complete-v1',
         '{"schema_version":"research.v1","summary":"three options",
           "options":[{"key":"option-one","label":"Option one","summary":"Best fit."}],
           "recommendation":{"option_key":"option-one","rationale":"Best fit for the request."},
           "sources":[{"key":"source-one","title":"Primary source","url":"https://example.com/source"}]}'::jsonb
       ) $$,
  $$ VALUES ('completed'::text, 'three options'::text) $$,
  'the lease owner can complete a step'
);

SELECT results_eq(
  $$ SELECT status, output->>'summary'
       FROM public.complete_task_step(
         '00000000-0000-4000-8000-000000000201',
         NULL,
         'research-complete-v1',
         '{"summary":"ignored replay"}'::jsonb
       ) $$,
  $$ VALUES ('completed'::text, 'three options'::text) $$,
  'a completion replay returns the original step state'
);

SELECT is(
  (SELECT count(*)::integer FROM public.claim_task_step('email-worker', 300)),
  0,
  'a completed prerequisite does not bypass an unresolved decision gate'
);

SELECT throws_ok(
  $$ SELECT public.resolve_task_decision(
       '00000000-0000-4000-8000-000000000401',
       'person:m', 'ritz', 'Invalid option', 'hotel-decision-invalid'
     ) $$,
  '22023',
  'decision option not found',
  'a decision cannot resolve to an undeclared option'
);

SELECT throws_ok(
  $$ SELECT public.resolve_task_decision(
       '00000000-0000-4000-8000-000000000401',
       'person:someone-else', 'langham', 'Not the owner', 'hotel-wrong-owner'
     ) $$,
  'PT409',
  'decision actor is not owner',
  'only the declared decision owner can resolve it'
);

SELECT results_eq(
  $$ SELECT status, selected_option_key, resolution_note
       FROM public.resolve_task_decision(
         '00000000-0000-4000-8000-000000000401',
         'person:m', 'langham', 'Location matters more.', 'hotel-decision-v1'
       ) $$,
  $$ VALUES ('resolved'::text, 'langham'::text, 'Location matters more.'::text) $$,
  'resolving a decision records the selected option and rationale'
);

SELECT results_eq(
  $$ SELECT decision.status, gate.status
       FROM public.task_decisions AS decision
       JOIN public.task_gates AS gate ON gate.id = decision.gate_id
      WHERE decision.id = '00000000-0000-4000-8000-000000000401' $$,
  $$ VALUES ('resolved'::text, 'satisfied'::text) $$,
  'a resolved decision atomically satisfies its downstream gate'
);

SELECT is(
  (SELECT execution_status FROM public.tasks
    WHERE id = '00000000-0000-4000-8000-000000000110'),
  'ready',
  'satisfying the decision gate refreshes the parent task roll-up'
);

SELECT results_eq(
  $$ SELECT id, status, attempt_count
       FROM public.claim_task_step('email-worker', 300) $$,
  $$ VALUES (
       '00000000-0000-4000-8000-000000000202'::uuid,
       'running'::text,
       1
     ) $$,
  'completing a prerequisite makes its dependent step runnable'
);

SELECT is(
  (SELECT execution_status FROM public.tasks
    WHERE id = '00000000-0000-4000-8000-000000000110'),
  'running',
  'claiming a downstream step refreshes the parent task roll-up'
);

SELECT results_eq(
  $$ SELECT status, attempt_count, last_error
       FROM public.fail_task_step(
         '00000000-0000-4000-8000-000000000202',
         (SELECT claim_token FROM public.task_steps
           WHERE id = '00000000-0000-4000-8000-000000000202'),
         'email-failure-v1', 'temporary provider failure', 0
       ) $$,
  $$ VALUES ('ready'::text, 1, 'temporary provider failure'::text) $$,
  'a worker failure requeues a step that has attempts remaining'
);

SELECT is(
  (SELECT event_type FROM public.task_step_events
    WHERE step_id = '00000000-0000-4000-8000-000000000202'
      AND idempotency_key = 'email-failure-v1'),
  'step.retry_scheduled',
  'a retryable worker failure emits a durable retry event'
);

SELECT is(
  (SELECT status FROM public.fail_task_step(
    '00000000-0000-4000-8000-000000000202',
    '00000000-0000-4000-8000-000000000999',
    'email-failure-v1', 'duplicate delivery', 0)),
  'ready',
  'replaying the same failure idempotency key is harmless'
);

UPDATE public.task_steps
   SET max_attempts = 2
 WHERE id = '00000000-0000-4000-8000-000000000202';

SELECT results_eq(
  $$ SELECT status, attempt_count
       FROM public.claim_task_step('email-worker', 300) $$,
  $$ VALUES ('running'::text, 2) $$,
  'a requeued step can be claimed for its next attempt'
);

SELECT results_eq(
  $$ SELECT status, attempt_count, last_error
       FROM public.fail_task_step(
         '00000000-0000-4000-8000-000000000202',
         (SELECT claim_token FROM public.task_steps
           WHERE id = '00000000-0000-4000-8000-000000000202'),
         'email-failure-v2', 'permanent provider failure', 60
       ) $$,
  $$ VALUES ('failed'::text, 2, 'permanent provider failure'::text) $$,
  'a worker failure exhausts the configured attempt budget'
);

SELECT is(
  (SELECT event_type FROM public.task_step_events
    WHERE step_id = '00000000-0000-4000-8000-000000000202'
      AND idempotency_key = 'email-failure-v2'),
  'step.failed',
  'an exhausted worker failure emits a terminal event'
);

SELECT is(
  (SELECT execution_status FROM public.tasks
    WHERE id = '00000000-0000-4000-8000-000000000110'),
  'failed',
  'a terminal step failure refreshes the parent task roll-up'
);

SELECT lives_ok(
  $$ SELECT public.create_task_plan(
    '{
      "thread": {
        "subject": "NYC lodging request",
        "desired_outcome": "Select and prepare an approved NYC hotel booking",
        "owner_ref": "person:m"
      },
      "task": {
        "task_type": "travel",
        "goal": "Research two hotels and prepare the selected booking",
        "context": {"city":"New York","reason":"executive meeting"},
        "priority": 2
      },
      "participants": [
        {"actor_type":"person","actor_ref":"person:m","identity_confidence":"trusted","roles":["owner","approver"]},
        {"actor_type":"person","actor_ref":"person:ea","identity_confidence":"verified","roles":["initiator","requester"]}
      ],
      "steps": [
        {"key":"research-hotels","type":"research.travel","priority":1,"input":{"hotels":["Four Seasons","Langham"]}},
        {"key":"brief-owner","type":"briefing.prepare","priority":2},
        {"key":"prepare-booking","type":"reservation.prepare","priority":2}
      ],
      "dependencies": [
        {"step_key":"brief-owner","depends_on_step_key":"research-hotels"},
        {"step_key":"prepare-booking","depends_on_step_key":"brief-owner"}
      ],
      "decisions": [{
        "key":"hotel-choice",
        "title":"Hotel for NYC",
        "owner_ref":"person:m",
        "requested_by_ref":"person:ea",
        "question":"Four Seasons or Langham?",
        "preference_dimension":"location versus loyalty points",
        "recommendation_key":"langham",
        "blocks":["prepare-booking"],
        "options":[
          {"key":"four-seasons","label":"Four Seasons","tradeoffs":{"strength":"loyalty"},"rank":2},
          {"key":"langham","label":"Langham","tradeoffs":{"strength":"location"},"rank":1}
        ]
      }],
      "closure_recipients": [
        {"recipient_ref":"person:m","channel":"voice","delivery_policy":"on_terminal"},
        {"recipient_ref":"person:ea","channel":"email","delivery_policy":"on_terminal"}
      ]
    }'::jsonb,
    'hotel-plan-v1',
    'planner-test'
  ) $$,
  'a structured request atomically creates a task execution plan'
);

SELECT is(
  (SELECT thread.subject FROM public.threads AS thread
    JOIN public.tasks AS task ON task.thread_id = thread.id
    JOIN public.task_events AS event ON event.task_id = task.id
   WHERE event.call_id = 'hotel-plan-v1'),
  'NYC lodging request',
  'the plan preserves the durable thread subject'
);

SELECT is(
  (SELECT count(*)::integer FROM public.task_steps
   WHERE task_id = (SELECT task_id FROM public.task_events WHERE call_id = 'hotel-plan-v1')),
  3,
  'the plan creates every declared step'
);

SELECT is(
  (SELECT count(*)::integer FROM public.task_step_dependencies
   WHERE task_id = (SELECT task_id FROM public.task_events WHERE call_id = 'hotel-plan-v1')),
  2,
  'the plan creates explicit step dependencies'
);

SELECT is(
  (SELECT count(*)::integer FROM public.task_decision_options AS option
    JOIN public.task_decisions AS decision ON decision.id = option.decision_id
   WHERE decision.task_id = (SELECT task_id FROM public.task_events WHERE call_id = 'hotel-plan-v1')),
  2,
  'the plan creates the declared decision options'
);

SELECT is(
  (SELECT count(*)::integer FROM public.task_step_gates
   WHERE task_id = (SELECT task_id FROM public.task_events WHERE call_id = 'hotel-plan-v1')),
  1,
  'the decision gate blocks its declared downstream step'
);

SELECT is(
  (SELECT count(*)::integer FROM public.task_closure_recipients
   WHERE task_id = (SELECT task_id FROM public.task_events WHERE call_id = 'hotel-plan-v1')),
  2,
  'the plan records everyone who must receive closure'
);

SELECT is(
  (SELECT count(*)::integer
     FROM public.claim_task_step('call-only-worker', 300, ARRAY['elevenlabs.outbound_call'])),
  0,
  'a worker cannot claim a runnable step type it does not advertise'
);

SELECT is(
  (SELECT step_key FROM public.claim_task_step('planner-worker', 300, ARRAY['research.travel'])),
  'research-hotels',
  'only the first dependency-safe planned step is runnable'
);

SELECT throws_ok(
  $$ SELECT public.complete_task_step(
    (SELECT id FROM public.task_steps WHERE idempotency_key = 'hotel-plan-v1:step:research-hotels'),
    (SELECT claim_token FROM public.task_steps WHERE idempotency_key = 'hotel-plan-v1:step:research-hotels'),
    'hotel-research-invalid-schema',
    '{"summary":"Compared two hotels."}'::jsonb
  ) $$,
  '22023',
  'research output schema_version must be research.v1',
  'research completion rejects an unversioned result'
);

SELECT throws_ok(
  $$ SELECT public.complete_task_step(
    (SELECT id FROM public.task_steps WHERE idempotency_key = 'hotel-plan-v1:step:research-hotels'),
    (SELECT claim_token FROM public.task_steps WHERE idempotency_key = 'hotel-plan-v1:step:research-hotels'),
    'hotel-research-invalid-recommendation',
    '{"schema_version":"research.v1","summary":"Compared two hotels.",
      "options":[{"key":"langham","label":"Langham","summary":"Closer to the meeting."}],
      "recommendation":{"option_key":"four-seasons","rationale":"Prefer loyalty."},
      "sources":[{"key":"langham-site","title":"Langham New York","url":"https://example.com/langham"}]}'::jsonb
  ) $$,
  '22023',
  'research recommendation must reference a declared option',
  'research completion rejects a recommendation outside its option set'
);

SELECT results_eq(
  $$ SELECT status, output->>'schema_version', output->'recommendation'->>'option_key'
       FROM public.complete_task_step(
         (SELECT id FROM public.task_steps WHERE idempotency_key = 'hotel-plan-v1:step:research-hotels'),
         (SELECT claim_token FROM public.task_steps WHERE idempotency_key = 'hotel-plan-v1:step:research-hotels'),
         'hotel-research-complete-v1',
         '{"schema_version":"research.v1","summary":"The Langham best fits the location preference.",
           "options":[
             {"key":"four-seasons","label":"Four Seasons","summary":"Strong loyalty benefits.","attributes":{"strength":"loyalty"}},
             {"key":"langham","label":"Langham","summary":"Closer to the meeting.","attributes":{"strength":"location"}}
           ],
           "recommendation":{"option_key":"langham","rationale":"Location matters most for this trip."},
           "sources":[{"key":"hotel-sites","title":"Official hotel sites","url":"https://example.com/hotels"}],
           "constraints":{"city":"New York"},"caveats":[]}'::jsonb
       ) $$,
  $$ VALUES ('completed'::text, 'research.v1'::text, 'langham'::text) $$,
  'a valid versioned research result completes the step'
);

SELECT is(
  (SELECT count(*)::integer FROM public.task_step_events
    WHERE idempotency_key = 'hotel-research-complete-v1'),
  1,
  'accepted research output produces one durable completion event'
);

SELECT lives_ok(
  $$ SELECT public.create_task_plan(
    (SELECT jsonb_build_object(
      'thread', jsonb_build_object('subject', thread.subject, 'desired_outcome', thread.desired_outcome),
      'task', jsonb_build_object('task_type', task.task_type, 'goal', task.goal),
      'steps', '[]'::jsonb
    ) FROM public.tasks AS task JOIN public.threads AS thread ON thread.id = task.thread_id LIMIT 1),
    'hotel-plan-v1', 'planner-replay'
  ) $$,
  'a replay returns the existing plan before revalidating its body'
);

SELECT is(
  (SELECT count(*)::integer FROM public.task_events
   WHERE event_type = 'task.planned' AND call_id = 'hotel-plan-v1'),
  1,
  'a replay cannot duplicate the planned task'
);

SELECT throws_ok(
  $$ SELECT public.create_task_plan(
    '{"thread":{"subject":"Bad plan","desired_outcome":"Nothing persists"},
      "task":{"task_type":"test","goal":"Reject invalid graph"},
      "steps":[{"key":"only-step","type":"test.noop"}],
      "dependencies":[{"step_key":"missing-step","depends_on_step_key":"only-step"}]}'::jsonb,
    'invalid-plan-v1', 'planner-test'
  ) $$,
  '22023',
  'dependency references an unknown step',
  'an invalid dependency rejects the entire plan'
);

SELECT is(
  (SELECT count(*)::integer FROM public.threads WHERE subject = 'Bad plan'),
  0,
  'a rejected plan leaves no partial thread behind'
);

SELECT lives_ok(
  $$
    INSERT INTO public.thread_participants (
      thread_id, actor_type, actor_ref, identity_confidence, roles
    ) VALUES (
      (SELECT thread_id FROM public.tasks
        WHERE id = '00000000-0000-4000-8000-000000000110'),
      'person', 'person:m', 'trusted', ARRAY['initiator', 'owner', 'approver']
    );
    INSERT INTO public.task_authority_grants (
      task_id, grantee_ref, granted_by_ref, scope
    ) VALUES (
      '00000000-0000-4000-8000-000000000110',
      'agent:11', 'person:m', '{"email.send":true}'::jsonb
    );
    INSERT INTO public.task_approvals (
      task_id, step_id, requested_from_ref, scope, request_idempotency_key
    ) VALUES (
      '00000000-0000-4000-8000-000000000110',
      '00000000-0000-4000-8000-000000000202',
      'person:m', '{"action":"email.send"}'::jsonb, 'approval-email-v1'
    );
    INSERT INTO public.task_closure_recipients (
      task_id, recipient_ref, channel, delivery_policy
    ) VALUES (
      '00000000-0000-4000-8000-000000000110',
      'person:m', 'voice', 'on_terminal'
    );
    INSERT INTO public.task_memory_refs (
      task_id, provider, namespace, external_ref, purpose
    ) VALUES (
      '00000000-0000-4000-8000-000000000110',
      'memory-service', 'preferences', 'memory:travel:primary', 'planning'
    );
  $$,
  'task governance and provider-neutral memory references can be recorded'
);

SELECT is(
  (SELECT participant.identity_confidence
     FROM public.thread_participants AS participant
     JOIN public.tasks AS task ON task.thread_id = participant.thread_id
    WHERE task.id = '00000000-0000-4000-8000-000000000110'
      AND participant.actor_ref = 'person:m'),
  'trusted',
  'the initiator record preserves identity confidence'
);

SELECT is(
  (SELECT scope->>'email.send' FROM public.task_authority_grants
    WHERE task_id = '00000000-0000-4000-8000-000000000110'),
  'true',
  'authority is stored as an explicit scoped grant'
);

SELECT is(
  (SELECT status FROM public.task_approvals
    WHERE task_id = '00000000-0000-4000-8000-000000000110'),
  'pending',
  'approval requests begin pending'
);

SELECT is(
  (SELECT delivery_policy FROM public.task_closure_recipients
    WHERE task_id = '00000000-0000-4000-8000-000000000110'),
  'on_terminal',
  'closure recipients have an explicit delivery policy'
);

SELECT is(
  (SELECT provider FROM public.task_memory_refs
    WHERE task_id = '00000000-0000-4000-8000-000000000110'),
  'memory-service',
  'task memory references are not coupled to GitHub'
);

SELECT lives_ok(
  $$
    INSERT INTO public.tool_adapters (
      workspace_id, adapter_key, provider, transport, capabilities,
      credential_ref, configuration
    ) VALUES (
      '00000000-0000-4000-8000-000000000001',
      'travel-inventory-primary', 'future-travel-provider', 'mcp',
      ARRAY['travel.hotel.search', 'travel.hotel.details'],
      'secret-manager:n8n/travel-inventory',
      '{"region":"global"}'::jsonb
    );
  $$,
  'a workspace can register an MCP adapter without storing its secret'
);

SELECT is(
  (SELECT transport FROM public.tool_adapters
    WHERE adapter_key = 'travel-inventory-primary'),
  'mcp',
  'an adapter records its replaceable transport'
);

SELECT is(
  (SELECT credential_ref FROM public.tool_adapters
    WHERE adapter_key = 'travel-inventory-primary'),
  'secret-manager:n8n/travel-inventory',
  'an adapter stores only an external credential reference'
);

SELECT lives_ok(
  $$
    INSERT INTO public.task_step_tool_requirements (
      task_id, step_id, capability, access_mode, preferred_adapter_id,
      constraints
    )
    SELECT step.task_id, step.id, 'travel.hotel.search', 'read', adapter.id,
           '{"live_inventory":true}'::jsonb
      FROM public.task_steps AS step
      CROSS JOIN public.tool_adapters AS adapter
     WHERE step.idempotency_key = 'hotel-plan-v1:step:research-hotels'
       AND adapter.adapter_key = 'travel-inventory-primary';
  $$,
  'a research step declares a read-only travel capability requirement'
);

SELECT is(
  (SELECT access_mode FROM public.task_step_tool_requirements AS requirement
    JOIN public.task_steps AS step ON step.id = requirement.step_id
   WHERE step.idempotency_key = 'hotel-plan-v1:step:research-hotels'
     AND requirement.capability = 'travel.hotel.search'),
  'read',
  'research cannot silently inherit booking authority'
);

SELECT lives_ok(
  $$
    INSERT INTO public.task_step_tool_runs (
      task_id, step_id, adapter_id, capability, operation, status,
      idempotency_key, external_run_id, request_summary, result_ref,
      evidence, completed_at
    )
    SELECT step.task_id, step.id, adapter.id, 'travel.hotel.search',
           'search New York hotels', 'completed', 'hotel-search-run-v1',
           'provider-run-123', '{"city":"New York","hotel_count":2}'::jsonb,
           'object-store:research/provider-run-123',
           '{"result_count":2,"retrieved_at":"2026-09-08T23:30:00Z"}'::jsonb,
           now()
      FROM public.task_steps AS step
      CROSS JOIN public.tool_adapters AS adapter
     WHERE step.idempotency_key = 'hotel-plan-v1:step:research-hotels'
       AND adapter.adapter_key = 'travel-inventory-primary';
  $$,
  'a tool call records bounded provenance while raw results live externally'
);

SELECT is(
  (SELECT result_ref FROM public.task_step_tool_runs
    WHERE idempotency_key = 'hotel-search-run-v1'),
  'object-store:research/provider-run-123',
  'large provider results use a provider-neutral external reference'
);

SELECT throws_ok(
  $$
    INSERT INTO public.task_step_tool_requirements (
      task_id, step_id, capability, access_mode
    )
    SELECT task_id, id, 'travel.hotel.book', 'purchase'
      FROM public.task_steps
     WHERE idempotency_key = 'hotel-plan-v1:step:research-hotels'
  $$,
  '23514',
  NULL,
  'unsupported authority modes are rejected by the durable tool layer'
);

SELECT * FROM finish();
ROLLBACK;
