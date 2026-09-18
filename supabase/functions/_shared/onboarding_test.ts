import { assertEquals, assertMatch } from "jsr:@std/assert@1";
import { digestCode, generateCode, normalizeIdentifier } from "./onboarding.ts";

Deno.test("normalizes supported onboarding identifiers", () => {
  assertEquals(normalizeIdentifier("phone", " +18323886696 "), "+18323886696");
  assertEquals(normalizeIdentifier("email", " M@Example.COM "), "m@example.com");
  assertEquals(normalizeIdentifier("phone", "8323886696"), null);
});

Deno.test("generates six digit codes", () => {
  assertMatch(generateCode(), /^[0-9]{6}$/);
});

Deno.test("code digest is invite bound and deterministic", async () => {
  const first = await digestCode("10000000-0000-4000-8000-000000000001", "123456", "pepper");
  const replay = await digestCode("10000000-0000-4000-8000-000000000001", "123456", "pepper");
  const otherInvite = await digestCode("10000000-0000-4000-8000-000000000002", "123456", "pepper");
  assertEquals(first, replay);
  assertEquals(first.length, 64);
  assertEquals(first === otherInvite, false);
});
