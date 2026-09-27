# 11 private native memory activation — 2026-09-25

## Live wiring

Recognized-owner private calls use 11's existing agent and the real GitHub-seeded
LiteGraph scope from [PHASE1-BASELINE.md](PHASE1-BASELINE.md). Guests and conference
agent legs use a separate memory-free agent. No caller startup code is enabled.

- Bridge revision: `eleven-voice-bridge-poc--private-0925-e1eac9c414`.
- Memory revision: `litegraph-memory-poc--private-native-0925`.
- Private agent: `agent_01jyhnqm7efv1vn2dhh2n20h2z`.
- Branch: `agtbrch_9101ks1979h2eqssvfbavc3aja61`.
- Agent version after cutover: `agtvrsn_4101m3d2kzgte6gvgx1ca4r0yp96`.
- Guest/conference agent: `agent_9501m3d24x63e9abzbzkg5a0v4ad`.
- Private MCP server: `7PKnZqpJA4AQ5ZR0RTlk`.
- Native endpoint: `/eleven-private-mcp` on the existing memory app.
- Eight automatically approved tools: `node/search`, `node/all`, `node/get`, `node/create`,
  `node/update`, `edge/all`, `edge/create`, `graph/query`. No per-call human
  approval ceremony for those tools; administrative tools remain unapproved.

This is native LiteGraph MCP, not the memory facade. A dedicated MCP sidecar
uses the restricted real-graph credential. The gateway authenticates a separate
edge bearer; neither credential is stored in Git. Existing `/mcp` synthetic and
facade routes remain intact. 2's app configuration is unchanged.

## Caller boundary

`PRIVATE_MEMORY_ROUTING=recognized_owner`, `OWNER_CODE_MODE=disabled`, and
`ELEVENLABS_GUEST_AGENT_ID` configure selection. `session_routes.py` binds the
signed Twilio webhook's Call SID, caller number and role to an opaque, expiring,
single-use server claim. Media-stream metadata cannot promote a guest or
conference leg. The account SID and duplicate active call are also checked.
Claims are process-local: one worker, one replica; restart fails closed.

Caller ID is deliberately low-assurance Phase 1 recognition, not authenticated
identity or voiceprint verification. The private agent's credential can access
the entire owner graph. Fine-grained disclosure and stronger step-up are not
implemented by this split.

Both agents require authenticated connections; prompt overrides are disabled.
The guest has no external tools, MCP servers, private knowledge base, or transfer
workflow. It retains only conversation system tools. Its prompt does not carry
M's profile. Joined sessions start separately rather than inheriting private
conversation history. Administrator/API-key access remains privileged.

The Twilio number retains its bridge inbound webhook. Its legacy fallback
directly to ElevenLabs was cleared because it bypassed bridge agent selection.
Do not restore that fallback while private memory is attached.

## Instructions and preserved behavior

The private agent replaces stale GitHub and synthetic-memory instructions with
`eleven-private-memory.md`, populated with the real scope IDs. It requests
targeted name search, relevant entity retrieval, sourced quiet saves,
full-node preservation, relationship edges, correction history and readback.
It does not pretend a failed write is durably queued.

The existing first-message template, TTS configuration, call-joining rules,
workflow, call tools and other MCP integrations were preserved. The guest uses
the same voice and generic opening. Conference introduction polish remains
deferred; this rollout does not redesign greetings or joining.

## Verification and acceptance

- Voice-bridge unit suite: 114 tests passed, including seven route tests.
- Private native MCP enumerated the 47 baseline/receipt nodes and read a known
  Andrew fact. Requests into 2 and synthetic scopes were denied.
- Native create/update/get succeeded for one temporary synthetic probe. That
  exact probe was checked and removed afterward; baseline records were retained.
- ElevenLabs discovered the seven approved private tools.
- Signed synthetic Twilio websocket sessions reached the expected agents for
  owner, guest, and conference roles, confirmed in provider conversation records.
  Forged owner/role stream parameters did not change guest/conference routing.
- Post-cutover checks cover anonymous agent denial, unsigned webhook denial,
  bridge health, unchanged 2 configuration, and the old synthetic MCP route.

Still to test with M: natural recall, an unsolicited durable fact save, recall on
a fresh call, and live guest/joined-call privacy. Automated transport probes do
not prove conversational behavior or guarantee every save succeeds. Concurrent
full-node updates across separate owner calls also need caution; model-side
instructions are not a transactional conflict-resolution mechanism.

## Recovery

