import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  boundedRouteStackPayload,
  routeStackFlightSearchPayload,
  routeStackPartnerSignature,
} from "./routestack.ts";

Deno.test("RouteStack maps the canonical one-way flight contract", () => {
  assertEquals(routeStackFlightSearchPayload({
    slices: [{ origin: "HOU", destination: "NYC", departure_date: "2026-10-14" }],
    passengers: [{ type: "adult" }, { age: 12 }],
    cabin_class: "premium_economy",
    max_connections: 1,
  }), {
    origin: "HOU", destination: "NYC", departureDate: "2026-10-14",
    adults: 1, children: 1, childAges: [12], cabin: "Premium Economy",
    tripType: "ONE_WAY", maxConnections: 1,
  });
});

Deno.test("RouteStack maps a canonical return date", () => {
  const payload = routeStackFlightSearchPayload({
    slices: [
      { origin: "HOU", destination: "NYC", departure_date: "2026-10-14" },
      { origin: "NYC", destination: "HOU", departure_date: "2026-10-18" },
    ],
    passengers: [{ type: "adult" }],
  });
  assertEquals(payload.tripType, "ROUND_TRIP");
  assertEquals(payload.returnDate, "2026-10-18");
});

Deno.test("RouteStack rejects unsupported multi-city mapping", () => {
  assertThrows(() => routeStackFlightSearchPayload({
    slices: [
      { origin: "HOU", destination: "NYC", departure_date: "2026-10-14" },
      { origin: "NYC", destination: "LAX", departure_date: "2026-10-16" },
      { origin: "LAX", destination: "HOU", departure_date: "2026-10-18" },
    ],
    passengers: [{ type: "adult" }],
  }), Error, "one-way or round-trip");
});

Deno.test("RouteStack HMAC matches the documented base64url algorithm", async () => {
  assertEquals(
    await routeStackPartnerSignature("key", "secret", 1_700_000_000, "nonce"),
    "gAIIgzNHTeP1mecin5XCrXVJQxUkuS-L2mlP8gJjkh0",
  );
});

Deno.test("RouteStack payload bounding caps nested inventory", () => {
  assertEquals(boundedRouteStackPayload({
    success: true,
    result: { result: [{ id: 1 }, { id: 2 }, { id: 3 }], count: 3 },
  }, 2), {
    success: true,
    result: { result: [{ id: 1 }, { id: 2 }], count: 3 },
  });
});

Deno.test("RouteStack payload bounding strips provider secrets recursively", () => {
  assertEquals(boundedRouteStackPayload({
    success: true,
    result: {
      token: "session-secret",
      client_key: "provider-key",
      fareSourceCode: "opaque-booking-token",
      fare: "public-fare",
    },
  }), {
    success: true,
    result: { fare: "public-fare" },
  });
});
