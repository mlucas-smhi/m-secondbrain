# 11 — Phase 1 GitHub baseline migration

## Deployment result — 2026-09-25

**Imported and verified; not yet attached to the live agent.**

- Azure app: `litegraph-memory-poc`; existing PostgreSQL-backed LiteGraph v9.
- Tenant: `9a1b6836-2cbb-41f5-9d8a-1d2e96540318`
- Graph: `df5fedac-4567-4c09-86fe-fbba399161d1`
- Workspace: `7e0c009d-1aa9-4068-8eb8-5854fe6d4f04`
- Owner: `user:9068ffd8-bfb6-43f8-8405-f24269383503`
- Non-admin user: `b69084a6-698a-48dd-bec9-44b38421b380`
- Read/write credential ID: `74bb51b2-79af-4562-995b-58e640439464`;
  graph allowlist contains only the graph above. No bearer token in Git.
- Receipt: `6ed1a5e3-da17-5364-a3ce-6f4961d1cabb`
- Import digest: `b090b18092076845758c5543462af77e91166db0663d5527ddd9886550f1dffc`
- 20 source files -> 46 entities, 139 sourced fact/section records, 46 edges.
  Physical graph: 47 nodes including the import receipt, plus 46 edges.

The restricted credential performed the atomic import. Every persisted node's
data/name/scope and every relationship's data/endpoints matched the reviewed
plan on readback. Repeating the import returned `already_imported` with the
same receipt and no writes. Fifteen local mapping/import tests pass.

Six negative checks returned HTTP 401: private credential read/write against
2's scope; private credential read/write against the synthetic graph; synthetic
credential read against this private graph; private credential listing tenants.
Write probes used empty transactions, not real cross-tenant mutations. These
prove those credential boundaries, not full caller authorization or 12's future
agent isolation. No 12 agent/scope was created in this step.

11's conversation configuration and both Azure app configurations were compared
to pre-import snapshots and unchanged. GitHub and the existing graphs were not
reset. The live native MCP still uses the synthetic graph credential.

Private operational checkpoint: `/tmp/eleven-baseline-import-20260925-state.json`
points to mode-0600 snapshots/results. These are local recovery artifacts, not
the durable memory store; the graph and its receipt are already in LiteGraph.
The checkpoint helper `/tmp/eleven-baseline-import.py` delivered code over exec
stdin to avoid Azure's long-command websocket URL limit. Long-term maintenance
uses the repository mapping/import modules below, not those temporary files.

## Current decision — 2026-09-25

Recognize M's configured calling number for ordinary low-risk conversation.
No code/keypad ceremony just to start a call. Caller ID is low-assurance
recognition, not strong identity proof. Sensitive requests will later need
proportionate step-up checks. The earlier `OWNER_CODE_MODE=sms` experiment was
rejected before deployment; keep it disabled.

## Boundaries

- Import 11's knowledge into a distinct workspace, tenant, and graph.
- Preserve GitHub, 2's memories, and the synthetic native comparison graph.
- 12 starts empty in its own scope when the user creates that agent. Never
  inherit M's memories or personalization. Reusing a test phone number must
  not collapse workspace identity.
- Unknown callers and joined/conference sessions must not inherit M's memory
  credentials or private history. Enforce this through routing, not solely a
  prompt. Graph credentials isolate tenants, not callers sharing a credential.
- Keep the working intro and joining behavior. No startup code gate.
- Consequential external actions still need explicit authorization.

## Import implementation

`bridge/memory_seed.py` inventories allowlisted committed sources.
`bridge/memory_baseline.py` contains a reviewed mapping pinned to commit
`5849d29e38af4514d2b3b489076639db82dd594b`.
`bridge/memory_import.py` performs atomic create-only import and full readback.

Native entities contain inline sourced fact records, with explicit relationship
edges. Schema: `eleven-native-memory.v1`, **not** 2's facade schema. Native MCP
does not need a facade or extraction-model call. A later facade comparison
would need an explicit adapter, not an assumption of schema compatibility.

Every fact/relationship retains the Git path, immutable revision, blob/hash,
and exact evidence excerpt. Source-recorded dates are not effective dates;
unknown effective dates stay unknown. Section hierarchy is retained so a
destination's duration is not mistaken for the duration of the whole trip.
Historical architecture decisions are context, not runtime instructions.

Twenty substantive files are represented. The `test`-only event, authoring
instructions, placeholders, example people, unresolved bare project links,
secrets, `_system` instructions, and uncommitted changes are not imported as
facts. The import does not invent facts absent from GitHub, such as Pharr's
diet, or infer parentage from the children's surname.

An empty graph and matching scope metadata are required. Records and receipt
commit together. A rerun checks that receipt and never overwrites subsequent
conversation saves. Do not reset any other graph to make an import fit.

```sh
PYTHONPATH=services/voice-bridge python3 -m bridge.memory_seed --repo . --ref origin/main
PYTHONPATH=services/voice-bridge python3 -m unittest discover -s services/voice-bridge/tests -p 'test_memory*.py' -v
```

## Activation after import

1. Verify persisted entities, evidence, edges and the import receipt.
2. Verify restricted credentials cannot cross into 2's or synthetic memory.
3. Route recognized-owner private sessions separately from guest/conference
   sessions, without a startup challenge. Audit preview/share/transfer paths.
   Importing the data does not change 11's live MCP connection.
4. Replace synthetic-test and GitHub-memory retrieval instructions with scoped
   real-memory instructions, preserving personality and call controls.
5. Test recall, silent save, fresh-call recall, then guest/joined-call privacy.

Silent-save fallback/retry, dynamic standing instructions, step-up verification,
and 12's actual tenant test remain separate work. Do not claim these behaviors
are delivered merely because the baseline is imported.
