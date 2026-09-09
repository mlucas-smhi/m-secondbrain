import { assertEquals } from "jsr:@std/assert@1";
import {
  boundedProviderPayload,
  duffelFlightOfferPath,
  duffelFlightSearchRequest,
  duffelPlaceSuggestionsPath,
} from "./duffel.ts";

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

Deno.test("flight place lookup safely encodes the provider query", () => {
  assertEquals(
    duffelPlaceSuggestionsPath("New York / JFK"),
    "/places/suggestions?query=New%20York%20%2F%20JFK",
  );
});

Deno.test("flight search maps the canonical request to Duffel offer requests", () => {
  const input = {
    slices: [{ origin: "HOU", destination: "NYC", departure_date: "2026-10-14" }],
    passengers: [{ type: "adult" as const }],
    cabin_class: "business" as const,
    max_connections: 1,
  };
  assertEquals(duffelFlightSearchRequest(input), {
    path: "/air/offer_requests?return_offers=true",
    data: input,
  });
});

Deno.test("flight offer lookup safely encodes the external identifier", () => {
  assertEquals(
    duffelFlightOfferPath("off/unsafe"),
    "/air/offers/off%2Funsafe",
  );
});
