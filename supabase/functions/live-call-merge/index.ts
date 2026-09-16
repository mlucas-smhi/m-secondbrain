import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

const WORKSPACE_ID = "00000000-0000-4000-8000-000000000001";

type MergeRequest = {
  action?: unknown;
  provider_call_ref?: unknown;
  target_session_id?: unknown;
  merge_request_id?: unknown;
  idempotency_key?: unknown;
  reason_summary?: unknown;
  approved?: unknown;
  actor_ref?: unknown;
  approval_evidence?: unknown;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: MergeRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (!validCallId(body.provider_call_ref)) {
    return json(400, { error: "provider_call_ref_required" });
  }

  let rpc: string;
  let params: Record<string, unknown>;
  if (body.action === "propose") {
    if (typeof body.target_session_id !== "string" ||
      !UUID_PATTERN.test(body.target_session_id)) {
      return json(400, { error: "invalid_target_session_id" });
    }
    if (!validCallId(body.idempotency_key)) {
      return json(400, { error: "idempotency_key_required" });
    }
    rpc = "propose_live_call_merge";
    params = {
      p_workspace_id: WORKSPACE_ID,
      p_requesting_provider_call_ref: body.provider_call_ref.trim(),
      p_target_session_id: body.target_session_id,
      p_idempotency_key: body.idempotency_key.trim(),
      p_reason_summary: typeof body.reason_summary === "string"
        ? body.reason_summary.slice(0, 500)
        : null,
      p_ttl_seconds: 90,
    };
  } else if (body.action === "answer") {
    if (typeof body.merge_request_id !== "string" ||
      !UUID_PATTERN.test(body.merge_request_id)) {
      return json(400, { error: "invalid_merge_request_id" });
    }
    if (typeof body.approved !== "boolean") {
      return json(400, { error: "approved_must_be_boolean" });
    }
    if (!validCallId(body.actor_ref)) return json(400, { error: "actor_ref_required" });
    if (body.approval_evidence !== undefined &&
      (body.approval_evidence === null || typeof body.approval_evidence !== "object" ||
        Array.isArray(body.approval_evidence))) {
      return json(400, { error: "invalid_approval_evidence" });
    }
    rpc = "answer_live_call_merge";
    params = {
      p_workspace_id: WORKSPACE_ID,
      p_merge_request_id: body.merge_request_id,
      p_requesting_provider_call_ref: body.provider_call_ref.trim(),
      p_approved: body.approved,
      p_actor_ref: body.actor_ref.trim(),
      p_approval_evidence: body.approval_evidence ?? {},
    };
  } else {
    return json(400, { error: "invalid_action" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    rpc,
    params,
  );
  if (!ok) {
    console.error(`${rpc} failed`, result);
    return json(postgresStatus(result), { error: "live_call_merge_failed" });
  }

  return json(200, {
    merge_request: result,
    execution: "disabled",
  });
});
