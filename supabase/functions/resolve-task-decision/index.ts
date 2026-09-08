import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

type ResolveTaskDecisionRequest = {
  decision_id?: unknown;
  actor_ref?: unknown;
  option_key?: unknown;
  resolution_note?: unknown;
  idempotency_key?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: ResolveTaskDecisionRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.decision_id !== "string" || !UUID_PATTERN.test(body.decision_id)) {
    return json(400, { error: "invalid_decision_id" });
  }
  if (!validCallId(body.actor_ref)) return json(400, { error: "actor_ref_required" });
  if (!validCallId(body.option_key)) return json(400, { error: "option_key_required" });
  if (!validCallId(body.idempotency_key)) {
    return json(400, { error: "idempotency_key_required" });
  }
  if (body.resolution_note !== undefined && typeof body.resolution_note !== "string") {
    return json(400, { error: "invalid_resolution_note" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "resolve_task_decision",
    {
      p_decision_id: body.decision_id,
      p_actor_ref: body.actor_ref.trim(),
      p_option_key: body.option_key.trim(),
      p_resolution_note: typeof body.resolution_note === "string"
        ? body.resolution_note.trim()
        : null,
      p_idempotency_key: body.idempotency_key.trim(),
    },
  );

  if (!ok) {
    console.error("resolve_task_decision failed", result);
    return json(postgresStatus(result), { error: "decision_not_resolved", details: result });
  }

  return json(200, { decision: result });
});
