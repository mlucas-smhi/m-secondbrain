import {
  advanceTask,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

type CompleteTaskRequest = {
  task_id?: unknown;
  call_id?: unknown;
  result?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: CompleteTaskRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.task_id !== "string" || !UUID_PATTERN.test(body.task_id)) {
    return json(400, { error: "invalid_task_id" });
  }
  if (!validCallId(body.call_id)) return json(400, { error: "call_id_required" });
  if (typeof body.result !== "string" || body.result.trim().length === 0) {
    return json(400, { error: "result_required" });
  }

  const resultSummary = body.result.trim();
  const { ok, result } = await advanceTask(
    config.supabaseUrl,
    config.serviceRoleKey,
    {
      p_task_id: body.task_id,
      p_event_type: "turn.completed",
      p_actor: "complete-task",
      p_call_id: body.call_id.trim(),
      p_expected_status: "running",
      p_patch: {
        status: "completed",
        current_step: "completed",
        next_action: null,
        waiting_for: null,
        pending_question: null,
        resume_condition: null,
        next_action_at: null,
      },
      p_outcome: "completed",
      p_extracted_data: { result: resultSummary },
    },
  );

  if (!ok) {
    console.error("advance_task failed", result);
    return json(postgresStatus(result), { error: "task_not_completed", details: result });
  }

  return json(200, { task: result });
});
