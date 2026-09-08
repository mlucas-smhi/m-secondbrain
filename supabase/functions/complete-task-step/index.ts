import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

type CompleteTaskStepRequest = {
  step_id?: unknown;
  claim_token?: unknown;
  idempotency_key?: unknown;
  output?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: CompleteTaskStepRequest;
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
  if (!validCallId(body.idempotency_key)) {
    return json(400, { error: "idempotency_key_required" });
  }
  if (
    body.output !== undefined &&
    (body.output === null || typeof body.output !== "object" || Array.isArray(body.output))
  ) {
    return json(400, { error: "invalid_output" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "complete_task_step",
    {
      p_step_id: body.step_id,
      p_claim_token: body.claim_token,
      p_idempotency_key: body.idempotency_key.trim(),
      p_output: body.output ?? {},
    },
  );

  if (!ok) {
    console.error("complete_task_step failed", result);
    return json(postgresStatus(result), { error: "step_not_completed", details: result });
  }

  return json(200, { step: result });
});
