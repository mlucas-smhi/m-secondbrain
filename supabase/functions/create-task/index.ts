import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  validCallId,
} from "../_shared/turn-http.ts";

type CreateTaskRequest = {
  task_type?: unknown;
  goal?: unknown;
  call_id?: unknown;
  context?: unknown;
  priority?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: CreateTaskRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.task_type !== "string" || body.task_type.trim().length === 0) {
    return json(400, { error: "task_type_required" });
  }
  if (typeof body.goal !== "string" || body.goal.trim().length === 0) {
    return json(400, { error: "goal_required" });
  }
  if (!validCallId(body.call_id)) return json(400, { error: "call_id_required" });
  if (
    body.context !== undefined &&
    (typeof body.context !== "object" || body.context === null || Array.isArray(body.context))
  ) {
    return json(400, { error: "invalid_context" });
  }

  const priority = body.priority ?? 3;
  if (!Number.isInteger(priority) || (priority as number) < 1 || (priority as number) > 5) {
    return json(400, { error: "invalid_priority" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "create_task",
    {
      p_task_type: body.task_type.trim(),
      p_goal: body.goal.trim(),
      p_call_id: body.call_id.trim(),
      p_actor: "create-task",
      p_context: body.context ?? {},
      p_priority: priority,
    },
  );

  if (!ok) {
    console.error("create_task failed", result);
    return json(postgresStatus(result), { error: "task_not_created", details: result });
  }

  return json(201, { task: result });
});