### Plain-language save workflow and entity guide — 2026-09-26

The minimal prompt did not reliably trigger writes. Explicit `node/create`
requests succeeded, and a real travel-memory request subsequently created
`Tentative Travel Plans June` (`eb573193-c433-48f1-bc09-954157a1ab0b`) in 0.722s,
but did not populate its details. 11 claimed the countries were saved although
no update was invoked. This established that naming a record was being treated
as completing the save. No trip backfill or test-node cleanup was performed.

At M's direction, added a plain-language save workflow: search, retrieve existing
content or create a name, update substantive details, connect established
relationships, then verify persistence. Added conceptual memory parts and
examples for people, meetings, events, projects, trips, decisions and tasks.
Examples are explicitly nonfactual illustrations, not seed data. Unknown fields
remain unspecified. Task references require real, persistent Turn Engine IDs;
graph notes cannot pretend to create operational tasks or update live status.
No intricate JSON packaging recipe was reinstated.

Live version: `agtvrsn_7901m3f1ah12etdtzak660vqtkr6`. Verified only the saving
section of the prompt changed; model, voice, intro, targeted lookup, tools,
workflow, platform settings and routing remain unchanged. Five prompt regression
tests passed. Actual update arguments and persisted details still need a fresh
conversation test; deployment is not evidence of successful conversational saves.
Private before/after snapshots are under the machine's temporary directory,
`eleven-save-guide-20260926-rtvx_9cx`; do not commit those snapshots.

### Minimal save-instruction experiment — 2026-09-26

Both the Asia-tour phone conversation and an explicit Thailand-in-June chat
request produced verbal save claims without any write-tool invocation. The
private graph still contained 47 nodes and no matching trip facts at audit.

At M's direction, removed the step-by-step write/JSON packaging procedure,
leaving a short rule to use memory tools, preserve existing memories, and claim
success only when the information was actually stored. Secrecy, honest failure
handling, and no fictional durable retry queue remain explicit. Removed the
recall paragraph's dangling reference to the old write procedure; targeted
search behavior otherwise remains unchanged.

Live agent version: `agtvrsn_3201m3ey17edfz0t1ka6k2681mpn`. Prompt length decreased
from 12,420 to 9,968 characters. Full configuration readback confirmed that only
prompt text changed: tools/approvals, model, voice, opening, workflow and platform
settings were not modified. No bridge deployment, data backfill, or new middleware.
Three prompt regression tests passed.

This is an experiment, not a proven save fix. Repeat the explicit Thailand
request in a fresh chat; inspect tool invocation first, then arguments, result,
and persisted graph content. Existing low-level write schemas are still sparse;
removing the recipe may reveal argument/schema failures rather than fix them.
Private before/after snapshots are in the machine's temporary directory under
`eleven-save-prompt-20260926-_pwbdec5`; they must not be committed.

### Targeted-search follow-up

After the first real call stalled without issuing a write, the mandatory startup
directory sweep was removed. `node/search` is now automatically approved. The
prompt requests a scoped Name search with MaxResults=5 and no Data/subordinates,
then fetches only the resolved entity. Explicit inventory questions still use
paginated enumeration. Name substrings can match multiple people: Andrew also
matches Pharr Andrews, so conversational disambiguation remains necessary.

Read-only production checks returned two candidates in 924 response characters
for Andrew (0.671s), and one in 517 characters for Andrew Everett (0.274s).
Searches against 2's and the synthetic scope were denied. Only the memory prompt
and private MCP search approval changed; voice, intro, workflow, other tools,
platform settings and routing were preserved. Version after this follow-up:
`agtvrsn_1301m3d5dq44e1t9jwxanf8ksbcd`.

Three prompt regression tests cover bounded scoped search, no startup sweep,
and preservation of full-node write safeguards. This does not solve full-record
rewrite overhead or prove conversational save latency; a fresh call is needed.
Checkpoint files use the `targeted-search-` prefix in the private activation
checkpoint directory.

### Rollback order

Private checkpoint: `/tmp/eleven-private-connect-20260925-state.json` points to
mode-0600 before/after configurations and proof records. It is not the durable
memory store. Do not publish those files; they include secret-bearing snapshots.

If rolling back, first detach the private MCP and restore the synthetic-scoped
agent configuration while retaining authenticated access. Only then consider
restoring the earlier bridge routing. Never restore an all-callers-to-one-agent
bridge while that agent still has real private memory. Preserve the seeded
graph, 2, and synthetic comparison data; no reset is required.
