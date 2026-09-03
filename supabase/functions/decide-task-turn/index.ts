import {
  advanceTask,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

type DecideTaskTurnRequest = {
  task_id?: unknown;
  call_id?: unknown;
  outcome?: unknown;
  question?: unknown;
  resume_condition?: unknown;
  result?: unknown;
};

type Decision = {
  eventType: "turn.waiting_for_user" | "turn.completed";
  outcome: "needs_input" | "completed";
  patch: Record<string, unknown>;
  extractedData: Record<string, unknown>;
};

function decisionFor(body: DecideTaskTurnRequest): Decision | Response {
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

    return {
      eventType: "turn.waiting_for_user",
      outcome: "needs_input",
      patch: {
        status: "waiting_user",
        current_step: "wait-for-user",
        next_action: "Await user response",
        waiting_for: "user",
        pending_question: body.question.trim(),
        resume_condition: body.resume_condition.trim(),
      },
      extractedData: {},
    };
  }

  if (body.outcome === "completed") {
    if (typeof body.result !== "string" || body.result.trim().length === 0) {
      return json(400, { error: "result_required" });
    }

    return {
      eventType: "turn.completed",
      outcome: "completed",
      patch: {
        status: "completed",
        current_step: "completed",
        next_action: null,
        waiting_for: null,
        pending_question: null,
        resume_condition: null,
        next_action_at: null,
      },
      extractedData: { result: body.result.trim() },
    };
  }

  return json(400, { error: "invalid_outcome" });
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: DecideTaskTurnRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.task_id !== "string" || !UUID_PATTERN.test(body.task_id)) {
    return json(400, { error: "invalid_task_id" });
  }
  if (!validCallId(body.call_id)) return json(400, { error: "call_id_required" });

  const decision = decisionFor(body);
  if (decision instanceof Response) return decision;

  const { ok, result } = await advanceTask(
    config.supabaseUrl,
    config.serviceRoleKey,
    {
      p_task_id: body.task_id,
      p_event_type: decision.eventType,
      p_actor: "decide-task-turn",
      p_call_id: body.call_id.trim(),
      p_expected_status: "running",
      p_patch: decision.patch,
      p_outcome: decision.outcome,
      p_extracted_data: decision.extractedData,
    },
  );

  if (!ok) {
    console.error("advance_task failed", result);
    return json(postgresStatus(result), { error: "decision_not_applied", details: result });
  }

  return json(200, { decision: body.outcome, task: result });
});
