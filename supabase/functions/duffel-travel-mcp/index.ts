import { createMcpHandler, McpServer } from "npm:@modelcontextprotocol/server@2.0.0";
import * as z from "npm:zod@4.5.4";
import {
  boundedProviderPayload,
  callDuffel,
  duffelFlightOfferPath,
  duffelFlightSearchRequest,
  duffelPlaceSuggestionsPath,
} from "../_shared/duffel.ts";
import {
  normalizeDuffelFlightResults,
  protectedDuffelOfferRefs,
  validateCanonicalFlightResults,
} from "../_shared/flight-results.ts";
import { storeProtectedFlightResult } from "../_shared/tool-results.ts";

const SERVER_NAME = "eleven-duffel-travel";
const SERVER_VERSION = "0.1.0";

const coordinateSchema = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
});

const locationSchema = z.object({
  radius: z.number().int().min(1).max(100).default(5),
  geographic_coordinates: coordinateSchema,
});

const guestSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("adult") }),
  z.object({ type: z.literal("child"), age: z.number().int().min(0).max(17) }),
]);

const flightSliceSchema = z.object({
  origin: z.string().trim().regex(/^[A-Za-z]{3}$/).transform((value) => value.toUpperCase()),
  destination: z.string().trim().regex(/^[A-Za-z]{3}$/).transform((value) => value.toUpperCase()),
  departure_date: z.iso.date(),
});

const flightPassengerSchema = z.union([
  z.object({ type: z.literal("adult") }),
  z.object({ age: z.number().int().min(0).max(17) }),
]);

function toolResult(payload: unknown) {
  const structuredContent = {
    provider: "duffel",
    retrieved_at: new Date().toISOString(),
    response: boundedProviderPayload(payload),
  };
  return {
    content: [{ type: "text" as const, text: JSON.stringify(structuredContent) }],
    structuredContent,
  };
}

function errorResult(error: unknown) {
  const message = error instanceof Error ? error.message : "Duffel request failed";
  return {
    content: [{ type: "text" as const, text: message.slice(0, 1_000) }],
    isError: true,
  };
}

