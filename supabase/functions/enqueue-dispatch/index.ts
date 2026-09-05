import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

type EnqueueDispatchRequest = {
  task_id?: unknown;
  dispatch_type?: unknown;
  dedupe_key?: unknown;
  payload?: unknown;
  available_at?: unknown;
  max_attempts?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: EnqueueDispatchRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.task_id !== "string" || !UUID_PATTERN.test(body.task_id)) {
    return json(400, { error: "invalid_task_id" });
  }
  if (typeof body.dispatch_type !== "string" || body.dispatch_type.trim() === "") {
    return json(400, { error: "dispatch_type_required" });
  }
  if (!validCallId(body.dedupe_key)) return json(400, { error: "dedupe_key_required" });
  if (
    body.payload !== undefined &&
    (typeof body.payload !== "object" || body.payload === null || Array.isArray(body.payload))
  ) {
    return json(400, { error: "invalid_payload" });
  }
  if (
    body.available_at !== undefined &&
    (typeof body.available_at !== "string" || Number.isNaN(Date.parse(body.available_at)))
  ) {
    return json(400, { error: "invalid_available_at" });
  }
  if (
    body.max_attempts !== undefined &&
    (!Number.isInteger(body.max_attempts) ||
      (body.max_attempts as number) < 1 ||
      (body.max_attempts as number) > 10)
  ) {
    return json(400, { error: "invalid_max_attempts" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "enqueue_task_dispatch",
    {
      p_task_id: body.task_id,
      p_dispatch_type: body.dispatch_type.trim(),
      p_dedupe_key: body.dedupe_key.trim(),
      p_payload: body.payload ?? {},
      p_available_at: body.available_at ?? new Date().toISOString(),
      p_max_attempts: body.max_attempts ?? 3,
    },
  );

  if (!ok) {
    console.error("enqueue_task_dispatch failed", result);
    return json(postgresStatus(result), { error: "dispatch_not_enqueued", details: result });
  }

  return json(200, { dispatch: result });
});

