type JsonObject = Record<string, unknown>;

function object(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : {};
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value : null;
}

function number(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function bool(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null;
}

function envelope(payload: unknown): JsonObject {
  const root = object(payload);
  return object(root.result ?? object(root.data).result);
}

type ResultBase = {
  schema_version: "travel.hotel_search.v1" | "travel.car_search.v1";
  provider: "routestack";
  retrieved_at: string;
  valid_until: string;
};

function validity(schemaVersion: ResultBase["schema_version"], provider: "routestack"): ResultBase {
  const retrieved = new Date();
  return {
    schema_version: schemaVersion,
    provider,
    retrieved_at: retrieved.toISOString(),
    valid_until: new Date(retrieved.getTime() + 10 * 60_000).toISOString(),
  };
}

export type CanonicalHotelOffer = {
  offer_key: string;
  name: string | null;
  star_rating: number | null;
  total_amount: number | null;
  total_currency: string | null;
  published_amount: number | null;
  distance_km: number | null;
  address: string | null;
  chain: string | null;
  payment_timing: "prepaid" | "pay_later" | null;
  refundable: boolean | null;
  free_cancellation: boolean | null;
  breakfast_included: boolean | null;
  image_url: string | null;
};

export type CanonicalHotelResults = ResultBase & {
  schema_version: "travel.hotel_search.v1";
  offer_count: number;
  returned_count: number;
  truncated: boolean;
  offers: CanonicalHotelOffer[];
};

export type CanonicalCarOffer = {
  offer_key: string;
  vehicle_name: string | null;
  category: string | null;
  supplier: string | null;
  total_amount: number | null;
  total_currency: string | null;
  rental_days: number | null;
  passengers: number | null;
  bags: number | null;
  doors: number | null;
  automatic: boolean | null;
  air_conditioning: boolean | null;
  fuel_type: string | null;
  pay_at_booking: boolean | null;
  free_cancellation: boolean | null;
  unlimited_mileage: boolean | null;
  pickup_location: string | null;
  dropoff_location: string | null;
  image_url: string | null;
};

export type CanonicalCarResults = ResultBase & {
  schema_version: "travel.car_search.v1";
  offer_count: number;
  returned_count: number;
  truncated: boolean;
  offers: CanonicalCarOffer[];
};

export type CanonicalTravelResults = CanonicalHotelResults | CanonicalCarResults;

export function normalizeRouteStackHotelResults(payload: unknown, maxOffers = 12): CanonicalHotelResults {
  const result = envelope(payload);
  const rawOffers = array(result.result ?? result.hotels);
  const count = number(result.count) ?? rawOffers.length;
  const currency = text(result.currency);
  const offers = rawOffers.slice(0, maxOffers).map((value, index): CanonicalHotelOffer => {
    const hotel = object(value);
    const options = object(hotel.options);
    const contact = object(hotel.contact);
    return {
      offer_key: `routestack-hotel:${index + 1}`,
      name: text(hotel.name),
      star_rating: number(hotel.starRating),
      total_amount: number(hotel.ourprice ?? hotel.showOurprice),
      total_currency: text(hotel.currency) ?? currency,
      published_amount: number(hotel.publishedRate),
      distance_km: number(hotel.distancekm),
      address: text(object(contact.address).line1),
      chain: text(hotel.chain),
      payment_timing: bool(hotel.payAtHotel) === true ? "pay_later" :
        (text(hotel.ratetype)?.toUpperCase() === "PREPAID" ? "prepaid" : null),
      refundable: bool(options.refundable),
      free_cancellation: bool(options.freeCancellation),
      breakfast_included: bool(options.freeBreakfast),
      image_url: text(hotel.heroImage),
    };
  });
  return {
    ...validity("travel.hotel_search.v1", "routestack"),
    offer_count: count,
    returned_count: offers.length,
    truncated: count > offers.length,
    offers,
  };
}

export function normalizeRouteStackCarResults(payload: unknown, maxOffers = 12): CanonicalCarResults {
  const result = envelope(payload);
  const rawOffers = array(result.cars ?? result.result);
  const count = number(result.count) ?? rawOffers.length;
  const currency = text(result.currency);
  const offers = rawOffers.slice(0, maxOffers).map((value, index): CanonicalCarOffer => {
    const car = object(value);
    const price = object(car.price_postpaid ?? car.price_prepaid);
    return {
      offer_key: `routestack-car:${index + 1}`,
      vehicle_name: text(car.name),
      category: text(car.description ?? car.type_name),
      supplier: text(object(car.partner).name),
      total_amount: number(price.total ?? car.display_price),
      total_currency: text(price.currency) ?? currency,
      rental_days: number(price.days),
      passengers: number(car.passengers),
      bags: number(car.bags),
      doors: number(car.doors),
      automatic: bool(car.hasAMT),
      air_conditioning: bool(car.hasAC),
      fuel_type: text(car.fuelType),
      pay_at_booking: bool(price.pay_at_booking),
      free_cancellation: bool(price.free_cancellation),
      unlimited_mileage: bool(price.mileage ?? car.mileage),
      pickup_location: text(object(car.pickup).location),
      dropoff_location: text(object(car.dropoff).location),
      image_url: text(car.heroImage),
    };
  });
  return {
    ...validity("travel.car_search.v1", "routestack"),
    offer_count: count,
    returned_count: offers.length,
    truncated: count > offers.length,
    offers,
  };
}

export function validateCanonicalTravelResults(result: CanonicalTravelResults): void {
  if (!result.offers.length) throw new Error("travel search returned no valid offers");
  if (Date.parse(result.valid_until) <= Date.now()) throw new Error("travel search result is stale");
  for (const offer of result.offers) {
    if (offer.total_amount === null || offer.total_amount <= 0) {
      throw new Error(`travel offer ${offer.offer_key} is missing a valid total amount`);
    }
    if (!offer.total_currency || !/^[A-Z]{3}$/.test(offer.total_currency)) {
      throw new Error(`travel offer ${offer.offer_key} is missing an ISO currency`);
    }
  }
}

function protectedEnvelopeRefs(payload: unknown): JsonObject {
  const root = object(payload);
  const result = envelope(payload);
  return {
    correlation_id: text(result.correlationId ?? root.correlationId),
    token: text(result.token ?? root.token),
  };
}

export function protectedRouteStackHotelRefs(payload: unknown, maxOffers = 12): Record<string, unknown> {
  const result = envelope(payload);
  const common = protectedEnvelopeRefs(payload);
  return Object.fromEntries(array(result.result ?? result.hotels).slice(0, maxOffers).map((value, index) => {
    const hotel = object(value);
    return [`routestack-hotel:${index + 1}`, {
      ...common,
      hotel_id: text(hotel.id),
      token: text(hotel.token) ?? common.token,
    }];
  }));
}

export function protectedRouteStackCarRefs(payload: unknown, maxOffers = 12): Record<string, unknown> {
  const result = envelope(payload);
  const common = protectedEnvelopeRefs(payload);
  return Object.fromEntries(array(result.cars ?? result.result).slice(0, maxOffers).map((value, index) => {
    const car = object(value);
    return [`routestack-car:${index + 1}`, {
      ...common,
      fare_code: text(car.fareCode),
      vehicle_code: text(car.vehicle_code),
    }];
  }));
}
