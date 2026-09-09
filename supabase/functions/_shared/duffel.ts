const DUFFEL_API_BASE = "https://api.duffel.com";
const MAX_ERROR_TEXT = 1_000;

export type DuffelRequestOptions = {
  method?: "GET" | "POST";
  data?: unknown;
  signal?: AbortSignal;
};

export async function callDuffel(
  accessToken: string,
  path: string,
  options: DuffelRequestOptions = {},
): Promise<unknown> {
  const response = await fetch(`${DUFFEL_API_BASE}${path}`, {
    method: options.method ?? "GET",
    headers: {
      Accept: "application/json",
      "Accept-Encoding": "gzip",
      "Content-Type": "application/json",
      "Duffel-Version": "v2",
      Authorization: `Bearer ${accessToken}`,
    },
    body: options.data === undefined ? undefined : JSON.stringify({ data: options.data }),
    signal: options.signal,
  });

  const text = await response.text();
  let payload: unknown;
  try {
    payload = text ? JSON.parse(text) : null;
  } catch {
    payload = { raw: text.slice(0, MAX_ERROR_TEXT) };
  }

  if (!response.ok) {
    throw new Error(
      `Duffel request failed (${response.status}): ${JSON.stringify(payload).slice(0, MAX_ERROR_TEXT)}`,
    );
  }
  return payload;
}

export function boundedProviderPayload(payload: unknown, maxItems = 20): unknown {
  if (
    payload && typeof payload === "object" && !Array.isArray(payload) &&
    "data" in payload && Array.isArray((payload as { data: unknown }).data)
  ) {
    const record = payload as { data: unknown[]; [key: string]: unknown };
    return { ...record, data: record.data.slice(0, maxItems) };
  }
  return payload;
}
