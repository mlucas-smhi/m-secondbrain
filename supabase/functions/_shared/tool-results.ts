import type { CanonicalFlightResults } from "./flight-results.ts";
import type { CanonicalTravelResults } from "./travel-results.ts";

async function storeProtectedTravelResult(
  toolRunId: string | undefined,
  provider: "duffel" | "routestack",
  result: CanonicalFlightResults | CanonicalTravelResults,
  protectedRefs: Record<string, unknown>,
): Promise<string | null> {
  if (!toolRunId) return null;
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) throw new Error("protected tool-result storage is not configured");
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/store_travel_search_result`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${serviceRoleKey}`,
      apikey: serviceRoleKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      p_tool_run_id: toolRunId,
      p_provider: provider,
      p_result_type: result.schema_version,
      p_canonical_result: result,
      p_protected_refs: protectedRefs,
      p_expires_at: result.valid_until,
    }),
  });
  const payload = await response.json().catch(() => null);
  if (!response.ok || typeof payload !== "string") {
    throw new Error(`protected tool-result storage failed (${response.status})`);
  }
  return payload;
}

export async function storeProtectedFlightResult(
  toolRunId: string | undefined,
  provider: "duffel" | "routestack",
  result: CanonicalFlightResults,
  protectedRefs: Record<string, unknown>,
): Promise<string | null> {
  return await storeProtectedTravelResult(toolRunId, provider, result, protectedRefs);
}

export async function storeProtectedHotelOrCarResult(
  toolRunId: string | undefined,
  result: CanonicalTravelResults,
  protectedRefs: Record<string, unknown>,
): Promise<string | null> {
  return await storeProtectedTravelResult(toolRunId, "routestack", result, protectedRefs);
}
