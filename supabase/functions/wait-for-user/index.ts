import {
  advanceTask,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

type WaitForUserRequest = {
  task_id?: unknown;
  call_id?: unknown;
  question?: unknown;
  resume_condition?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: WaitForUserRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.task_id !== "string" || !UUID_PATTERN.test(body.task_id)) {
    return json(400, { error: "invalid_task_id" });
  }
  if (!validCallId(body.call_id)) return json(400, { error: "call_id_required" });
  if (typeof body.question !== "string" || body.question.trim().length === 0) {
    return json(400, { error: "question_required" });
  }
  if (
    typeof body.resume_condition !== "string" ||
    body.resume_condition.trim().length === 0
  ) {
    return json(400, { error: "resume_condition_required" });
  }

  const { ok, result } = await advanceTask(
    config.supabaseUrl,
    config.serviceRoleKey,
    {
      p_task_id: body.task_id,
      p_event_type: "turn.waiting_for_user",
      p_actor: "wait-for-user",
      p_call_id: body.call_id.trim(),
      p_expected_status: "running",
      p_patch: {
        status: "waiting_user",
        current_step: "wait-for-user",
        next_action: "Await user response",
        waiting_for: "user",
        pending_question: body.question.trim(),
        resume_condition: body.resume_condition.trim(),
      },
      p_outcome: "needs_input",
    },
  );

  if (!ok) {
    console.error("advance_task failed", result);
    return json(postgresStatus(result), { error: "task_not_paused", details: result });
  }

  return json(200, { task: result });
});
