import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

type CompleteDispatchRequest = {
  dispatch_id?: unknown;
  worker_id?: unknown;
  result?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: CompleteDispatchRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.dispatch_id !== "string" || !UUID_PATTERN.test(body.dispatch_id)) {
    return json(400, { error: "invalid_dispatch_id" });
  }
  if (!validCallId(body.worker_id)) return json(400, { error: "worker_id_required" });
  if (
    body.result !== undefined &&
    (typeof body.result !== "object" || body.result === null || Array.isArray(body.result))
  ) {
    return json(400, { error: "invalid_result" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "complete_task_dispatch",
    {
      p_dispatch_id: body.dispatch_id,
      p_worker_id: body.worker_id.trim(),
      p_result: body.result ?? {},
    },
  );

  if (!ok) {
    console.error("complete_task_dispatch failed", result);
    return json(postgresStatus(result), { error: "dispatch_not_completed", details: result });
  }

  return json(200, { dispatch: result });
});