function buildServer(accessToken: string): McpServer {
  const server = new McpServer({ name: SERVER_NAME, version: SERVER_VERSION });

  // These operation names and inputs are the provider-neutral contract. A
  // replacement adapter must expose the same surface and translate internally.
  server.registerTool(
    "travel_flight_place_suggest",
    {
      title: "Suggest flight origins and destinations",
      description: "Resolve city, airport, or IATA text to canonical flight places.",
      inputSchema: z.object({ query: z.string().trim().min(2).max(200) }),
      annotations: { readOnlyHint: true, idempotentHint: true, destructiveHint: false },
    },
    async ({ query }) => {
      try {
        return toolResult(await callDuffel(accessToken, duffelPlaceSuggestionsPath(query)));
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "travel_flight_search",
    {
      title: "Search live flight inventory",
      description: "Search flight offers without holding, ordering, paying for, or changing travel.",
      inputSchema: z.object({
        slices: z.array(flightSliceSchema).min(1).max(6),
        passengers: z.array(flightPassengerSchema).min(1).max(9),
        cabin_class: z.enum(["economy", "premium_economy", "business", "first"]).optional(),
        max_connections: z.number().int().min(0).max(3).optional(),
        tool_run_id: z.uuid().optional(),
      }),
      annotations: { readOnlyHint: true, idempotentHint: true, destructiveHint: false },
    },
    async (input) => {
      try {
        const { tool_run_id, ...searchInput } = input;
        const request = duffelFlightSearchRequest(searchInput);
        const payload = await callDuffel(accessToken, request.path, {
          method: "POST",
          data: request.data,
        });
        const normalized = normalizeDuffelFlightResults(payload);
        validateCanonicalFlightResults(normalized);
        const resultRef = await storeProtectedFlightResult(
          tool_run_id, "duffel", normalized, protectedDuffelOfferRefs(payload),
        );
        return toolResult({ ...normalized, result_ref: resultRef });
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "travel_flight_offer_details",
    {
      title: "Get current flight offer details",
      description: "Refresh price, expiry, itinerary, and conditions for one flight offer.",
      inputSchema: z.object({ offer_id: z.string().trim().min(1).max(200) }),
      annotations: { readOnlyHint: true, idempotentHint: true, destructiveHint: false },
    },
    async ({ offer_id }) => {
      try {
        return toolResult(await callDuffel(accessToken, duffelFlightOfferPath(offer_id)));
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "travel_hotel_suggest",
    {
      title: "Suggest hotels",
      description: "Resolve hotel names or destination text to Duffel accommodation IDs.",
      inputSchema: z.object({
        query: z.string().trim().min(3).max(200),
        location: locationSchema.optional(),
      }),
      annotations: { readOnlyHint: true, idempotentHint: true, destructiveHint: false },
    },
    async ({ query, location }) => {
      try {
        return toolResult(await callDuffel(accessToken, "/stays/accommodation/suggestions", {
          method: "POST",
          data: { query, ...(location ? { location } : {}) },
        }));
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "travel_hotel_search",
    {
      title: "Search live hotel inventory",
      description: "Search available Duffel Stays inventory for exact dates and guests.",
      inputSchema: z.object({
        check_in_date: z.iso.date(),
        check_out_date: z.iso.date(),
        guests: z.array(guestSchema).min(1).max(16),
        rooms: z.number().int().min(1).max(8),
        location: locationSchema.optional(),
        accommodation_ids: z.array(z.string().trim().min(1)).min(1).max(20).optional(),
      }).refine(
        (value) => Boolean(value.location) !== Boolean(value.accommodation_ids),
        { message: "provide exactly one of location or accommodation_ids" },
      ).refine(
        (value) => value.check_out_date > value.check_in_date,
        { message: "check_out_date must be after check_in_date" },
      ),
      annotations: { readOnlyHint: true, idempotentHint: true, destructiveHint: false },
    },
    async (input) => {
      try {
        return toolResult(await callDuffel(accessToken, "/stays/search", {
          method: "POST",
          data: input,
        }));
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "travel_hotel_details",
    {
      title: "Get hotel details",
      description: "Retrieve current details for one Duffel accommodation ID.",
      inputSchema: z.object({ accommodation_id: z.string().trim().min(1).max(200) }),
      annotations: { readOnlyHint: true, idempotentHint: true, destructiveHint: false },
    },
    async ({ accommodation_id }) => {
      try {
        return toolResult(await callDuffel(
          accessToken,
          `/stays/accommodation/${encodeURIComponent(accommodation_id)}`,
        ));
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "travel_hotel_rates",
    {
      title: "Get hotel room rates",
      description: "Retrieve rooms and available rates for one Duffel stay search result.",
      inputSchema: z.object({ search_result_id: z.string().trim().min(1).max(200) }),
      annotations: { readOnlyHint: true, idempotentHint: true, destructiveHint: false },
    },
    async ({ search_result_id }) => {
      try {
        return toolResult(await callDuffel(
          accessToken,
          `/stays/search_results/${encodeURIComponent(search_result_id)}/actions/fetch_all_rates`,
          { method: "POST" },
        ));
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  return server;
}

const handler = createMcpHandler(() => {
  const token = Deno.env.get("DUFFEL_ACCESS_TOKEN");
  if (!token) throw new Error("DUFFEL_ACCESS_TOKEN is not configured");
  return buildServer(token);
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

Deno.serve(async (request) => {
  const serverKey = Deno.env.get("TRAVEL_MCP_API_KEY");
  if (!serverKey) return Response.json({ error: "server_misconfigured" }, { status: 500 });

  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer ") ||
      !timingSafeEqual(authorization.slice(7), serverKey)) {
    return new Response(null, {
      status: 401,
      headers: { "WWW-Authenticate": "Bearer" },
    });
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
