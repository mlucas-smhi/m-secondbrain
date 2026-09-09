const MAX_ERROR_TEXT = 1_000;

export type CanonicalFlightSearchInput = {
  slices: Array<{ origin: string; destination: string; departure_date: string }>;
  passengers: Array<{ type: "adult" } | { age: number }>;
  cabin_class?: "economy" | "premium_economy" | "business" | "first";
  max_connections?: number;
};

type CachedToken = { value: string; refreshAt: number };
let cachedToken: CachedToken | null = null;

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function routeStackFlightSearchPayload(input: CanonicalFlightSearchInput): Record<string, unknown> {
  if (input.slices.length < 1 || input.slices.length > 2) {
    throw new Error("RouteStack flight search supports one-way or round-trip searches");
  }
  const adults = input.passengers.filter((passenger) => "type" in passenger).length;
  const childAges = input.passengers
    .filter((passenger): passenger is { age: number } => "age" in passenger)
    .map((passenger) => passenger.age);
  const cabin = {
    economy: "Economy",
    premium_economy: "Premium Economy",
    business: "Business",
    first: "First",
  }[input.cabin_class ?? "economy"];
  const outbound = input.slices[0];
  const inbound = input.slices[1];
  return {
    origin: outbound.origin,
    destination: outbound.destination,
    departureDate: outbound.departure_date,
    adults,
    children: childAges.length,
    childAges,
    cabin,
    tripType: inbound ? "ROUND_TRIP" : "ONE_WAY",
    ...(inbound ? { returnDate: inbound.departure_date } : {}),
    ...(input.max_connections === undefined ? {} : { maxConnections: input.max_connections }),
  };
}

export async function routeStackPartnerSignature(
  apiKey: string,
  apiSecret: string,
  timestamp: number,
  nonce: string,
): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(apiSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(`${apiKey}:${timestamp}:${nonce}`),
  );
  return base64Url(new Uint8Array(signature));
}

function tokenLifetimeSeconds(value: unknown): number {
  if (typeof value !== "string") return 24 * 60 * 60;
  const match = /^(\d+)([smhd])$/.exec(value.trim());
  if (!match) return 24 * 60 * 60;
  const amount = Number(match[1]);
  const units: Record<string, number> = { s: 1, m: 60, h: 3600, d: 86400 };
  return amount * (units[match[2]] ?? 1);
}

async function partnerToken(baseUrl: string, apiKey: string, apiSecret: string): Promise<string> {
  if (cachedToken && cachedToken.refreshAt > Date.now()) return cachedToken.value;
  const timestamp = Math.floor(Date.now() / 1000);
  const nonce = crypto.randomUUID();
  const hmac = await routeStackPartnerSignature(apiKey, apiSecret, timestamp, nonce);
  const response = await fetch(`${baseUrl}/mcp/auth/partner-token`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ apiKey, hmac, timestamp, nonce }),
  });
  const payload = await response.json().catch(() => null) as
    | { token?: unknown; expiresIn?: unknown }
    | null;
  if (!response.ok || typeof payload?.token !== "string") {
    throw new Error(
      `RouteStack authentication failed (${response.status}): ${JSON.stringify(payload).slice(0, MAX_ERROR_TEXT)}`,
    );
  }
  const lifetime = tokenLifetimeSeconds(payload.expiresIn);
  cachedToken = {
    value: payload.token,
    refreshAt: Date.now() + Math.max(60, lifetime - 300) * 1000,
  };
  return payload.token;
}

export async function callRouteStack(
  baseUrl: string,
  apiKey: string,
  apiSecret: string,
  path: string,
  data: unknown,
  retryAuth = true,
): Promise<unknown> {
  const normalizedBaseUrl = baseUrl.replace(/\/$/, "");
  const token = await partnerToken(normalizedBaseUrl, apiKey, apiSecret);
  const response = await fetch(`${normalizedBaseUrl}${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify(data),
  });
  if (response.status === 401 && retryAuth) {
    cachedToken = null;
    return callRouteStack(baseUrl, apiKey, apiSecret, path, data, false);
  }
  const text = await response.text();
  let payload: unknown;
  try {
    payload = text ? JSON.parse(text) : null;
  } catch {
    payload = { raw: text.slice(0, MAX_ERROR_TEXT) };
  }
  if (!response.ok) {
    throw new Error(
      `RouteStack request failed (${response.status}): ${JSON.stringify(payload).slice(0, MAX_ERROR_TEXT)}`,
    );
  }
  return payload;
}

export function boundedRouteStackPayload(payload: unknown, maxItems = 20): unknown {
  const sensitiveKey = /(^|_)(token|secret|client_key|authorization|hmac)($|_)|faresourcecode/i;
  function bound(value: unknown, depth: number): unknown {
    if (depth > 10) return "[truncated]";
    if (typeof value === "string") return value.length > 2_000 ? `${value.slice(0, 2_000)}…` : value;
    if (Array.isArray(value)) return value.slice(0, maxItems).map((item) => bound(item, depth + 1));
    if (!value || typeof value !== "object") return value;
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .filter(([key]) => !sensitiveKey.test(key))
        .slice(0, 100)
        .map(([key, item]) => [key, bound(item, depth + 1)]),
    );
  }
  return bound(payload, 0);
}
