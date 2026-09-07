import {
  parsePostCall,
  postCallData,
  postCallTaskId,
  postCallTriggerType,
  verifyElevenLabsSignature,
} from "../_shared/elevenlabs-webhook.ts";
import { callRpc, json } from "../_shared/turn-http.ts";

// Gateway JWT verification is disabled. ElevenLabs HMAC verification authenticates
// the exact raw request body before any payload fields are trusted.
Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const webhookSecret = Deno.env.get("ELEVENLABS_WEBHOOK_SECRET");
  const expectedAgentId = Deno.env.get("ELEVENLABS_AGENT_ID");
  if (!supabaseUrl || !serviceRoleKey || !webhookSecret || !expectedAgentId) {
    console.error("Missing ElevenLabs post-call webhook configuration");
    return json(500, { error: "server_misconfigured" });
  }

  const rawBody = await request.text();
  const signatureValid = await verifyElevenLabsSignature(
    rawBody,
    request.headers.get("elevenlabs-signature"),
    webhookSecret,
  );
  if (!signatureValid) return json(401, { error: "invalid_signature" });

  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if ((parsed as { type?: unknown } | null)?.type !== "post_call_transcription") {
    return json(200, { outcome: "ignored", reason: "unsupported_event_type" });
  }

  const event = parsePostCall(parsed);
  if (!event) return json(400, { error: "invalid_event" });
  if (event.data.agent_id !== expectedAgentId) {
    return json(200, { outcome: "ignored", reason: "unexpected_agent" });
  }

  const taskId = postCallTaskId(event);
  if (!taskId) {
    return json(200, { outcome: "ignored", reason: "task_id_missing" });
  }

  const triggerType = postCallTriggerType(event);
  const { ok, result } = await callRpc(
    supabaseUrl,
    serviceRoleKey,
    "wake_task_delivery",
    {
      p_task_id: taskId,
      p_trigger_type: triggerType,
      p_call_id: `elevenlabs:${event.data.conversation_id}`,
      p_data: postCallData(event),
      p_actor: "elevenlabs-post-call",
    },
  );

  if (!ok) {
    const code = result && typeof result === "object" && "code" in result
      ? (result as { code?: unknown }).code
      : null;

    // Task-state conflicts and unknown task IDs cannot improve with provider
    // retries. Acknowledge them to prevent an unbounded retry storm.
    if (code === "PT409" || code === "P0002") {
      console.warn("Ignoring non-retryable post-call delivery", result);
      return json(200, { outcome: "ignored", reason: "task_not_wakeable" });
    }

    console.error("wake_task_delivery failed", result);
    return json(502, { error: "task_not_woken" });
  }

  const delivery = result as { task?: unknown; replayed?: unknown } | null;
  if (
    !delivery ||
    typeof delivery !== "object" ||
    typeof delivery.replayed !== "boolean" ||
    !("task" in delivery)
  ) {
    console.error("wake_task_delivery returned an invalid result", result);
    return json(502, { error: "invalid_wake_result" });
  }

  return json(200, {
    outcome: delivery.replayed ? "replayed" : "ready",
    replayed: delivery.replayed,
    trigger_type: triggerType,
    conversation_id: event.data.conversation_id,
    task: delivery.task,
  });
});
