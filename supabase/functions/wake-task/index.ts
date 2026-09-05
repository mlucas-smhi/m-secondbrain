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
    "wake_task_delivery",
    {
      p_task_id: body.task_id,
      p_trigger_type: body.trigger_type,
      p_call_id: body.call_id.trim(),
      p_data: body.data ?? {},
      p_actor: "wake-task",
    },
  );

  if (!ok) {
    console.error("wake_task_delivery failed", result);
    return json(postgresStatus(result), { error: "task_not_woken", details: result });
  }

  const delivery = result as { task?: unknown; replayed?: unknown } | null;
  if (
    !delivery ||
    typeof delivery !== "object" ||
    typeof delivery.replayed !== "boolean" ||
    !("task" in delivery)
  ) {
    console.error("wake_task_delivery returned an invalid result", result);
    return json(502, { error: "invalid_wake_result" });
  }

  return json(200, {
    outcome: delivery.replayed ? "replayed" : "ready",
    trigger_type: body.trigger_type,
    replayed: delivery.replayed,
    task: delivery.task,
  });
});
