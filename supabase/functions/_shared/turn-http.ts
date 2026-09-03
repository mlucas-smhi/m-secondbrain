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

export function hasServiceRole(request: Request, serviceRoleKey: string): boolean {
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return false;

  const token = authorization.slice("Bearer ".length).trim();
  if (token === serviceRoleKey) return true;

  // verify_jwt is enabled at the Edge Function gateway, so a JWT reaching the
  // handler has already had its signature and expiry checked by Supabase.
  const parts = token.split(".");
  if (parts.length !== 3) return false;

  try {
    const base64 = parts[1].replaceAll("-", "+").replaceAll("_", "/");
    const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=");
    const payload: unknown = JSON.parse(atob(padded));

    return typeof payload === "object" && payload !== null &&
      "role" in payload && payload.role === "service_role";
  } catch {
    return false;
  }
}

export function runtimeConfig(request: Request):
  | { supabaseUrl: string; serviceRoleKey: string }
  | Response {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseUrl || !serviceRoleKey) {
    console.error("Missing required Supabase environment variables");
    return json(500, { error: "server_misconfigured" });
  }

  if (!hasServiceRole(request, serviceRoleKey)) {
    return json(403, { error: "service_role_required" });
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
