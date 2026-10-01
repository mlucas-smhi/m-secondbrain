# Isolated Graphiti cook-off

Status: isolated Azure infrastructure and custom ontology deployed. Single-canary
entity recall passes; the baseline multi-relationship test was partial, but the
same paragraph with native extraction guidance recovered diet, hobby and
anniversary details alongside family and employer links. One guided case passes;
this is not yet a reliability result. Guidance is passed by the test caller,
not globally enabled. See the [ontology rollout](ONTOLOGY-ROLLOUT-2026-10-01.md).
The full scenario comparison remains unverified. See also the
[rollout receipt](AZURE-ROLLOUT-2026-10-01.md). This directory does not change
production 11, Eleven.a, LiteGraph, 2, phone routing, or real memories. Live-agent
activation and the scenario cook-off remain separate steps.

Validation on 2026-10-01:

- Six offline fixture tests passed; shell syntax and Git whitespace checks passed.
- All three Bicep templates compile with Bicep 0.47.16. Azure infrastructure,
  VM bootstrap, private database connectivity and MCP deployment succeeded.
- Both container targets built locally on ARM64 and in ACR for `linux/amd64`.
  Azure runs the digest-pinned AMD64 images.
- Local internal-network smoke passed: DB authentication, graph readback after DB
  restart, HTTP 401 without MCP credentials, native MCP initialize/tool listing,
  and successful native `get_status` database query. Test resources were removed.
- Cloud checks passed: HTTPS health, unauthorized MCP denial, native tool
  discovery and database status. A synthetic database record survived a database
  container restart and an RDB restore into a separate unnetworked container.
  The restore checkpoint is on the same VM disk, not an independent backup.
- Provider-backed extraction and live-agent activation are tracked separately
  in the rollout receipt. A healthy HTTP endpoint does not prove either works.

The custom executive-assistant [entity/relationship definitions](ONTOLOGY.md)
are deployed to the isolated app: 21 entity types and 31 relationships, with
optional structured attributes and explicit source/target mappings. Eighteen
offline tests and a network-disabled native-loader smoke pass. Live extraction
results and the new image digest are recorded in the rollout receipt.

To repeat the opt-in smoke after building both local image tags used by the test:

```sh
FALKORDB_IMAGE=falkordb/falkordb-server@sha256:54b896e034d29b49a46fb3d0d7cb7a659ee2989d32def2d7e3efa2a7c7c8b793 \
  python3 services/graphiti-poc/tests/local_smoke.py
```

That digest reported FalkorDB 4.22.0 and Redis 8.10.2. The test uses only synthetic
scratch data and an internal Docker network with no model API egress.

## Topology

ElevenLabs chat -> authenticated HTTPS gateway -> **native Graphiti MCP** in a
dedicated Azure Container App -> FalkorDB on a dedicated CPU-only Azure VM.

The gateway only authenticates and forwards HTTP; it does not rewrite tools,
normalize entities, or perform memory operations. Graphiti extraction, search,
tool schemas, and the episode queue remain upstream behavior.
The pinned runtime's canonical endpoint is `/mcp` (without a trailing slash).
Its documentation says `/mcp/`, but that path returns HTTP 307 in the local smoke
test; avoid depending on clients replaying authenticated POSTs across redirects.

The existing `cae-eleven-gptlive-poc` environment has no VNet configuration
(checked 2026-10-01). A new environment uses its own unpeered VNet; no existing
app is moved. Database ingress is allowed only from that environment's subnet.
The VM has a public IP for explicit outbound package/image downloads, but no
public inbound allowance, including SSH. Administration uses Azure managed Run
Command with RBAC. Redis binds through Docker only to the VM's private address.

Deployed isolated resource group: `rg-graphiti-cookoff-poc`, South Central US.
VM: Standard_B2ms, 32 GiB managed data disk. These are POC starting sizes,
not measured capacity requirements. VM, disks, public IP, logs, Container Apps,
and extraction/embedding/reranking API usage incur charges. Never delete existing apps
or change subscription-wide policies as part of this deployment.

## Reproducibility

The Dockerfile pins upstream MCP source to
`3c427640abf909f12f71f963fce15eb514a3c493` and installs its frozen dependency lock
(graphiti-core 0.30.2). It does not use upstream's combined DB/MCP image or
regenerate dependency versions. Python/Caddy bases are digest-pinned; deploy
resulting images by digest too. Build targets are `graphiti` and `gateway`.
Python is explicitly 3.12: upstream's `.python-version` otherwise selects a
downloaded runtime under root's home that the non-root service cannot access.

Extraction model is a required deployment parameter; record it explicitly along
with the embedding model and upstream reranker default. Do not assume selecting
the extraction model also selects the reranker. No API calls or real memory
ingestion should happen during image builds. Telemetry is disabled.

