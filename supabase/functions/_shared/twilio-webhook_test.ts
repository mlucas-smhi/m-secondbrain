import {
  protectedPhoneRef,
  twilioEventId,
  twilioFormSignature,
  verifyTwilioFormSignature,
} from "./twilio-webhook.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("Twilio form signatures are deterministic and tamper evident", async () => {
  const url = "https://example.com/twilio-call-status";
  const form = new URLSearchParams({
    To: "+15550000002",
    CallSid: "CA123",
    CallStatus: "ringing",
  });
  const signature = await twilioFormSignature(url, form, "auth-token");
  assert(
    await verifyTwilioFormSignature(url, form, signature, "auth-token"),
    "valid signature was rejected",
  );
  form.set("CallStatus", "completed");
  assert(
    !await verifyTwilioFormSignature(url, form, signature, "auth-token"),
    "tampered callback was accepted",
  );
});

Deno.test("phone references are stable keyed hashes", async () => {
  const first = await protectedPhoneRef("+15550000002", "hash-key");
  const second = await protectedPhoneRef("+15550000002", "hash-key");
  const other = await protectedPhoneRef("+15550000003", "hash-key");
  assert(first === second, "same phone did not produce a stable reference");
  assert(first !== other, "different phones produced the same reference");
  assert(first?.startsWith("hmac-sha256:"), "reference is missing its scheme");
  assert(!first?.includes("+1555"), "raw phone data leaked into the reference");
});

Deno.test("event IDs prefer Twilio sequence numbers", () => {
  const sequenced = new URLSearchParams({
    CallSid: "CA123",
    CallStatus: "ringing",
    SequenceNumber: "2",
  });
  assert(twilioEventId(sequenced) === "CA123:2", "sequence event ID is incorrect");
  assert(twilioEventId(new URLSearchParams()) === null, "invalid event was accepted");
});

Deno.test("stream event IDs include the stream SID and event", () => {
  const started = new URLSearchParams({
    CallSid: "CA123",
    StreamSid: "MZ123",
    StreamEvent: "stream-started",
  });
  assert(
    twilioEventId(started) === "CA123:MZ123:stream-started",
    "stream event ID is incorrect",
  );
});
