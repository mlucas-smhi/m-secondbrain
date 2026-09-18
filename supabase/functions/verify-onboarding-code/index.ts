import {
  callRpc,
  digestCode,
  json,
  normalizeIdentifier,
  onboardingConfig,
  validInviteId,
} from "../_shared/onboarding.ts";

type VerifyRequest = {
  invite_id?: unknown;
  request_id?: unknown;
  code?: unknown;
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

  let body: VerifyRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (!validInviteId(body.invite_id)) return json(400, { error: "invalid_invite_id" });
  if (typeof body.request_id !== "string" || !body.request_id.trim() || body.request_id.length > 200) {
    return json(400, { error: "invalid_request_id" });
  }
  if (typeof body.code !== "string" || !/^[0-9]{6}$/.test(body.code)) {
    return json(400, { error: "invalid_code_format" });
  }
  if (typeof body.external_session_ref !== "string" || !body.external_session_ref.trim() ||
    body.external_session_ref.length > 200) {
    return json(400, { error: "invalid_external_session_ref" });
  }
  if (typeof body.channel !== "string" || !CHANNELS.has(body.channel)) {
    return json(400, { error: "invalid_channel" });
  }
  const identifier = normalizeIdentifier(body.identifier_type, body.identifier);
  if (!identifier) return json(400, { error: "invalid_identifier" });

  const codeDigest = await digestCode(body.invite_id, body.code, config.codePepper);
  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "verify_and_provision_onboarding",
    {
      p_invite_id: body.invite_id,
      p_request_id: body.request_id.trim(),
      p_code_digest: codeDigest,
      p_identifier_type: body.identifier_type,
      p_identifier: identifier,
      p_external_session_ref: body.external_session_ref.trim(),
      p_channel: body.channel,
      p_memory_provider: "litegraph",
    },
  );
  if (!ok || !result || typeof result !== "object") {
    console.error("verify_and_provision_onboarding failed", result);
    return json(502, { error: "verification_service_failed" });
  }

  const internal = result as Record<string, unknown>;
  if (internal.status === "confirmed") {
    return json(200, {
      status: "confirmed",
      replayed: internal.replayed === true,
      user_id: internal.user_id,
      actor_ref: internal.actor_ref,
      workspace_id: internal.workspace_id,
      onboarding_session_id: internal.onboarding_session_id,
      trust_session_id: internal.trust_session_id,
      onboarding_state: internal.onboarding_state ?? "in_progress",
    });
  }
  if (internal.status === "locked") {
    return json(200, { status: "locked", can_retry: false, message: "verification_unavailable" });
  }
  // Deliberately collapse wrong, expired, revoked, consumed, and unknown invites.
  return json(200, { status: "retry", can_retry: true, message: "verification_failed" });
});
