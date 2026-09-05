import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  validCallId,
} from "../_shared/turn-http.ts";

type ClaimDispatchRequest = { worker_id?: unknown };

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: ClaimDispatchRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (!validCallId(body.worker_id)) return json(400, { error: "worker_id_required" });

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "claim_task_dispatch",
    { p_worker_id: body.worker_id.trim() },
  );

  if (!ok) {
    console.error("claim_task_dispatch failed", result);
    return json(postgresStatus(result), { error: "dispatch_not_claimed", details: result });
  }

  if (!Array.isArray(result)) {
    console.error("claim_task_dispatch returned an invalid result", result);
    return json(502, { error: "invalid_claim_result" });
  }

  return json(200, { dispatch: result[0] ?? null });
});

