import { callRpc, json, postgresStatus } from "../_shared/turn-http.ts";
import {
  protectedPhoneRef,
  twilioEventId,
  verifyTwilioFormSignature,
} from "../_shared/twilio-webhook.ts";

const WORKSPACE_ID = "00000000-0000-4000-8000-000000000001";
const CALL_STATUSES = new Set([
  "queued",
  "initiated",
  "ringing",
  "in-progress",
  "completed",
  "busy",
  "failed",
  "no-answer",
  "canceled",
]);

async function fetchCall(
  accountSid: string,
  authToken: string,
  callSid: string,
): Promise<Record<string, unknown> | null> {
  const endpoint = `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Calls/${callSid}.json`;
  const response = await fetch(endpoint, {
    headers: { Authorization: `Basic ${btoa(`${accountSid}:${authToken}`)}` },
  });
  if (!response.ok) return null;
  return await response.json() as Record<string, unknown>;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authToken = Deno.env.get("TWILIO_AUTH_TOKEN");
  const accountSid = Deno.env.get("TWILIO_ACCOUNT_SID");
  const phoneHashKey = Deno.env.get("LIVE_CALL_PHONE_HASH_KEY");
  if (!supabaseUrl || !serviceRoleKey || !authToken || !accountSid || !phoneHashKey) {
    console.error("Missing Twilio live-call callback configuration");
    return json(500, { error: "server_misconfigured" });
  }

  const rawBody = await request.text();
  const form = new URLSearchParams(rawBody);
  // Twilio signs the exact public URL configured on the call. Edge gateways may
  // rewrite request.url before it reaches the function, so reconstruct the
  // canonical callback URL from SUPABASE_URL instead of trusting the proxy URL.
  const callbackUrl = `${supabaseUrl.replace(/\/$/, "")}/functions/v1/twilio-call-status`;
  if (!await verifyTwilioFormSignature(
    callbackUrl,
    form,
    request.headers.get("x-twilio-signature"),
    authToken,
  )) return json(403, { error: "invalid_signature" });

  if (form.get("AccountSid") !== accountSid) {
    return json(403, { error: "unexpected_account" });
  }

  const providerEventId = twilioEventId(form);
  const callSid = form.get("CallSid")?.trim();
  const streamEvent = form.get("StreamEvent")?.trim();
  let status = form.get("CallStatus")?.trim();
  let direction = form.get("Direction")?.trim();
  let from = form.get("From")?.trim() ?? "";
  let to = form.get("To")?.trim() ?? "";
  if (callSid && streamEvent) {
    const call = await fetchCall(accountSid, authToken, callSid);
    if (!call) return json(502, { error: "twilio_call_not_resolved" });
    direction = String(call.direction ?? "").trim();
    from = String(call.from ?? "").trim();
    to = String(call.to ?? "").trim();
    const resolvedStatus = String(call.status ?? "").trim();
    status = streamEvent === "stream-started"
      ? "in-progress"
      : streamEvent === "stream-stopped"
      ? "completed"
      : CALL_STATUSES.has(resolvedStatus)
      ? resolvedStatus
      : "in-progress";
  }
  const sequenceRaw = form.get("SequenceNumber")?.trim();
  const sequenceNumber = sequenceRaw === undefined || sequenceRaw === null || sequenceRaw === ""
    ? null
    : Number(sequenceRaw);
  if (!providerEventId || !callSid || !status || !direction ||
    (sequenceNumber !== null && (!Number.isInteger(sequenceNumber) || sequenceNumber < 0))) {
    return json(400, { error: "invalid_callback" });
  }

  const timestampRaw = form.get("Timestamp")?.trim();
  const occurredAt = timestampRaw && !Number.isNaN(Date.parse(timestampRaw))
    ? new Date(timestampRaw).toISOString()
    : new Date().toISOString();

  const { ok, result } = await callRpc(
    supabaseUrl,
    serviceRoleKey,
    "record_live_call_status",
    {
      p_workspace_id: WORKSPACE_ID,
      p_provider_event_id: providerEventId,
      p_provider_call_ref: callSid,
      p_provider_status: status,
      p_direction: direction,
      p_occurred_at: occurredAt,
      p_sequence_number: sequenceNumber,
      p_from_phone_ref: await protectedPhoneRef(from, phoneHashKey),
      p_to_phone_ref: await protectedPhoneRef(to, phoneHashKey),
      p_data: {
        callback_source: form.get("CallbackSource"),
        stream_event: streamEvent,
        stream_error: form.get("StreamError"),
        stream_sid: form.get("StreamSid"),
        stir_status: form.get("StirStatus"),
      },
    },
  );

  if (!ok) {
    console.error("record_live_call_status failed", result);
    return json(postgresStatus(result), { error: "live_call_status_not_recorded" });
  }
  return json(200, result);
});
