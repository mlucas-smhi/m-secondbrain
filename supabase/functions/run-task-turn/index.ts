import {
  advanceTask,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

type RunTaskTurnRequest = {
  task_id?: unknown;
  call_id?: unknown;
  expected_status?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return json(405, { error: "method_not_allowed" });
  }

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: RunTaskTurnRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.task_id !== "string" || !UUID_PATTERN.test(body.task_id)) {
    return json(400, { error: "invalid_task_id" });
  }

  if (!validCallId(body.call_id)) {
    return json(400, { error: "call_id_required" });
  }

  const expectedStatus = body.expected_status ?? "new";
  if (expectedStatus !== "new" && expectedStatus !== "ready") {
    return json(400, { error: "invalid_expected_status" });
  }

  const { ok, result } = await advanceTask(
    config.supabaseUrl,
    config.serviceRoleKey,
    {
      p_task_id: body.task_id,
      p_event_type: "turn.started",
      p_actor: "run-task-turn",
      p_call_id: body.call_id.trim(),
      p_expected_status: expectedStatus,
      p_patch: {
        status: "running",
        current_step: "run-task-turn",
      },
    },
  );

  if (!ok) {
    console.error("advance_task failed", result);
    return json(postgresStatus(result), {
      error: "turn_not_advanced",
      details: result,
    });
  }

  return json(200, { task: result });
});