## Deployment order

1. Confirm separate infrastructure and cost scope; check subscription, quota,
   address ranges, image digests, and the approved extraction model.
2. Build/scan both targets and push only those images to the existing ACR.
   Create a dedicated managed identity with AcrPull scoped to that registry.
3. Validate and review `infra.bicep`; deploy it to the **new** resource group.
   It creates networking, a CPU VM, managed data disk, logs, and ACA environment.
4. Generate a fresh 64-character random hex DB password and independent edge
   token. Keep them in secret storage/0600 temporary parameter files outside Git;
   never put them in command arguments, chat, screenshots, or build layers.
5. Deploy `database.bicep` using secure parameters and a digest-pinned
   `falkordb/falkordb-server` image. The bootstrap accepts only the dedicated LUN0
   disk, refuses unknown filesystem signatures, and refuses replacing an existing
   container. Explicitly select the Redis entrypoint; upstream run.sh ignores
   ordinary positional config arguments. Do not rerun this as a database update.
6. Verify authenticated DB access and unauthenticated denial. Confirm AOF/RDB
   files land on the managed disk, not container-local storage. Snapshot and
   restore a synthetic record before calling persistence verified.
7. Deploy `app.bicep` with secure parameters and image digests. It runs one
   always-on replica. Only the gateway port is externally exposed.
8. Verify HTTPS 401 without credentials, MCP initialization/tool listing with
   credentials, and `get_status` DB connectivity. `/health` is process liveness,
   **not** proof of a healthy database or completed write.
9. Ingest a single synthetic canary, verify extraction and fact retrieval, restart
   the app, then verify retrieval again before seeding the scenario suite.
10. Seed only the primary synthetic fixture and wait for each episode's extraction
    completion/readback. Connect a separate test agent only after these gates.

No unattended deploy script is included yet. Keep infrastructure provisioning,
secret injection, seeding, and agent activation as separate reviewable steps.

## Important native limitations

- `add_memory` returns queue acceptance, **not completed persistence**. Upstream
  `QueueService` uses process-local `asyncio.Queue` and logs processing failures.
  Accepted/pending jobs can be lost on process restart; minReplicas=1 does not
  make that queue durable. Drain/verify before deploys. Do not promise saves on
  acceptance or retry unknown outcomes blindly.
- Group IDs are namespaces, not tenant authorization. The native credential can
  reach other groups and administrative tools. This entire instance must contain
  only disposable synthetic test data; don't import real/foreign tenant data.
- Expose only the intended search/read/add tools to the test agent. Keep delete,
  clear_graph, community rebuild, and other admin tools unavailable to it. That
  tool selection is not a replacement for server-side authorization in production.
- The POC private Redis link is password-authenticated but not TLS-encrypted.
  That and off-VM backup automation need separate hardening before sensitive data.
- A managed disk survives container replacement; it is **not** an independent
  backup. AOF everysec also has a potential recent-write loss window.
- The native MCP server is experimental. Production durability, tool scoping,
  authorization, bounded retries, rate limits, and recovery need another pass.

## Fair comparison

`fixture_episodes.py` converts only
`../voice-bridge/fixtures/memory-scenarios-v1.json` primary records into native
`add_memory` inputs. Original facts, structured fields, relationships, stable
task/thread references, explicit offsets, and the synthetic clock are retained.
Evaluator documents and answer keys are never ingestion sources. The fixture is
a snapshot as of its clock, not a reconstructed historical event stream.

```sh
python3 -m unittest discover -s services/graphiti-poc/tests -v
python3 services/graphiti-poc/fixture_episodes.py
```

The manifest is offline only; printing it does not ingest anything. Content-based
episode names aid reconciliation but do not make native writes idempotent.
New writes omit `uuid`: this upstream version uses a supplied UUID to retrieve an
existing episode, not to assign a new ID. Record the generated ID after completion.
Changed facts receive a new name; reconcile before replaying a partial import.

Use the same test questions, synthetic clock, agent model/reasoning setting, and
behavioral goals. Adapt only backend-specific tool instructions. Start from the
same baseline on both sides (the old LiteGraph test includes later Morgan edits).
Measure ingestion completion separately from tool acknowledgement and retrieval;
report extraction, embedding and reranking costs as well as conversational costs.
Score retrieval, ambiguity, constraints, time arithmetic, cross-chat recall,
provenance, failed writes and recovery separately. A graph upgrade cannot by
itself establish sound time arithmetic or task execution authority.

## Sources checked

- [Graphiti native MCP source](https://github.com/getzep/graphiti/tree/3c427640abf909f12f71f963fce15eb514a3c493/mcp_server)
- [ACA custom networking](https://learn.microsoft.com/en-us/azure/container-apps/custom-virtual-networks)
- [Managed Run Command protected parameters](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/run-command-managed)
