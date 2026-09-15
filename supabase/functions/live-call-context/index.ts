import {
  callRpc,
  json,
  postgresStatus,
  runtimeConfig,
  validCallId,
} from "../_shared/turn-http.ts";

const WORKSPACE_ID = "00000000-0000-4000-8000-000000000001";

type LiveCallContextRequest = {
  provider_call_ref?: unknown;
};

// Gateway JWT verification is disabled; runtimeConfig enforces X-Turn-Engine-Key.
Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const config = runtimeConfig(request);
  if (config instanceof Response) return config;

  let body: LiveCallContextRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (!validCallId(body.provider_call_ref)) {
    return json(400, { error: "provider_call_ref_required" });
  }

  const { ok, result } = await callRpc(
    config.supabaseUrl,
    config.serviceRoleKey,
    "get_live_call_context",
    {
      p_workspace_id: WORKSPACE_ID,
      p_provider_call_ref: body.provider_call_ref.trim(),
    },
  );

  if (!ok) {
    console.error("get_live_call_context failed", result);
    return json(postgresStatus(result), { error: "live_call_context_unavailable" });
  }

  return json(200, result);
});
