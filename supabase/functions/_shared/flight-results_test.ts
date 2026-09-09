import { assertEquals } from "jsr:@std/assert@1";
import { assertThrows } from "jsr:@std/assert@1";
import {
  normalizeDuffelFlightResults,
  normalizeRouteStackFlightResults,
  protectedRouteStackOfferRefs,
  validateCanonicalFlightResults,
} from "./flight-results.ts";

Deno.test("normalizes Duffel offers without raw provider payload", () => {
  const result = normalizeDuffelFlightResults({ data: { offers: [{
    id: "off_1", total_amount: "199.50", total_currency: "USD",
    slices: [{ duration: "PT3H15M", segments: [{
      marketing_carrier: { iata_code: "UA" }, marketing_carrier_flight_number: "123",
      origin: { iata_code: "IAH" }, destination: { iata_code: "EWR" },
      departing_at: "2026-10-14T10:00:00Z", arriving_at: "2026-10-14T13:15:00Z",
      passengers: [{ cabin_class: "economy" }],
    }] }],
  }] } });
  assertEquals(result.offers[0].total_amount, 199.5);
  assertEquals(result.offers[0].duration_minutes, 195);
  assertEquals(result.offers[0].segments[0].origin, "IAH");
  assertEquals("data" in result, false);
});

Deno.test("normalizes and bounds RouteStack offers without fare source tokens", () => {
  const offer = { stops: 0, showOurprice: 165.39, currency: "USD", fareSourceCode: "secret", flights: [{
    triptime: 202, flightCode: "DL", flightNumber: "1195", departure: "HOU", arrival: "JFK",
    departureTime: "2026-10-14T15:09:00", arrivalTime: "2026-10-14T18:31:00",
    cabin: "Economy", remainingSeats: 9, fareFamily: "DELTA MAIN",
  }] };
  const result = normalizeRouteStackFlightResults({ count: 34, result: [offer, offer] }, 1);
  assertEquals(result.returned_count, 1);
  assertEquals(result.truncated, true);
  assertEquals(result.offers[0].segments[0].flight_number, "1195");
  assertEquals(JSON.stringify(result).includes("fareSourceCode"), false);
  assertEquals(JSON.stringify(result).includes("secret"), false);
});

Deno.test("rejects flight packets without currency", () => {
  const result = normalizeRouteStackFlightResults({ result: [{
    showOurprice: 100,
    flights: [{
      departure: "IAH", arrival: "EWR",
      departureTime: "2026-10-14T10:00:00Z", arrivalTime: "2026-10-14T13:00:00Z",
    }],
  }] });
  assertThrows(() => validateCanonicalFlightResults(result), Error, "missing an ISO currency");
});

Deno.test("keeps RouteStack execution handles only in protected refs", () => {
  const payload = { result: [{ fareSourceCode: "opaque", sessionId: "session" }] };
  const refs = protectedRouteStackOfferRefs(payload);
  assertEquals(refs, {
    "routestack:1": { fare_source_code: "opaque", session_id: "session" },
  });
  assertEquals(JSON.stringify(normalizeRouteStackFlightResults(payload)).includes("opaque"), false);
});
