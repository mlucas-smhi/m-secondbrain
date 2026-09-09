import { assertEquals } from "jsr:@std/assert@1";
import { boundedProviderPayload } from "./duffel.ts";

Deno.test("boundedProviderPayload caps top-level result arrays", () => {
  const payload = { data: [{ id: 1 }, { id: 2 }, { id: 3 }], meta: { after: "next" } };
  assertEquals(boundedProviderPayload(payload, 2), {
    data: [{ id: 1 }, { id: 2 }],
    meta: { after: "next" },
  });
});

Deno.test("boundedProviderPayload preserves object responses", () => {
  const payload = { data: { id: "acc_123", name: "Example" } };
  assertEquals(boundedProviderPayload(payload), payload);
});
