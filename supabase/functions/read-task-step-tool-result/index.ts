import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
} from "../_shared/turn-http.ts";

type ReadToolResultRequest = {
  step_id?: unknown;
  claim_token?: unknown;
  result_ref?: unknown;
};

const RESULT_REF_PATTERN = /^tool-result:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: ReadToolResultRequest;
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
  if (typeof body.result_ref !== "string" || !RESULT_REF_PATTERN.test(body.result_ref)) {
    return json(400, { error: "invalid_result_ref" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "read_task_step_tool_result",
    {
      p_step_id: body.step_id,
      p_claim_token: body.claim_token,
      p_result_ref: body.result_ref,
    },
  );

  if (!ok) {
    console.error("read_task_step_tool_result failed", result);
    return json(postgresStatus(result), { error: "tool_result_not_read", details: result });
  }

  return json(200, { result });
});
