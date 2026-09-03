export const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" };
export const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

export function postgresStatus(error: unknown): number {
  if (!error || typeof error !== "object" || !("code" in error)) return 502;

  switch ((error as { code?: unknown }).code) {
    case "P0002":
      return 404;
    case "40001":
      return 409;
    case "22023":
      return 422;
    default:
      return 502;
  }
}

function timingSafeEqual(left: string, right: string): boolean {
  const length = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;

  for (let index = 0; index < length; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }

  return difference === 0;
}

export function runtimeConfig(request: Request):
  | { supabaseUrl: string; serviceRoleKey: string }
  | Response {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const turnEngineApiKey = Deno.env.get("TURN_ENGINE_API_KEY");

  if (!supabaseUrl || !serviceRoleKey || !turnEngineApiKey) {
    console.error("Missing required Supabase environment variables");
    return json(500, { error: "server_misconfigured" });
  }

  const providedKey = request.headers.get("x-turn-engine-key") ?? "";
  if (!timingSafeEqual(providedKey, turnEngineApiKey)) {
    return json(403, { error: "turn_engine_key_required" });
  }

  return { supabaseUrl, serviceRoleKey };
}

export async function callRpc(
  supabaseUrl: string,
  serviceRoleKey: string,
  functionName: string,
  body: Record<string, unknown>,
): Promise<{ ok: boolean; result: unknown }> {
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${functionName}`, {
    method: "POST",
    headers: {
      ...JSON_HEADERS,
      apikey: serviceRoleKey,
      authorization: `Bearer ${serviceRoleKey}`,
    },
    body: JSON.stringify(body),
  });

  return {
    ok: response.ok,
    result: await response.json().catch(() => null),
  };
}

export function advanceTask(
  supabaseUrl: string,
  serviceRoleKey: string,
  body: Record<string, unknown>,
): Promise<{ ok: boolean; result: unknown }> {
  return callRpc(supabaseUrl, serviceRoleKey, "advance_task", body);
}

export function validCallId(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0 && value.length <= 200;
}
