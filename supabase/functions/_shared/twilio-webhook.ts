const encoder = new TextEncoder();

function timingSafeEqual(left: string, right: string): boolean {
  const length = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;
  for (let index = 0; index < length; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return difference === 0;
}

function base64(bytes: ArrayBuffer): string {
  let binary = "";
  for (const byte of new Uint8Array(bytes)) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export async function twilioFormSignature(
  url: string,
  form: URLSearchParams,
  authToken: string,
): Promise<string> {
  const keys = [...new Set([...form.keys()])].sort();
  let material = url;
  for (const key of keys) {
    for (const value of form.getAll(key).sort()) material += `${key}${value}`;
  }
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(authToken),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  return base64(await crypto.subtle.sign("HMAC", key, encoder.encode(material)));
}

export async function verifyTwilioFormSignature(
  url: string,
  form: URLSearchParams,
  suppliedSignature: string | null,
  authToken: string,
): Promise<boolean> {
  if (!suppliedSignature || !authToken) return false;
  return timingSafeEqual(
    await twilioFormSignature(url, form, authToken),
    suppliedSignature,
  );
}

export async function protectedPhoneRef(value: string, hashKey: string): Promise<string | null> {
  const normalized = value.trim();
  if (!normalized) return null;
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(hashKey),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = await crypto.subtle.sign("HMAC", key, encoder.encode(normalized));
  const hex = [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  return `hmac-sha256:${hex}`;
}

export function twilioEventId(form: URLSearchParams): string | null {
  const callSid = form.get("CallSid")?.trim();
  const status = form.get("CallStatus")?.trim() || form.get("StreamEvent")?.trim();
  if (!callSid || !status) return null;
  const streamSid = form.get("StreamSid")?.trim();
  if (streamSid) return `${callSid}:${streamSid}:${status}`;
  const discriminator = form.get("SequenceNumber")?.trim() ||
    form.get("Timestamp")?.trim() || status;
  return `${callSid}:${discriminator}`;
}
