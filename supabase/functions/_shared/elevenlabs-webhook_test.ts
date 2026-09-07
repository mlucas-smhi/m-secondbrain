import {
  parsePostCall,
  postCallData,
  postCallTaskId,
  postCallTriggerType,
  verifyElevenLabsSignature,
} from "./elevenlabs-webhook.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function signature(rawBody: string, timestamp: number, secret: string): Promise<string> {
  const encoder = new TextEncoder();
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
  const hash = [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  return `t=${timestamp},v0=${hash}`;
}

Deno.test("verifies a current ElevenLabs HMAC and rejects tampering", async () => {
  const now = 1_800_000_000_000;
  const timestamp = Math.floor(now / 1000);
  const rawBody = '{"type":"post_call_transcription"}';
  const header = await signature(rawBody, timestamp, "test-secret");

  assert(
    await verifyElevenLabsSignature(rawBody, header, "test-secret", now),
    "valid signature was rejected",
  );
  assert(
    !await verifyElevenLabsSignature(`${rawBody} `, header, "test-secret", now),
    "tampered body was accepted",
  );
  assert(
    !await verifyElevenLabsSignature(rawBody, header, "wrong-secret", now),
    "wrong secret was accepted",
  );
});

Deno.test("rejects stale and future webhook timestamps", async () => {
  const now = 1_800_000_000_000;
  const staleTimestamp = Math.floor((now - 31 * 60 * 1000) / 1000);
  const futureTimestamp = Math.floor((now + 31 * 60 * 1000) / 1000);
  const rawBody = "{}";

  assert(
    !await verifyElevenLabsSignature(
      rawBody,
      await signature(rawBody, staleTimestamp, "secret"),
      "secret",
      now,
    ),
    "stale signature was accepted",
  );
  assert(
    !await verifyElevenLabsSignature(
      rawBody,
      await signature(rawBody, futureTimestamp, "secret"),
      "secret",
      now,
    ),
    "future signature was accepted",
  );
});

Deno.test("extracts routing and bounded post-call data", () => {
  const parsed = parsePostCall({
    type: "post_call_transcription",
    event_timestamp: 1_800_000_000,
    data: {
      agent_id: "agent_test",
      conversation_id: "conv_test",
      status: "done",
      transcript: [
        { role: "agent", message: "Question", time_in_call_secs: 0, ignored: true },
        { role: "user", message: "Answer", time_in_call_secs: 2, ignored: true },
      ],
      analysis: {
        call_successful: "success",
        transcript_summary: "A useful answer was provided.",
        data_collection_results: { decision: "approved" },
      },
      metadata: { call_duration_secs: 12, phone_number: "+15555550100" },
      conversation_initiation_client_data: {
        dynamic_variables: {
          task_id: "00000000-0000-4000-8000-000000000001",
          trigger_type: "user_response",
        },
      },
      has_audio: true,
      has_user_audio: true,
      has_response_audio: true,
    },
  });

  assert(parsed, "valid event was rejected");
  assert(
    postCallTaskId(parsed) === "00000000-0000-4000-8000-000000000001",
    "task ID was not extracted",
  );
  assert(postCallTriggerType(parsed) === "user_response", "trigger type was not extracted");

  const data = postCallData(parsed);
  assert(data.conversation_id === "conv_test", "conversation ID was omitted");
  assert(data.call_duration_secs === 12, "duration was omitted");
  assert(Array.isArray(data.transcript) && data.transcript.length === 2, "transcript missing");
  assert(!("phone_number" in data), "raw telephony metadata leaked into event data");
});

Deno.test("ignores invalid payloads and defaults to external events", () => {
  assert(parsePostCall({ type: "post_call_audio", data: {} }) === null, "audio event accepted");

  const parsed = parsePostCall({
    type: "post_call_transcription",
    data: {
      agent_id: "agent_test",
      conversation_id: "conv_test",
      conversation_initiation_client_data: { dynamic_variables: { trigger_type: "other" } },
    },
  });
  assert(parsed, "minimal valid event was rejected");
  assert(postCallTaskId(parsed) === null, "invalid task ID was accepted");
  assert(postCallTriggerType(parsed) === "external_event", "fallback trigger is incorrect");
});
