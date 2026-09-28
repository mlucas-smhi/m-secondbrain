# Eleven.a — isolated native MCP chat setup

No Twilio number, voice configuration, call routing, or bridge deployment.
The original Eleven agent's conversation config, platform config, workflow,
and phone assignments were compared before/after and are unchanged.

## Connection

- Agent: `agent_4801m2dmpzs0e2k9r7392kzn7vxq` (Eleven.a).
- Branch: `agtbrch_8701m2dmpzsqexdb01aq6w63dgm7`.
- Initial configuration version: `agtvrsn_2301m3jvxn2eed08gqc7bpbhp1mn`.
- Plan-context prompt version: `agtvrsn_2001m3jyfg2yfwx8vhtxjx9gja43`.
- Current partial-test candidate: `agtvrsn_1001m3k29wtwf119e2vhad76dpy2`.
  See `ELEVEN-A-PARTIALS-2026-09-27.md` for improvements and regressions; this is
  not a production-approved prompt.
- Mode: authenticated text-only; existing TTS config left untouched.
- Model: `gemini-3.5-flash-lite`, matching the original Eleven, replacing this
  older duplicate's `claude-opus-4-7` setting for the controlled comparison.
- MCP server: `Vt7hrlqXIsPmxH5eHcdm`.
- URL: `https://litegraph-memory-poc.thankfulriver-72a195a7.southcentralus.azurecontainerapps.io/eleven-a-mcp`.
- Transport: native LiteGraph MCP, `STREAMABLE_HTTP`; no memory facade or n8n.
- Tenant: `10a5bb87-eabc-534a-b37c-b41987f2e633`.
- Graph: `e6d076f3-454a-5f3c-8d32-6c56a0953076`.
- Backend user: `5e78e65a-69ca-4a07-9c86-f688aae5eacc`, non-admin.
- Backend credential ID: `411746c9-d306-4f0d-b428-9629cf433cfa`.
  Scopes are read/write, graph allowlist contains only the above graph.

Eight tools are automatically approved: `node/search`, `node/all`, `node/get`,
`node/create`, `node/update`, `edge/all`, `edge/create`, `graph/query`.
Discovery still advertises 209 native tools; the rest remain unapproved.
This is not a claim that the native server's advertised catalog was reduced.

The older duplicate's GitHub and other MCP references, 29 external tool refs,
and any knowledge-base references were detached from Eleven.a only. Workspace
integrations/tools were NOT deleted. No external actions are available to this
agent. Client prompt overrides are disabled; authenticated access remains on.

## Prompt

`bridge/scenario_agent.py:chat_prompt` builds the test prompt from the shared
`eleven-private-memory.md` retrieval/save instructions. It replaces real-owner
identity/examples with Casey/Alex, inserts only the synthetic scope IDs, and
adds chat-only and simulation context. It does not read the evaluator answer key.
No GitHub startup checklist, telephone placeholders or onboarding flows remain.

The test-only builder also appends a general plan-context check: resolve the
requested activity, expand relevant commitments/relationships, compare timing,
location and other constraints, then advise. Missing booking integrations do
not excuse skipping memory-based advice. No fixture-specific answers are added.
The shared production prompt and production agent remain unchanged.

The test clock is October 5, 2026 at 10am America/Chicago, intentionally fixed
for the dated scenarios. The greeting is “Hi Casey. What are we working on?”
The operator plays Casey in these tests. Initial data, scoring and special test
requirements are in `MEMORY-SCENARIOS.md`; this document does not mark them passed.

## Memory-host change

An additive revision `litegraph-memory-poc--eleven-a-0927` adds a native
`jchristn77/litegraph-mcp:v8.1.0` sidecar named `eleven-a-mcp`, listening on
HTTP 8722, with auxiliary loopback listeners on 127.0.0.4. It uses only the
restricted `eleven-a-credential` Azure secret. Resources: 0.25 CPU / 0.5 GiB.
It shares the existing host; no separate Container App or database was created.

The gateway's versioned Azure Files config `Caddyfile.eleven-a-0927` preserves
all prior routes and adds `/eleven-a-mcp*`, authenticated using a separate
`eleven-a-edge-token`, then rewritten to `/mcp` at 127.0.0.1:8722.
ElevenLabs uses a dedicated workspace Authorization secret, not the live
agent's token. No secret values are stored in this repository.

