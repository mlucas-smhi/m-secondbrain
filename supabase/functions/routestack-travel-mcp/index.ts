import { createMcpHandler, McpServer } from "npm:@modelcontextprotocol/server@2.0.0";
import * as z from "npm:zod@4.5.4";
import {
  boundedRouteStackPayload,
  callRouteStack,
  routeStackFlightSearchPayload,
} from "../_shared/routestack.ts";
import { normalizeRouteStackFlightResults } from "../_shared/flight-results.ts";

const flightSliceSchema = z.object({
  origin: z.string().trim().regex(/^[A-Za-z]{3}$/).transform((value) => value.toUpperCase()),
  destination: z.string().trim().regex(/^[A-Za-z]{3}$/).transform((value) => value.toUpperCase()),
  departure_date: z.iso.date(),
});
const passengerSchema = z.union([
  z.object({ type: z.literal("adult") }),
  z.object({ age: z.number().int().min(0).max(17) }),
]);

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
    }),
    annotations: { readOnlyHint: true, idempotentHint: true, destructiveHint: false },
  }, async (input) => {
    try {
      return result(normalizeRouteStackFlightResults(await callRouteStack(
        baseUrl,
        apiKey,
        apiSecret,
        "/mcp/flight/search",
        routeStackFlightSearchPayload(input),
      )));
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
