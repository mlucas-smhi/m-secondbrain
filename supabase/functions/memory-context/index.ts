import {
  callRpc,
  json,
  runtimeConfig,
  UUID_PATTERN,
  validCallId,
} from "../_shared/turn-http.ts";
import {
  GitMemoryProvider,
  type MemoryPermission,
  type MemoryRecord,
} from "../_shared/memory-provider.ts";

type MemoryContextRequest = {
  workspace_id?: unknown;
  request_id?: unknown;
  actor_ref?: unknown;
  session_id?: unknown;
  subject_ref?: unknown;
  query?: unknown;
  permission?: unknown;
  purpose?: unknown;
  task_id?: unknown;
  limit?: unknown;
};

type TrustResult = {
  decision?: string;
  reason_codes?: string[];
};

const MEMORY_PERMISSIONS = new Set<MemoryPermission>(["read", "use", "disclose"]);
const memoryProvider = new GitMemoryProvider();

function safeMemory(memory: MemoryRecord) {
  return {
    memory_ref: memory.id,
    subject_ref: memory.subject_ref,
    memory_type: memory.memory_type,
    content: memory.content,
    source_ref: memory.source_ref,
    valid_from: memory.valid_from,
    valid_until: memory.valid_until,
    supersedes: memory.supersedes,
  };
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: MemoryContextRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.workspace_id !== "string" || !UUID_PATTERN.test(body.workspace_id)) {
    return json(400, { error: "invalid_workspace_id" });
  }
  if (!validCallId(body.request_id)) return json(400, { error: "request_id_required" });
  if (typeof body.actor_ref !== "string" || !body.actor_ref.trim()) {
    return json(400, { error: "actor_ref_required" });
  }
  if (typeof body.session_id !== "string" || !UUID_PATTERN.test(body.session_id)) {
    return json(400, { error: "invalid_session_id" });
  }
  if (typeof body.subject_ref !== "string" || !body.subject_ref.trim()) {
    return json(400, { error: "subject_ref_required" });
  }
  if (typeof body.query !== "string" || !body.query.trim() || body.query.length > 500) {
    return json(400, { error: "invalid_query" });
  }
  if (typeof body.permission !== "string" ||
    !MEMORY_PERMISSIONS.has(body.permission as MemoryPermission)) {
    return json(400, { error: "invalid_permission" });
  }
  if (typeof body.purpose !== "string" || !body.purpose.trim() || body.purpose.length > 200) {
    return json(400, { error: "purpose_required" });
  }
  if (body.task_id !== undefined && body.task_id !== null &&
    (typeof body.task_id !== "string" || !UUID_PATTERN.test(body.task_id))) {
    return json(400, { error: "invalid_task_id" });
  }

  const limit = body.limit === undefined ? 5 : Number(body.limit);
  if (!Number.isInteger(limit) || limit < 1 || limit > 10) {
    return json(400, { error: "invalid_limit" });
  }

  const permission = body.permission as MemoryPermission;
  const candidates = await memoryProvider.search({
    subject_ref: body.subject_ref,
    query: body.query,
    limit,
    now: new Date(),
  });

  const authorized: ReturnType<typeof safeMemory>[] = [];
  const handling = new Set<string>();

  for (const candidate of candidates) {
    const { ok, result } = await callRpc(
      config.supabaseUrl,
      config.serviceRoleKey,
      "security_check",
      {
        p_workspace_id: body.workspace_id,
        p_request_id: `${body.request_id}:${candidate.id}`,
        p_action_key: permission === "disclose" ? "memory.disclose" : "memory.read",
        p_requested_permission: permission,
        p_resource_sensitivity: candidate.sensitivity_level,
        p_compartment: candidate.compartment,
        p_actor_ref: body.actor_ref,
        p_session_id: body.session_id,
        p_task_id: body.task_id ?? null,
        p_resource_owner_ref: candidate.owner_ref,
        p_context: { purpose: body.purpose, memory_ref: candidate.id },
      },
    );

    if (!ok) {
      console.error("memory authorization failed", { request_id: body.request_id, result });
      return json(502, { error: "memory_authorization_failed" });
    }

    const trust = result as TrustResult;
    if (trust.decision === "ALLOW" || trust.decision === "ALLOW_WITH_CONSTRAINTS") {
      authorized.push(safeMemory(candidate));
    } else if (trust.decision) {
      handling.add(trust.decision);
    }
  }

  const response: Record<string, unknown> = {
    provider: memoryProvider.providerKey,
    memories: authorized,
  };
  if (authorized.length === 0 && handling.size > 0) {
    response.handling = handling.has("DEFER") ? "DEFER" :
      handling.has("CHALLENGE") ? "CHALLENGE" : "NO_AUTHORIZED_CONTEXT";
  }

  return json(200, response);
});
