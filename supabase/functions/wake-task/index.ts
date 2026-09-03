import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

type WakeTaskRequest = {
  task_id?: unknown;
  trigger_type?: unknown;
  call_id?: unknown;
  data?: unknown;
};

const TRIGGER_TYPES = new Set(["user_response", "external_event", "scheduled_time"]);

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: WakeTaskRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.task_id !== "string" || !UUID_PATTERN.test(body.task_id)) {
    return json(400, { error: "invalid_task_id" });
  }
  if (typeof body.trigger_type !== "string" || !TRIGGER_TYPES.has(body.trigger_type)) {
    return json(400, { error: "invalid_trigger_type" });
  }
  if (!validCallId(body.call_id)) return json(400, { error: "call_id_required" });
  if (
    body.data !== undefined &&
    (typeof body.data !== "object" || body.data === null || Array.isArray(body.data))
  ) {
    return json(400, { error: "invalid_data" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "wake_task",
    {
      p_task_id: body.task_id,
      p_trigger_type: body.trigger_type,
      p_call_id: body.call_id.trim(),
      p_data: body.data ?? {},
      p_actor: "wake-task",
    },
  );

  if (!ok) {
    console.error("wake_task failed", result);
    return json(postgresStatus(result), { error: "task_not_woken", details: result });
  }

  return json(200, { outcome: "ready", trigger_type: body.trigger_type, task: result });
});
