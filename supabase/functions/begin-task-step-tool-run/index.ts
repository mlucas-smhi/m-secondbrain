import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

type BeginToolRunRequest = {
  step_id?: unknown;
  claim_token?: unknown;
  capability?: unknown;
  operation?: unknown;
  idempotency_key?: unknown;
  request_summary?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: BeginToolRunRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.step_id !== "string" || !UUID_PATTERN.test(body.step_id)) {
    return json(400, { error: "invalid_step_id" });
  }
  if (typeof body.claim_token !== "string" || !UUID_PATTERN.test(body.claim_token)) {
    return json(400, { error: "invalid_claim_token" });
  }
  if (!validCallId(body.capability)) return json(400, { error: "capability_required" });
  if (!validCallId(body.operation)) return json(400, { error: "operation_required" });
  if (!validCallId(body.idempotency_key)) {
    return json(400, { error: "idempotency_key_required" });
  }
  if (
    body.request_summary !== undefined &&
    (body.request_summary === null || typeof body.request_summary !== "object" ||
      Array.isArray(body.request_summary))
  ) {
    return json(400, { error: "invalid_request_summary" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "begin_task_step_tool_run",
    {
      p_step_id: body.step_id,
      p_claim_token: body.claim_token,
      p_capability: body.capability.trim(),
      p_operation: body.operation.trim(),
      p_idempotency_key: body.idempotency_key.trim(),
      p_request_summary: body.request_summary ?? {},
    },
  );

  if (!ok) {
    console.error("begin_task_step_tool_run failed", result);
    return json(postgresStatus(result), { error: "tool_run_not_started", details: result });
  }

  return json(200, result);
});