Adding the sidecar rolled the shared memory app to a new revision. That is a
memory-host deployment, despite there being no voice or phone plumbing changes.
Original sidecars, database settings, memory records and route credentials were
preserved. The prior gateway config was not overwritten.

## Boundary and transport checks completed

- Anonymous test endpoint request: HTTP 401.
- Own scope: 24 nodes (23 entities + import receipt).
- Foreign synthetic graph: enumeration, search, direct-ID read, update denied.
- Real 11 graph: enumeration, search, direct-ID read denied.
- 2's graph: enumeration/search denied.
- Tenant administration/discovery denied.
- Native create/update/readback succeeded for one uniquely named disposable
  connectivity probe. Only that probe was deleted after checking its exact
  GUID, name and Data; the graph returned to 24 nodes.
- ElevenLabs discovery succeeded, with exactly the eight selected tools marked
  `up_to_date` and `auto_approved`.
- A real authenticated text-only conversation
  `conv_9101m3jw75rhe21bw9cc16r7hh0p` answered “What's Robin's food preference?”
  with the seeded vegetarian restriction (including no fish/seafood). Measured
  user-message-to-answer time was approximately 3.37 seconds on this one probe;
  this is not a latency benchmark or proof that the entire scenario suite passed.
- Post-rollout discovery succeeded for all five existing/new memory routes:
  `/mcp`, `/memory-mcp`, `/eleven-facade-mcp`, `/eleven-private-mcp`, and
  `/eleven-a-mcp`. Previous secret values were unchanged. Voice bridge health
  remained `ok`.

These checks verify the tested boundaries and transport, not every possible
authorization path or full conversational save/reasoning quality. Native
read/write permissions remain broader than the eight ElevenLabs-approved tools
inside this synthetic graph; tool approvals are not a replacement for backend
tenant/graph isolation.

## Plan-context regression checks

Initial scenario #1 failed in `conv_3901m3jwyvbvf8bt4rb4qw91e939`:
five successful native reads found the flight and owner profile but never read
the meeting. The response endorsed the option without a compatibility check.

After the prompt-only change above, two fresh authenticated text chats produced:

| Test | Conversation | Observed result | Answer latency | Summed tool latency |
|---|---|---|---|---|
| Monday 11am SFO proposal | `conv_4501m3jyg0xnfd0t0rrxjspqg4ka` | Flagged the Houston 2–3pm in-person review conflict | 8.53s | 2.51s / 6 calls |
| Friday 6pm Houston arrival proposal, without mentioning school | `conv_8601m3jyh4w8emervy423vrynkk7` | Retrieved school event; calculated 7:30pm arrival versus 6:30pm start / 6:15pm target | 6.28s | 1.32s / 4 calls |

Completed traces confirm actual retrieval, not answers inserted in the prompt.
The first used name search, flight read, one edge/all page containing all 31
relationship records, and two connected event/meeting reads. The second used
targeted flight and Charlie searches/readbacks. No write tools or external
action tools ran in either test. No full-node-directory sweep occurred.

These are single-run passes of the specific conflict checks, not reliability or
full-suite certification. Neither fetched the calendar-coverage record; both
had positive conflict evidence and made no free/busy assurance. The first did
not mention prior reschedules or suggest a next step, so richer decision support
remains unproven. The edge/all fallback reads graph-wide relationship metadata;
it is not a scalable filtered-neighborhood query. Native scoped-query efficiency
and empty-result case/alias handling remain separate follow-ups. Keep this
prompt/model constant when comparing providers.

Four prompt-builder and seven fixture unit tests passed. Production agent config,
voice, greeting, tool attachments and phone routing were preserved. Local changes
remain uncommitted until the operator commits them.

## Recovery

To stop this test, detach this MCP ID from Eleven.a. Leave the synthetic graph
intact. Do not repoint its credential to a real graph, add live booking tools,
or restore GitHub to run the fixture tests. No change to original Eleven is
needed. The native endpoint can remain isolated for the Graphiti comparison.

Private operator snapshots are in the mode-restricted directory referenced by
`/tmp/eleven-a-state.json`. They include before/after agent configs, host template,
gateway source, and proof files. They are not a durable memory backup and must
not be committed. Runtime credentials are durably held in Azure/ElevenLabs secrets.
