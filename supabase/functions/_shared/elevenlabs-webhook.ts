import { UUID_PATTERN } from "./turn-http.ts";

const SIGNATURE_TOLERANCE_MS = 30 * 60 * 1000;
const encoder = new TextEncoder();

export type ElevenLabsPostCall = {
  type: "post_call_transcription";
  event_timestamp?: number;
  data: {
    agent_id: string;
    conversation_id: string;
    status?: unknown;
    transcript?: unknown;
    analysis?: unknown;
    metadata?: unknown;
    conversation_initiation_client_data?: unknown;
    has_audio?: unknown;
    has_user_audio?: unknown;
    has_response_audio?: unknown;
  };
};

function object(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function timingSafeEqual(left: string, right: string): boolean {
  const length = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;
  for (let index = 0; index < length; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return difference === 0;
}

export async function verifyElevenLabsSignature(
  rawBody: string,
  signatureHeader: string | null,
  secret: string,
  nowMs = Date.now(),
): Promise<boolean> {
  if (!signatureHeader || !secret) return false;

  let timestamp: string | undefined;
  let suppliedSignature: string | undefined;
  for (const part of signatureHeader.split(",")) {
    const value = part.trim();
    if (value.startsWith("t=")) timestamp = value.slice(2);
    if (value.startsWith("v0=")) suppliedSignature = value;
  }

  if (!timestamp || !suppliedSignature || !/^\d+$/.test(timestamp)) return false;
  const timestampMs = Number(timestamp) * 1000;
  if (!Number.isSafeInteger(timestampMs)) return false;
  if (Math.abs(nowMs - timestampMs) > SIGNATURE_TOLERANCE_MS) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(`${timestamp}.${rawBody}`),
  );

  return timingSafeEqual(suppliedSignature, `v0=${hex(digest)}`);
}

export function parsePostCall(value: unknown): ElevenLabsPostCall | null {
  const event = object(value);
  const data = object(event?.data);
  if (
    event?.type !== "post_call_transcription" ||
    !data ||
    typeof data.agent_id !== "string" ||
    data.agent_id.length === 0 ||
    typeof data.conversation_id !== "string" ||
    data.conversation_id.length === 0 ||
    data.conversation_id.length > 180
  ) return null;

  return value as ElevenLabsPostCall;
}

export function postCallTaskId(event: ElevenLabsPostCall): string | null {
  const clientData = object(event.data.conversation_initiation_client_data);
  const variables = object(clientData?.dynamic_variables);
  const taskId = variables?.task_id;
  return typeof taskId === "string" && UUID_PATTERN.test(taskId) ? taskId : null;
}

export function postCallTriggerType(
  event: ElevenLabsPostCall,
): "user_response" | "external_event" {
  const clientData = object(event.data.conversation_initiation_client_data);
  const variables = object(clientData?.dynamic_variables);
  return variables?.trigger_type === "user_response" ? "user_response" : "external_event";
}

function transcript(value: unknown): Array<Record<string, unknown>> {
  if (!Array.isArray(value)) return [];
  return value.slice(0, 100).flatMap((turn) => {
    const item = object(turn);
    if (!item || (item.role !== "agent" && item.role !== "user")) return [];
    if (typeof item.message !== "string") return [];
    return [{
      role: item.role,
      message: item.message.slice(0, 10_000),
      time_in_call_secs: typeof item.time_in_call_secs === "number"
        ? item.time_in_call_secs
        : null,
    }];
  });
}

export function postCallData(event: ElevenLabsPostCall): Record<string, unknown> {
  const analysis = object(event.data.analysis);
  const metadata = object(event.data.metadata);
  return {
    provider: "elevenlabs",
    conversation_id: event.data.conversation_id,
    agent_id: event.data.agent_id,
    status: typeof event.data.status === "string" ? event.data.status : null,
    event_timestamp: typeof event.event_timestamp === "number"
      ? event.event_timestamp
      : null,
    call_duration_secs: typeof metadata?.call_duration_secs === "number"
      ? metadata.call_duration_secs
      : null,
    call_successful: typeof analysis?.call_successful === "string"
      ? analysis.call_successful
      : null,
    transcript_summary: typeof analysis?.transcript_summary === "string"
      ? analysis.transcript_summary.slice(0, 20_000)
      : null,
    data_collection_results: object(analysis?.data_collection_results) ?? {},
    transcript: transcript(event.data.transcript),
    has_audio: event.data.has_audio === true,
    has_user_audio: event.data.has_user_audio === true,
    has_response_audio: event.data.has_response_audio === true,
  };
}
