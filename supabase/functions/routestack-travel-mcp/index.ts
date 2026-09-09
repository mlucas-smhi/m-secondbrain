import { createMcpHandler, McpServer } from "npm:@modelcontextprotocol/server@2.0.0";
import * as z from "npm:zod@4.5.4";
import {
  boundedRouteStackPayload,
  callRouteStack,
  routeStackFlightSearchPayload,
  routeStackHotelSearchPayload,
  routeStackCarSearchPayload,
} from "../_shared/routestack.ts";
import {
  normalizeRouteStackFlightResults,
  protectedRouteStackOfferRefs,
  validateCanonicalFlightResults,
} from "../_shared/flight-results.ts";
import { storeProtectedFlightResult } from "../_shared/tool-results.ts";

const flightSliceSchema = z.object({
  origin: z.string().trim().regex(/^[A-Za-z]{3}$/).transform((value) => value.toUpperCase()),
  destination: z.string().trim().regex(/^[A-Za-z]{3}$/).transform((value) => value.toUpperCase()),
  departure_date: z.iso.date(),
});
const passengerSchema = z.union([
  z.object({ type: z.literal("adult") }),
  z.object({ age: z.number().int().min(0).max(17) }),
]);
const carLocationSchema = z.object({
  code: z.string().trim().min(2).max(20),
  name: z.string().trim().min(1).max(200).optional(),
});

function result(payload: unknown) {
  const structuredContent = {
    provider: "routestack",
    retrieved_at: new Date().toISOString(),
    response: boundedRouteStackPayload(payload),
  };
  return {
    content: [{ type: "text" as const, text: JSON.stringify(structuredContent) }],
    structuredContent,
  };
}

function failure(error: unknown) {
  const message = error instanceof Error ? error.message : "RouteStack request failed";
  return { content: [{ type: "text" as const, text: message.slice(0, 1_000) }], isError: true };
}

