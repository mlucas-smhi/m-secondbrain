import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  validCallId,
} from "../_shared/turn-http.ts";

// Gateway JWT verification is disabled; runtimeConfig enforces X-Turn-Engine-Key.

type ClaimTaskStepRequest = {
  worker_id?: unknown;
  lease_seconds?: unknown;
  supported_step_types?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: ClaimTaskStepRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (!validCallId(body.worker_id)) return json(400, { error: "worker_id_required" });

  if (
    !Array.isArray(body.supported_step_types) ||
    body.supported_step_types.length === 0 ||
    !body.supported_step_types.every((value) => validCallId(value))
  ) {
    return json(400, { error: "supported_step_types_required" });
  }

  const leaseSeconds = body.lease_seconds ?? 300;
  if (
    !Number.isInteger(leaseSeconds) ||
    (leaseSeconds as number) < 30 ||
    (leaseSeconds as number) > 900
  ) {
    return json(400, { error: "invalid_lease_seconds" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "claim_task_step",
    {
      p_worker_id: body.worker_id.trim(),
      p_lease_seconds: leaseSeconds,
      p_step_types: body.supported_step_types.map((value) => value.trim()),
    },
  );

  if (!ok) {
    console.error("claim_task_step failed", result);
    return json(postgresStatus(result), { error: "step_not_claimed", details: result });
  }

  if (!Array.isArray(result)) {
    console.error("claim_task_step returned an invalid result", result);
    return json(502, { error: "invalid_claim_result" });
  }

  return json(200, { step: result[0] ?? null });
});
