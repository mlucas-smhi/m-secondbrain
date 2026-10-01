# Graphiti isolated Azure rollout — 2026-10-01

## Outcome

Infrastructure is live. Billing recovered on retry; provider-backed entity
extraction and entity recall now pass for the single synthetic canary. Relationship
extraction and the full scenario suite are not validated. The initial attempt
returned HTTP 429, `insufficient_quota`, `credit_balance_exhausted`; retain that
failure history below rather than interpreting queue acceptance as success.
No agent has been switched.
Production 11, Eleven.a, 2, LiteGraph and phone routing remain unchanged.

The user explicitly authorized reusing 2's POC OpenAI credential for this
isolated Graphiti service. Its source configuration was not changed. Values
were transferred privately into Azure Container App secrets, never into Git,
build layers, terminal output or this receipt. Sharing the key also shares its
provider budget and limits; it does not provide independent billing isolation.

## Deployed resources

- Subscription: `afb3e822-70d2-46e2-82f2-a5aed33e3324`.
- Resource group: `rg-graphiti-cookoff-poc`, South Central US.
- App/environment: `graphiti-cookoff-mcp` / `graphiti-cookoff-env`.
- Native MCP: `https://graphiti-cookoff-mcp.gentlebay-b36ad7b1.southcentralus.azurecontainerapps.io/mcp`.
- VNet: `graphiti-cookoff-vnet`, unpeered `10.42.0.0/16`.
- VM: `graphiti-cookoff-db`, Standard_B2ms, private `10.42.4.4`.
- Disk: `graphiti-cookoff-data`, 32 GiB Standard SSD, mounted `/srv/graphiti`.
- DB ingress: TCP 6379 only from the dedicated ACA subnet `10.42.0.0/23`.
  No public SSH/inbound allowance. Public IP is for outbound access.
- Registry: existing `ca773a2b28d9acr.azurecr.io`; new identity
  `graphiti-cookoff-pull` has AcrPull scoped to that registry.
- App: single revision, one always-on replica; MCP 1 CPU/2 GiB plus authentication
  gateway 0.25 CPU/0.5 GiB. These resources are billable while running.

The Caddy gateway authenticates requests without translating MCP tools or
payloads. The native upstream server performs extraction and retrieval.

## Version and model record

- Upstream revision: `3c427640abf909f12f71f963fce15eb514a3c493`.
- Frozen dependency lock: graphiti-core 0.30.2, MCP server 2.2.0, Python 3.12.
- MCP AMD64 image:
  `ca773a2b28d9acr.azurecr.io/graphiti-cookoff/mcp@sha256:2e962dc58cf30d5012b6cd57b1ddd64acf4ca7b64901296ba4ef26eee0e50edf`.
- Gateway AMD64 image:
  `ca773a2b28d9acr.azurecr.io/graphiti-cookoff/gateway@sha256:ae7f9d4a114635fd44e4de9e21603a75fd50f86a953cb685e7abc2bad7a715bd`.
- DB image:
  `falkordb/falkordb-server@sha256:54b896e034d29b49a46fb3d0d7cb7a659ee2989d32def2d7e3efa2a7c7c8b793`.
  Runtime reported FalkorDB 4.22.0 / Redis 8.10.2.
- Configured extraction: `gpt-4.1-2025-04-14`.
- Embedding: `text-embedding-3-small`; upstream reranker default: `gpt-4.1-nano`.
  Cloud embedding requests and canary extraction succeeded after billing recovery.
  Local metadata checks timed out. Separate reranker inference is not verified.

## Evidence

Passed:

- Six offline fixture-conversion tests, shell syntax, Git whitespace checks.
- Three Bicep templates compiled with Bicep 0.47.16.
- ACR AMD64 builds; infrastructure, database bootstrap and app deployments.
- HTTPS health, HTTP 401 for unauthorized MCP, native initialize and discovery
  of 13 tools. Authenticated `get_status` reached the private database in 0.079s
  on the post-restart check.
