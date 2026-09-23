import {
  callRpc,
  json,
  normalizeIdentifier,
  onboardingConfig,
  validInviteId,
} from "../_shared/onboarding.ts";

type ResolveRequest = {
  workspace_id?: unknown;
  identifier_type?: unknown;
  identifier?: unknown;
  external_session_ref?: unknown;
  channel?: unknown;
};

const CHANNELS = new Set(["phone", "sms", "email", "web"]);

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });
  const config = onboardingConfig(request);
  if (config instanceof Response) return config;

  let body: ResolveRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  const identifier = normalizeIdentifier(body.identifier_type, body.identifier);
  if (!validInviteId(body.workspace_id)) return json(400, { error: "invalid_workspace_id" });
  if (!identifier) return json(400, { error: "invalid_identifier" });
  if (typeof body.external_session_ref !== "string" ||
    !body.external_session_ref.trim() || body.external_session_ref.length > 200) {
    return json(400, { error: "invalid_external_session_ref" });
  }
  if (typeof body.channel !== "string" || !CHANNELS.has(body.channel)) {
    return json(400, { error: "invalid_channel" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "resume_onboarding_by_verified_identifier",
    {
      p_identifier_type: body.identifier_type,
      p_workspace_id: body.workspace_id,
      p_identifier: identifier,
      p_external_session_ref: body.external_session_ref.trim(),
      p_channel: body.channel,
    },
  );
  if (!ok || !result || typeof result !== "object") {
    console.error("resume_onboarding_by_verified_identifier failed", result);
    return json(502, { error: "caller_resolution_failed" });
  }

  const internal = result as Record<string, unknown>;
  if (internal.status !== "recognized") {
    return json(200, {
      status: internal.status === "unavailable" ? "unavailable" : "not_found",
    });
  }

  return json(200, {
    status: "recognized",
    user_id: internal.user_id,
    display_name: internal.display_name,
    actor_ref: internal.actor_ref,
    workspace_id: internal.workspace_id,
    trust_session_id: internal.trust_session_id,
    onboarding_session_id: internal.onboarding_session_id,
    thread_id: internal.thread_id,
    onboarding_state: internal.onboarding_state,
    current_topic: internal.current_topic,
    completed_topics: internal.completed_topics,
    checkpoint: internal.checkpoint,
    completion_percentage: internal.completion_percentage,
  });
});
