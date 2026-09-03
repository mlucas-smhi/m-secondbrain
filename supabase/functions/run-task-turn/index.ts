const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" };
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type RunTaskTurnRequest = {
  task_id?: unknown;
  call_id?: unknown;
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function postgresStatus(error: unknown): number {
  if (!error || typeof error !== "object" || !("code" in error)) return 502;

  switch ((error as { code?: unknown }).code) {
    case "P0002":
      return 404;
    case "40001":
      return 409;
    case "22023":
      return 422;
    default:
      return 502;
  }
}

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return json(405, { error: "method_not_allowed" });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseUrl || !serviceRoleKey) {
    console.error("Missing required Supabase environment variables");
    return json(500, { error: "server_misconfigured" });
  }

  // This is an internal runner endpoint. The gateway verifies the credential;
  // this comparison additionally prevents ordinary authenticated users from
  // invoking a service-role database transition.
  if (request.headers.get("authorization") !== `Bearer ${serviceRoleKey}`) {
    return json(403, { error: "service_role_required" });
  }

  let body: RunTaskTurnRequest;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (typeof body.task_id !== "string" || !UUID_PATTERN.test(body.task_id)) {
    return json(400, { error: "invalid_task_id" });
  }

  if (typeof body.call_id !== "string" || body.call_id.trim().length === 0) {
    return json(400, { error: "call_id_required" });
  }

  const rpcResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/advance_task`, {
    method: "POST",
    headers: {
      ...JSON_HEADERS,
      apikey: serviceRoleKey,
      authorization: `Bearer ${serviceRoleKey}`,
    },
    body: JSON.stringify({
      p_task_id: body.task_id,
      p_event_type: "turn.started",
      p_actor: "run-task-turn",
      p_call_id: body.call_id.trim(),
      p_expected_status: "new",
      p_patch: {
        status: "running",
        current_step: "run-task-turn",
      },
    }),
  });

  const result: unknown = await rpcResponse.json().catch(() => null);
  if (!rpcResponse.ok) {
    console.error("advance_task failed", result);
    return json(postgresStatus(result), {
      error: "turn_not_advanced",
      details: result,
    });
  }

  return json(200, { task: result });
});
