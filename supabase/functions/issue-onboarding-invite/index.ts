import {
  callRpc,
  digestCode,
  generateCode,
  json,
  normalizeIdentifier,
  onboardingConfig,
  validInviteId,
} from "../_shared/onboarding.ts";

type IssueRequest = {
  invite_type?: unknown;
  delivery_channel?: unknown;
  identifier_type?: unknown;
  identifier?: unknown;
  expires_in_minutes?: unknown;
  max_attempts?: unknown;
  auth_user_id?: unknown;
  created_by_actor_id?: unknown;
};

const INVITE_TYPES = new Set(["preview_invite", "signup"]);
const CHANNELS = new Set(["phone", "sms", "email", "manual"]);

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });
  const config = onboardingConfig(request);
  if (config instanceof Response) return config;

  let body: IssueRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.invite_type !== "string" || !INVITE_TYPES.has(body.invite_type)) {
    return json(400, { error: "invalid_invite_type" });
  }
  if (typeof body.delivery_channel !== "string" || !CHANNELS.has(body.delivery_channel)) {
    return json(400, { error: "invalid_delivery_channel" });
  }
  const identifier = normalizeIdentifier(body.identifier_type, body.identifier);
  if (!identifier) return json(400, { error: "invalid_identifier" });

  const expiresInMinutes = body.expires_in_minutes === undefined ? 30 : Number(body.expires_in_minutes);
  const maxAttempts = body.max_attempts === undefined ? 5 : Number(body.max_attempts);
  if (!Number.isInteger(expiresInMinutes) || expiresInMinutes < 5 || expiresInMinutes > 1440) {
    return json(400, { error: "invalid_expiry" });
  }
  if (!Number.isInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 20) {
    return json(400, { error: "invalid_max_attempts" });
  }
  for (const field of ["auth_user_id", "created_by_actor_id"] as const) {
    if (body[field] !== undefined && body[field] !== null && !validInviteId(body[field])) {
      return json(400, { error: `invalid_${field}` });
    }
  }

  const inviteId = crypto.randomUUID();
  const code = generateCode();
  const codeDigest = await digestCode(inviteId, code, config.codePepper);
  const expiresAt = new Date(Date.now() + expiresInMinutes * 60_000).toISOString();
  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "create_onboarding_invite",
    {
      p_code_digest: codeDigest,
      p_invite_type: body.invite_type,
      p_delivery_channel: body.delivery_channel,
      p_identifier_type: body.identifier_type,
      p_identifier: identifier,
      p_expires_at: expiresAt,
      p_max_attempts: maxAttempts,
      p_auth_user_id: body.auth_user_id ?? null,
      p_created_by_actor_id: body.created_by_actor_id ?? null,
      p_invite_id: inviteId,
    },
  );
  if (!ok) {
    console.error("create_onboarding_invite failed", result);
    return json(502, { error: "invite_creation_failed" });
  }

  // The trusted caller is responsible for delivering the code. Never log it.
  return json(201, { ...(result as Record<string, unknown>), code });
});