function buildServer(baseUrl: string, apiKey: string, apiSecret: string): McpServer {
  const server = new McpServer({ name: "eleven-routestack-travel", version: "0.1.0" });

  server.registerTool("travel_flight_place_suggest", {
    title: "Suggest flight origins and destinations",
    description: "Resolve city, airport, or IATA text to canonical flight places.",
    inputSchema: z.object({ query: z.string().trim().min(2).max(200) }),
    annotations: { readOnlyHint: true, idempotentHint: true, destructiveHint: false },
  }, async ({ query }) => {
    try {
      return result(await callRouteStack(
        baseUrl, apiKey, apiSecret, "/mcp/flight/locations", { term: query },
      ));
    } catch (error) {
      return failure(error);
    }
  });

  server.registerTool("travel_flight_search", {
    title: "Search live flight inventory",
    description: "Search flight inventory without revalidating, ordering, paying, or booking.",
    inputSchema: z.object({
      slices: z.array(flightSliceSchema).min(1).max(2),
      passengers: z.array(passengerSchema).min(1).max(9),
      cabin_class: z.enum(["economy", "premium_economy", "business", "first"]).optional(),
      max_connections: z.number().int().min(0).max(3).optional(),
      tool_run_id: z.uuid().optional(),
    }),
    annotations: { readOnlyHint: true, idempotentHint: true, destructiveHint: false },
  }, async (input) => {
    try {
      const payload = await callRouteStack(
        baseUrl,
        apiKey,
        apiSecret,
        "/mcp/flight/search",
        routeStackFlightSearchPayload(input),
      );
      const normalized = normalizeRouteStackFlightResults(payload);
      validateCanonicalFlightResults(normalized);
      const resultRef = await storeProtectedFlightResult(
        input.tool_run_id, "routestack", normalized, protectedRouteStackOfferRefs(payload),
      );
      return result({ ...normalized, result_ref: resultRef });
    } catch (error) {
      return failure(error);
    }
  });

  server.registerTool("travel_hotel_place_suggest", {
    title: "Suggest hotel destinations",
    description: "Resolve destination text to RouteStack destination IDs and coordinates.",
    inputSchema: z.object({ query: z.string().trim().min(2).max(200) }),
    annotations: { readOnlyHint: true, idempotentHint: true, destructiveHint: false },
  }, async ({ query }) => {
    try {
      return result(await callRouteStack(
        baseUrl, apiKey, apiSecret, "/mcp/hotel/search-destinations", { query, type: "DESTINATION" },
      ));
    } catch (error) {
      return failure(error);
    }
  });

  server.registerTool("travel_hotel_search", {
    title: "Search live hotel inventory",
    description: "Search hotels without viewing rates, revalidating, holding, paying, or booking.",
    inputSchema: z.object({
      destination_id: z.string().trim().min(1).max(200),
      latitude: z.number().min(-90).max(90),
      longitude: z.number().min(-180).max(180),
      check_in_date: z.iso.date(),
      check_out_date: z.iso.date(),
      rooms: z.array(z.object({
        adults: z.number().int().min(1).max(8),
        child_ages: z.array(z.number().int().min(0).max(17)).max(6).optional(),
      })).min(1).max(8),
      currency: z.string().trim().regex(/^[A-Za-z]{3}$/).transform((value) => value.toUpperCase()).optional(),
      limit: z.number().int().min(1).max(20).optional(),
    }).refine((value) => value.check_out_date > value.check_in_date, {
      message: "check_out_date must be after check_in_date",
    }),
    annotations: { readOnlyHint: true, idempotentHint: true, destructiveHint: false },
  }, async (input) => {
    try {
      return result(await callRouteStack(
        baseUrl, apiKey, apiSecret, "/mcp/hotel/search-hotels", routeStackHotelSearchPayload(input),
      ));
    } catch (error) {
      return failure(error);
    }
  });

  server.registerTool("travel_car_place_suggest", {
    title: "Suggest car rental locations",
    description: "Resolve airport or city text to RouteStack car rental location codes.",
    inputSchema: z.object({ query: z.string().trim().min(2).max(200) }),
    annotations: { readOnlyHint: true, idempotentHint: true, destructiveHint: false },
  }, async ({ query }) => {
    try {
      return result(await callRouteStack(
        baseUrl, apiKey, apiSecret, "/mcp/car/locations", { term: query },
      ));
    } catch (error) {
      return failure(error);
    }
  });

  server.registerTool("travel_car_search", {
    title: "Search live car rental inventory",
    description: "Search rental cars without revalidating, holding, paying, ordering, or booking.",
    inputSchema: z.object({
      pickup: carLocationSchema,
      dropoff: carLocationSchema.optional(),
      pickup_date: z.iso.date(),
      pickup_time: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/),
      dropoff_date: z.iso.date(),
      dropoff_time: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/),
      limit: z.number().int().min(1).max(20).optional(),
    }).refine((value) => `${value.dropoff_date}T${value.dropoff_time}` > `${value.pickup_date}T${value.pickup_time}`, {
      message: "dropoff must be after pickup",
    }),
    annotations: { readOnlyHint: true, idempotentHint: true, destructiveHint: false },
  }, async (input) => {
    try {
      return result(await callRouteStack(
        baseUrl, apiKey, apiSecret, "/mcp/car/search", routeStackCarSearchPayload(input),
      ));
    } catch (error) {
      return failure(error);
    }
  });

  return server;
}

const handler = createMcpHandler(() => {
  const baseUrl = Deno.env.get("ROUTESTACK_BASE_URL");
  const apiKey = Deno.env.get("ROUTESTACK_API_KEY");
  const apiSecret = Deno.env.get("ROUTESTACK_API_SECRET");
  if (!baseUrl || !apiKey || !apiSecret) throw new Error("RouteStack is not configured");
  return buildServer(baseUrl, apiKey, apiSecret);
}, { responseMode: "json" });

function timingSafeEqual(left: string, right: string): boolean {
  const encoder = new TextEncoder();
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index++) difference |= a[index] ^ b[index];
  return difference === 0;
}

Deno.serve((request) => {
  const serverKey = Deno.env.get("TRAVEL_MCP_API_KEY");
  if (!serverKey) return Response.json({ error: "server_misconfigured" }, { status: 500 });
  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer ") ||
      !timingSafeEqual(authorization.slice(7), serverKey)) {
    return new Response(null, { status: 401, headers: { "WWW-Authenticate": "Bearer" } });
  }
  const origin = request.headers.get("origin");
  const allowedOrigins = (Deno.env.get("TRAVEL_MCP_ALLOWED_ORIGINS") ?? "")
    .split(",").map((value) => value.trim()).filter(Boolean);
  if (origin && !allowedOrigins.includes(origin)) {
    return Response.json({ error: "origin_not_allowed" }, { status: 403 });
  }
  if (request.method === "DELETE") return new Response(null, { status: 405 });
  return handler.fetch(request, {
    authInfo: { token: serverKey, clientId: "n8n-travel-research", scopes: ["travel:read"] },
  });
});
