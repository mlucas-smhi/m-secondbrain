import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

type ProcessTaskRequest = {
  task_id?: unknown;
  call_id?: unknown;
  expected_status?: unknown;
  outcome?: unknown;
  question?: unknown;
  resume_condition?: unknown;
  result?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: ProcessTaskRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.task_id !== "string" || !UUID_PATTERN.test(body.task_id)) {
    return json(400, { error: "invalid_task_id" });
  }
  if (!validCallId(body.call_id)) return json(400, { error: "call_id_required" });

  const expectedStatus = body.expected_status ?? "new";
  if (expectedStatus !== "new" && expectedStatus !== "ready") {
    return json(400, { error: "invalid_expected_status" });
  }

  if (body.outcome !== "waiting_user" && body.outcome !== "completed") {
    return json(400, { error: "invalid_outcome" });
  }

  if (body.outcome === "waiting_user") {
    if (typeof body.question !== "string" || body.question.trim().length === 0) {
      return json(400, { error: "question_required" });
    }
    if (
      typeof body.resume_condition !== "string" ||
      body.resume_condition.trim().length === 0
    ) {
      return json(400, { error: "resume_condition_required" });
    }
  } else if (typeof body.result !== "string" || body.result.trim().length === 0) {
    return json(400, { error: "result_required" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "process_task_turn",
    {
      p_task_id: body.task_id,
      p_call_id: body.call_id.trim(),
      p_expected_status: expectedStatus,
      p_outcome: body.outcome,
      p_actor: "process-task",
      p_question: typeof body.question === "string" ? body.question.trim() : null,
      p_resume_condition: typeof body.resume_condition === "string"
        ? body.resume_condition.trim()
        : null,
      p_result: typeof body.result === "string" ? body.result.trim() : null,
    },
  );

  if (!ok) {
    console.error("process_task_turn failed", result);
    return json(postgresStatus(result), { error: "turn_not_processed", details: result });
  }

  return json(200, { outcome: body.outcome, task: result });
});
