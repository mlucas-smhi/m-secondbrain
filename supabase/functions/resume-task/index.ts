import {
  advanceTask,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

type ResumeTaskRequest = {
  task_id?: unknown;
  call_id?: unknown;
  answer?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: ResumeTaskRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.task_id !== "string" || !UUID_PATTERN.test(body.task_id)) {
    return json(400, { error: "invalid_task_id" });
  }
  if (!validCallId(body.call_id)) return json(400, { error: "call_id_required" });
  if (typeof body.answer !== "string" || body.answer.trim().length === 0) {
    return json(400, { error: "answer_required" });
  }

  const answer = body.answer.trim();
  const { ok, result } = await advanceTask(
    config.supabaseUrl,
    config.serviceRoleKey,
    {
      p_task_id: body.task_id,
      p_event_type: "user.responded",
      p_actor: "resume-task",
      p_call_id: body.call_id.trim(),
      p_expected_status: "waiting_user",
      p_patch: {
        status: "ready",
        current_step: "user-response-received",
        next_action: "Continue task",
        waiting_for: null,
        pending_question: null,
        resume_condition: null,
      },
      p_outcome: "input_received",
      p_extracted_data: { answer },
    },
  );

  if (!ok) {
    console.error("advance_task failed", result);
    return json(postgresStatus(result), { error: "task_not_resumed", details: result });
  }

  return json(200, { task: result });
});
