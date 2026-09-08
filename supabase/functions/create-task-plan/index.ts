import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  validCallId,
} from "../_shared/turn-http.ts";

type CreateTaskPlanRequest = {
  call_id?: unknown;
  actor?: unknown;
  plan?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: CreateTaskPlanRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (!validCallId(body.call_id)) return json(400, { error: "call_id_required" });
  if (body.actor !== undefined && !validCallId(body.actor)) {
    return json(400, { error: "invalid_actor" });
  }
  if (body.plan === null || typeof body.plan !== "object" || Array.isArray(body.plan)) {
    return json(400, { error: "plan_object_required" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "create_task_plan",
    {
      p_plan: body.plan,
      p_call_id: body.call_id.trim(),
      p_actor: typeof body.actor === "string" ? body.actor.trim() : "task-planner",
    },
  );

  if (!ok) {
    console.error("create_task_plan failed", result);
    return json(postgresStatus(result), { error: "task_plan_not_created", details: result });
  }

  return json(200, result);
});
