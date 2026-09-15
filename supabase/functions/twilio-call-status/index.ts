import { callRpc, json, postgresStatus } from "../_shared/turn-http.ts";
import {
  protectedPhoneRef,
  twilioEventId,
  verifyTwilioFormSignature,
} from "../_shared/twilio-webhook.ts";

const WORKSPACE_ID = "00000000-0000-4000-8000-000000000001";

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
  if (!await verifyTwilioFormSignature(
    request.url,
    form,
    request.headers.get("x-twilio-signature"),
    authToken,
  )) return json(403, { error: "invalid_signature" });

  if (form.get("AccountSid") !== accountSid) {
    return json(403, { error: "unexpected_account" });
  }

  const providerEventId = twilioEventId(form);
  const callSid = form.get("CallSid")?.trim();
  const status = form.get("CallStatus")?.trim();
  const direction = form.get("Direction")?.trim();
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
      p_from_phone_ref: await protectedPhoneRef(form.get("From") ?? "", phoneHashKey),
      p_to_phone_ref: await protectedPhoneRef(form.get("To") ?? "", phoneHashKey),
      p_data: {
        callback_source: form.get("CallbackSource"),
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