- Synthetic storage record survived DB container restart on the managed disk.
- RDB checkpoint restored and queried inside a second unnetworked container.
  Managed Run Command `verify-persistence` exited 0. Checkpoint SHA-256:
  `1365a36726c0c32a115cef9a76ce57f02c2bea4f534c34ad4929fb205ea28c42`.
  This is a same-VM restore test, **not** an off-VM backup or VM-loss test.

Initial failure / remaining checks:

- One fictional canary was queued in `graphiti_azure_canary_v1` in 0.073s.
  Episode UUID: `e5f21969-9925-5c34-9311-c8d1e57dc33b`.
  Subject: Cedar Quinn; facts: vegan, enjoys weekend hiking.
  Native fact search returned the provider credit error; provenance returned
  zero nodes and zero edges. Queue acceptance is not a completed save.
- No full scenario fixture ingestion, agent connection or comparative scoring.
- Image vulnerability scan not completed: Docker Scout required a Docker ID
  login. Do not treat successful builds as a security scan.
- No independent backup schedule, Redis TLS, durable ingestion queue or
  production tenant authorization. This remains synthetic-only infrastructure,
  not a SOC 2 compliance claim.

One immediate readiness call during the secret-loading restart returned an
upstream database `NoneType` error; a fresh session after startup passed. Do not
treat `/health` alone as database readiness.

## Billing-recovery retry

- Embeddings returned HTTP 200, confirming that the quota blocker cleared.
- A long-lived native query client still returned `NoneType` errors; direct
  database and fresh-driver queries succeeded. Restarting only the isolated app
  cleared the failure. Root cause is not established; this is an open reliability
  observation, not a claim of a permanent fix.
- Retry 1 (`b812aa10-9903-527c-945d-dd0dfdbfd19d`) failed in the background with
  `node ... not found`. The test harness incorrectly supplied a new `uuid`;
  pinned core `add_episode` interprets it as an existing episode to retrieve.
  Corrected the canary and fixture converter to omit UUID on new writes and use
  content-based names for reconciliation. No upstream runtime code was changed.
- Corrected episode `azure-canary-retry2` was accepted in 0.069s. Extracted entity
  provenance was observed 10.5s after submission (an observation bound, not a
  precise extraction duration).
- Generated episode UUID: `6f9109b0-fbbc-4f75-885e-f9c274495c07`.
- Generated Person UUID: `99808afb-1d5a-4103-96c0-4e1db0e5b2a4`.
- Native `search_nodes` returned Cedar Quinn's vegan preference and weekend-hiking
  hobby in 0.459s. They are in the entity summary/description, **not fact edges**:
  provenance had zero edges and `search_memory_facts` returned no facts in 0.963s.
  Do not count this as a relationship-extraction pass or promise a fact-only tool
  can retrieve every saved preference.
- After a completed-save app restart, a fresh MCP session retrieved the same
  Person UUID and both preferences in 0.508s. App-restart entity recall passed.
- Six fixture tests still pass, including omission of new-write UUIDs and
  deterministic reconciliation names. No full-suite ingestion or agent switch.

## Resume safely

1. Confirm billing remains available and native database readiness passes.
2. Reconcile the canary before retrying: inspect `get_episodes` and
   `get_episode_entities` in `graphiti_azure_canary_v1`, using the generated
   episode UUID above. Failed preassigned UUIDs are not successful records.
   The native queue does not promise automatic retries or idempotent replay.
3. If processing failed, use a distinct, explicitly recorded retry episode name
   and omit UUID for creation; do not blindly repeat an unknown write. Verify
   extracted facts and provenance.
4. After completed writes, restart only the isolated app and verify retrieval
   from a new MCP session.
5. Ingest the synthetic baseline serially with completion checks, then connect
   an isolated test agent. Do not move production 11 or overwrite Eleven.a's
   LiteGraph configuration as part of this recovery.

Keep secrets in Azure or protected local parameter files. Do not commit generated
parameters. Secret changes require a replica restart to load updated environment
values; drain and reconcile the process-local ingestion queue first.
