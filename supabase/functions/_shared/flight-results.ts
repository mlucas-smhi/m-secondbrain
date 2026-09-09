export type CanonicalFlightOffer = {
  offer_key: string;
  total_amount: number | null;
  total_currency: string | null;
  duration_minutes: number | null;
  stops: number | null;
  remaining_seats: number | null;
  fare_brand: string | null;
  segments: Array<{
    marketing_carrier: string | null;
    flight_number: string | null;
    origin: string | null;
    destination: string | null;
    departing_at: string | null;
    arriving_at: string | null;
    cabin: string | null;
  }>;
};

export type CanonicalFlightResults = {
  schema_version: "travel.flight_search.v1";
  provider: "duffel" | "routestack";
  retrieved_at: string;
  valid_until: string;
  offer_count: number;
  returned_count: number;
  truncated: boolean;
  offers: CanonicalFlightOffer[];
};

type JsonObject = Record<string, unknown>;

function object(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : {};
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function text(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function number(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function durationMinutes(value: unknown): number | null {
  const direct = number(value);
  if (direct !== null) return direct;
  const match = /^PT(?:(\d+)H)?(?:(\d+)M)?$/.exec(text(value) ?? "");
  return match ? Number(match[1] ?? 0) * 60 + Number(match[2] ?? 0) : null;
}

function base(provider: CanonicalFlightResults["provider"], offers: CanonicalFlightOffer[], count: number, maxOffers: number): CanonicalFlightResults {
  const retrievedAt = new Date();
  return {
    schema_version: "travel.flight_search.v1",
    provider,
    retrieved_at: retrievedAt.toISOString(),
    valid_until: new Date(retrievedAt.getTime() + 10 * 60_000).toISOString(),
    offer_count: count,
    returned_count: offers.length,
    truncated: count > maxOffers,
    offers,
  };
}

export function validateCanonicalFlightResults(result: CanonicalFlightResults): void {
  if (result.schema_version !== "travel.flight_search.v1" || result.offers.length === 0) {
    throw new Error("flight search returned no valid offers");
  }
  if (Date.parse(result.valid_until) <= Date.now()) throw new Error("flight search result is stale");
  for (const offer of result.offers) {
    if (offer.total_amount === null || offer.total_amount <= 0) {
      throw new Error(`flight offer ${offer.offer_key} is missing a valid total amount`);
    }
    if (!offer.total_currency || !/^[A-Z]{3}$/.test(offer.total_currency)) {
      throw new Error(`flight offer ${offer.offer_key} is missing an ISO currency`);
    }
    if (offer.segments.length === 0) throw new Error(`flight offer ${offer.offer_key} has no segments`);
    offer.segments.forEach((segment, index) => {
      if (!segment.origin || !segment.destination || !segment.departing_at || !segment.arriving_at) {
        throw new Error(`flight offer ${offer.offer_key} has an incomplete segment`);
      }
      if (Date.parse(segment.departing_at) >= Date.parse(segment.arriving_at)) {
        throw new Error(`flight offer ${offer.offer_key} has invalid segment times`);
      }
      if (index > 0 && offer.segments[index - 1].destination !== segment.origin) {
        throw new Error(`flight offer ${offer.offer_key} has a broken route`);
      }
    });
  }
}

export function protectedDuffelOfferRefs(payload: unknown, maxOffers = 12): Record<string, unknown> {
  const root = object(payload);
  const offers = array(object(root.data).offers ?? root.data).slice(0, maxOffers).map(object);
  return Object.fromEntries(offers.map((offer, index) => [
    text(offer.id) ?? `duffel:${index + 1}`,
    { offer_id: text(offer.id), expires_at: text(offer.expires_at) },
  ]));
}

export function protectedRouteStackOfferRefs(payload: unknown, maxOffers = 12): Record<string, unknown> {
  const root = object(payload);
  const offers = array(root.result ?? object(root.data).result).slice(0, maxOffers).map(object);
  return Object.fromEntries(offers.map((offer, index) => [
    `routestack:${index + 1}`,
    { fare_source_code: text(offer.fareSourceCode), session_id: text(offer.sessionId) },
  ]));
}

export function normalizeDuffelFlightResults(payload: unknown, maxOffers = 12): CanonicalFlightResults {
  const root = object(payload);
  const request = object(root.data);
  const rawOffers = array(request.offers ?? root.data);
  const offers = rawOffers.slice(0, maxOffers).map((value, index): CanonicalFlightOffer => {
    const offer = object(value);
    const slices = array(offer.slices).map(object);
    const segments = slices.flatMap((slice) => array(slice.segments).map((segmentValue) => {
      const segment = object(segmentValue);
      const marketingCarrier = object(segment.marketing_carrier);
      return {
        marketing_carrier: text(marketingCarrier.iata_code ?? marketingCarrier.name),
        flight_number: text(segment.marketing_carrier_flight_number),
        origin: text(object(segment.origin).iata_code),
        destination: text(object(segment.destination).iata_code),
        departing_at: text(segment.departing_at),
        arriving_at: text(segment.arriving_at),
        cabin: text(object(array(segment.passengers)[0]).cabin_class),
      };
    }));
    return {
      offer_key: text(offer.id) ?? `duffel:${index + 1}`,
      total_amount: number(offer.total_amount),
      total_currency: text(offer.total_currency),
      duration_minutes: slices.reduce<number | null>((sum, slice) => {
        const minutes = durationMinutes(slice.duration);
        return minutes === null ? sum : (sum ?? 0) + minutes;
      }, null),
      stops: segments.length > 0 ? Math.max(0, segments.length - slices.length) : null,
      remaining_seats: null,
      fare_brand: null,
      segments,
    };
  });
  return base("duffel", offers, rawOffers.length, maxOffers);
}

export function normalizeRouteStackFlightResults(payload: unknown, maxOffers = 12): CanonicalFlightResults {
  const root = object(payload);
  const rawOffers = array(root.result ?? object(root.data).result);
  const declaredCount = number(root.count) ?? rawOffers.length;
  const offers = rawOffers.slice(0, maxOffers).map((value, index): CanonicalFlightOffer => {
    const offer = object(value);
    const flights = array(offer.flights).map(object);
    const amounts = object(array(offer.fares ?? offer.fare)[0] ?? offer);
    const segmentSeats = flights.map((flight) => number(flight.remainingSeats)).filter((seat): seat is number => seat !== null);
    return {
      offer_key: `routestack:${index + 1}`,
      total_amount: number(offer.showOurprice ?? offer.ourprice ?? offer.totalFare ?? amounts.totalFare),
      total_currency: text(offer.currency ?? amounts.currency),
      duration_minutes: flights.reduce<number | null>((sum, flight) => {
        const minutes = durationMinutes(flight.triptime);
        return minutes === null ? sum : (sum ?? 0) + minutes;
      }, null),
      stops: number(offer.stops) ?? (flights.length ? flights.length - 1 : null),
      remaining_seats: segmentSeats.length ? Math.min(...segmentSeats) : null,
      fare_brand: text(flights[0]?.fareFamily),
      segments: flights.map((flight) => ({
        marketing_carrier: text(flight.flightCode ?? flight.airline),
        flight_number: text(flight.flightNumber),
        origin: text(flight.departure),
        destination: text(flight.arrival),
        departing_at: text(flight.departureTime),
        arriving_at: text(flight.arrivalTime),
        cabin: text(flight.cabin),
      })),
    };
  });
  return base("routestack", offers, declaredCount, maxOffers);
}
