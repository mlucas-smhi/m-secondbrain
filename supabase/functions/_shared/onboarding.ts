import { callRpc, json, UUID_PATTERN } from "./turn-http.ts";

export type OnboardingConfig = {
  supabaseUrl: string;
  serviceRoleKey: string;
  codePepper: string;
};

function timingSafeEqual(left: string, right: string): boolean {
  const length = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;
  for (let index = 0; index < length; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return difference === 0;
}

export function onboardingConfig(request: Request): OnboardingConfig | Response {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const apiKey = Deno.env.get("ONBOARDING_API_KEY");
  const codePepper = Deno.env.get("ONBOARDING_CODE_PEPPER");

  if (!supabaseUrl || !serviceRoleKey || !apiKey || !codePepper) {
    console.error("Missing required onboarding environment variables");
    return json(500, { error: "server_misconfigured" });
  }
  if (!timingSafeEqual(request.headers.get("x-onboarding-key") ?? "", apiKey)) {
    return json(403, { error: "onboarding_key_required" });
  }
  return { supabaseUrl, serviceRoleKey, codePepper };
}

export function normalizeIdentifier(type: unknown, value: unknown): string | null {
  if (type === "phone" && typeof value === "string") {
    const normalized = value.trim();
    return /^\+[1-9][0-9]{7,14}$/.test(normalized) ? normalized : null;
  }
  if (type === "email" && typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized) ? normalized : null;
  }
  return null;
}

export function validInviteId(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

export function generateCode(): string {
  const values = new Uint32Array(1);
  crypto.getRandomValues(values);
  return String(values[0] % 1_000_000).padStart(6, "0");
}

export async function digestCode(
  inviteId: string,
  code: string,
  pepper: string,
): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(pepper),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bytes = new Uint8Array(await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(`onboarding-code:v1:${inviteId}:${code}`),
  ));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export { callRpc, json };
