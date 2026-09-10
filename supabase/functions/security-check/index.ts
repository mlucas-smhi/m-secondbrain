import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";

type SecurityCheckRequest = {
  workspace_id?: unknown;
  request_id?: unknown;
  action?: unknown;
  permission?: unknown;
  resource_sensitivity?: unknown;
  compartment?: unknown;
  actor_ref?: unknown;
  session_id?: unknown;
  task_id?: unknown;
  resource_owner_ref?: unknown;
  context?: unknown;
};

const PERMISSIONS = new Set(["read", "use", "disclose", "write", "correct", "delegate"]);

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: SecurityCheckRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.workspace_id !== "string" || !UUID_PATTERN.test(body.workspace_id)) {
    return json(400, { error: "invalid_workspace_id" });
  }
  if (!validCallId(body.request_id)) return json(400, { error: "request_id_required" });
  if (typeof body.action !== "string" || !body.action.trim()) {
    return json(400, { error: "action_required" });
  }
  if (typeof body.permission !== "string" || !PERMISSIONS.has(body.permission)) {
    return json(400, { error: "invalid_permission" });
  }
  if (!Number.isInteger(body.resource_sensitivity) || Number(body.resource_sensitivity) < 1 || Number(body.resource_sensitivity) > 3) {
    return json(400, { error: "invalid_resource_sensitivity" });
  }
  if (typeof body.compartment !== "string" || !body.compartment.trim()) {
    return json(400, { error: "compartment_required" });
  }
  if (body.context !== undefined &&
    (body.context === null || typeof body.context !== "object" || Array.isArray(body.context))) {
    return json(400, { error: "invalid_context" });
  }

  for (const field of ["session_id", "task_id"] as const) {
    if (body[field] !== undefined && body[field] !== null &&
      (typeof body[field] !== "string" || !UUID_PATTERN.test(body[field] as string))) {
      return json(400, { error: `invalid_${field}` });
    }
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "security_check",
    {
      p_workspace_id: body.workspace_id,
      p_request_id: body.request_id,
      p_action_key: body.action,
      p_requested_permission: body.permission,
      p_resource_sensitivity: body.resource_sensitivity,
      p_compartment: body.compartment,
      p_actor_ref: typeof body.actor_ref === "string" ? body.actor_ref : null,
      p_session_id: body.session_id ?? null,
      p_task_id: body.task_id ?? null,
      p_resource_owner_ref: typeof body.resource_owner_ref === "string" ? body.resource_owner_ref : null,
      p_context: body.context ?? {},
    },
  );

  if (!ok) {
    console.error("security_check failed", result);
    return json(postgresStatus(result), { error: "security_check_failed", details: result });
  }

  return json(200, result);
});
