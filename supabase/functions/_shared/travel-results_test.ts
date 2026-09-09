import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  normalizeRouteStackCarResults,
  normalizeRouteStackHotelResults,
  protectedRouteStackCarRefs,
  protectedRouteStackHotelRefs,
  validateCanonicalTravelResults,
} from "./travel-results.ts";

Deno.test("normalizes RouteStack hotels without provider handles", () => {
  const payload = { result: { count: 451, currency: "USD", correlationId: "secret", token: "session", result: [{
    id: "hotel-1", name: "The Langham", starRating: 5, ourprice: 5230.44,
    options: { refundable: true, freeCancellation: true, freeBreakfast: true },
    payAtHotel: true, distancekm: 4.54, contact: { address: { line1: "400 Fifth Avenue" } },
  }] } };
  const result = normalizeRouteStackHotelResults(payload);
  validateCanonicalTravelResults(result);
  assertEquals(result.offer_count, 451);
  assertEquals(result.offers[0].payment_timing, "pay_later");
  assertEquals(JSON.stringify(result).includes("secret"), false);
  assertEquals(protectedRouteStackHotelRefs(payload)["routestack-hotel:1"], {
    correlation_id: "secret", token: "session", hotel_id: "hotel-1",
  });
});

Deno.test("normalizes RouteStack cars without fare codes", () => {
  const payload = { result: { count: 65, currency: "USD", correlationId: "secret", cars: [{
    fareCode: "opaque", vehicle_code: "FCAR", name: "Toyota Camry or similar",
    description: "Full-Size Car", passengers: 5, bags: 3, doors: 4, hasAMT: true, hasAC: true,
    partner: { name: "Budget Rent a Car" }, price_postpaid: {
      total: 200.42, currency: "USD", days: 2, pay_at_booking: false,
      free_cancellation: true, mileage: true,
    },
  }] } };
  const result = normalizeRouteStackCarResults(payload);
  validateCanonicalTravelResults(result);
  assertEquals(result.offers[0].supplier, "Budget Rent a Car");
  assertEquals(result.offers[0].total_amount, 200.42);
  assertEquals(JSON.stringify(result).includes("opaque"), false);
  assertEquals(protectedRouteStackCarRefs(payload)["routestack-car:1"], {
    correlation_id: "secret", token: null, fare_code: "opaque", vehicle_code: "FCAR",
  });
});

Deno.test("rejects hotel and car offers without ISO currency", () => {
  const result = normalizeRouteStackHotelResults({ result: { result: [{ ourprice: 100 }] } });
  assertThrows(() => validateCanonicalTravelResults(result), Error, "missing an ISO currency");
});
