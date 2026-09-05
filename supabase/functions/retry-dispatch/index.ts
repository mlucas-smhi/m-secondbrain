import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

type RetryDispatchRequest = {
  dispatch_id?: unknown;
  worker_id?: unknown;
  error?: unknown;
  delay_seconds?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: RetryDispatchRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.dispatch_id !== "string" || !UUID_PATTERN.test(body.dispatch_id)) {
    return json(400, { error: "invalid_dispatch_id" });
  }
  if (!validCallId(body.worker_id)) return json(400, { error: "worker_id_required" });
  if (typeof body.error !== "string" || body.error.trim() === "") {
    return json(400, { error: "error_required" });
  }
  if (
    body.delay_seconds !== undefined &&
    (!Number.isInteger(body.delay_seconds) ||
      (body.delay_seconds as number) < 1 ||
      (body.delay_seconds as number) > 3600)
  ) {
    return json(400, { error: "invalid_delay_seconds" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "retry_task_dispatch",
    {
      p_dispatch_id: body.dispatch_id,
      p_worker_id: body.worker_id.trim(),
      p_error: body.error.trim(),
      p_delay_seconds: body.delay_seconds ?? 30,
    },
  );

  if (!ok) {
    console.error("retry_task_dispatch failed", result);
    return json(postgresStatus(result), { error: "dispatch_not_retried", details: result });
  }

  return json(200, { dispatch: result });
});

