# Durable memory migration

Status: migration not yet applied. The running POC remains SQLite-backed.

## 2026-09-22 hosted target verified — not yet serving live memory

- Built LiteGraph 9 from pinned upstream revision
  `e1b32136603e158d6f5b0031413eac1ef1ed30f9` with the narrow existing-schema
  startup patch in `restricted-server/`. Missing schemas reject initialization;
  no database-wide CREATE privilege is needed.
- All 43 facade tests passed against the patched server and disposable
  PostgreSQL. Tested rollback, retry, restricted permissions, missing-schema
  rejection, and recall after replacing the LiteGraph container.
- Provisioned `litegraph_two_poc` in the approved Supabase project
  `apozwrkkomowdaocwfmm`: postgres-owned schema and separate runtime login with
  USAGE/CREATE only in that schema. No superuser, CREATEDB, CREATEROLE,
  BYPASSRLS, role memberships, or database CREATE. Runtime connection limit 8;
  application pool maximum 4.
- Connected through the session pooler on port 5432 with certificate **and
  hostname** verification. Supabase's public CA is bundled in the image and
  referenced explicitly; the system CA bundle alone did not trust this pooler.
  No TLS checks were disabled. See the restricted-server README for source,
  fingerprint, expiry, and renewal instructions.
- Effective-role tests found no other writable application schema, no accessible
  application tables outside the target, and no executable security-definer
  functions in accessible non-system schemas. A transactional write/read probe
  passed and was rolled back.
- Added `litegraph-postgres` as an **unused** Azure Container Apps secret. The
  live `litegraph-memory-poc` image/environment stayed unchanged on revision
  `litegraph-memory-poc--0000006`. Provisioning recovery briefly disabled only
  the new login; after verification it is enabled with the stored credential.
- Ran the actual patched LiteGraph/Npgsql server locally against the hosted
  target. It saved a synthetic graph; a replacement server then verified the
  original receipt, entity IDs, three facts, and eight edges. This test's local
  containers were removed. Its deterministic synthetic tenant/graph remains in
  the otherwise unused target for repeatability; it is not 2's personal graph.

**Still required before live use:** build and test the Azure deployment
architecture (these Docker tests used the Mac's local architecture), publish a
digest-pinned image, refresh/protect the old memory snapshot, deliberately
migrate/preserve legacy memory and provision the new graph's trusted metadata,
deploy the facade and matching voice tool instructions, and verify Azure
revision replacement plus a real two-call save/recall test. No personal-memory
reset, onboarding reset, invitation reset, or live graph-writer switch occurred.

Scripts: `restricted-server/test_durability.py`, `provision_target.py`, and
`verify_hosted.py`. The latter two are explicitly scoped to this approved POC;
review their target constants before reuse. Do not rerun provisioning against
the now-initialized target. It intentionally refuses nonempty/existing targets.

## Earlier 2026-09-22 implementation checkpoint (before provisioning)

The user selected the existing Supabase PostgreSQL project, with an isolated
schema and restricted login. No production schema, role, secret, or deployment
has been changed during the graph-writer implementation.

Read-only preflight found no existing `litegraph_two_poc` role/schema and no
PUBLIC grants on application tables. The extensions schema has PUBLIC SELECT
on `pg_stat_statements` and `pg_stat_statements_info`; these are not application
table grants and still require review of effective schema permissions and
metadata exposure before claiming isolation. The only PUBLIC-executable function
found in the public schema was the non-security-definer `update_updated_at`.
Recheck all effective privileges under the actual new role before rollout.

**Original compatibility blocker (now resolved in the custom image):** the deployed LiteGraph v8.1.0 image executes
`CREATE SCHEMA IF NOT EXISTS` during repository initialization, even when its
schema is already provisioned and owned by the runtime role. A local test against
Supabase PostgreSQL 17.6 confirmed startup fails without CREATE on the database.
Granting database CREATE in the disposable test database allowed initialization
and graph transaction/rollback/recall tests to pass.

Local verification completed against `jchristn77/litegraph:v8.1.0` (local image
ID `sha256:19606e1531962118ce5ffda0753da850faf3af90ded30ba3be703b9829e9cea5`)
and `public.ecr.aws/supabase/postgres:17.6.1.166`:

- 43 facade tests passed, including three real LiteGraph SQLite tests.
- The three real transaction/rollback/recall tests also passed on PostgreSQL.
- A replacement LiteGraph container read the original PostgreSQL-backed
  receipt, entity IDs, three sourced facts, and eight edges without reseeding.
- 35 existing voice-service tests passed; no voice-service code was changed
  as part of this graph-writer slice.

These are disposable local tests with synthetic records, not a verification of
Supabase's hosted pooler/TLS, Azure revision replacement, or live onboarding.

Do not add that broader privilege to the live Supabase login. The chosen fix is
the narrowly patched v9 image above. The alternatives originally evaluated were:

- a narrowly patched, pinned LiteGraph image that checks for an existing schema
  before attempting schema creation (preferred for schema-only runtime access); or
- explicit approval for database CREATE, which permits creating additional
  schemas, but is not CREATEDB and does not itself grant access to other tables.

A one-time CREATE grant followed by revocation is not a solution: unpatched
LiteGraph attempts the same statement on subsequent starts. Retest container
replacement with the final runtime role, TLS, provider settings, and image.

The local graph writer is opt-in and remains disabled in the live facade.
It includes the registry, atomic entity/fact/edge writes, save receipts, and
graph-aware recall. Automatic source capture/refinement and live migration
remain pending; passing graph tests is not proof of complete onboarding capture.

## Protected source snapshot — 2026-09-22

- Created with the running LiteGraph instance's authenticated backup API.
- Durable Azure Files account/share: `stlitegraphmbrain/litegraph`.
- Backup path: `backups/pre-durable-20260922.db`.
- SHA-256: `94e5602a360aa2baeaced1065f1732ade2f9c36e93dc74c0007973b3f3ad2932`.
- Local downloaded copy passed `PRAGMA integrity_check` (`ok`).
- Snapshot contains 13 nodes and one graph.
- This snapshot contains private memory and database credentials. Keep it
  access-controlled; never commit, attach, or expose it through MCP.

## Target requirements

LiteGraph supports PostgreSQL. Choose either an isolated schema/login in the
existing Supabase PostgreSQL service (subject to compatibility/isolation tests),
or a separate managed PostgreSQL database with its own recurring cost.

Do not place SQLite or PostgreSQL data files on the existing SMB share.
Azure Files remains suitable for configuration and secured backup artifacts.

Use a dedicated non-superuser login with access only to the LiteGraph schema.
Do not grant it Supabase `service_role`, `authenticated`, or public application
table privileges. Check inherited PUBLIC permissions as well as explicit grants.
Do not expose the LiteGraph schema through Supabase's Data API.

Use TLS certificate verification and a small connection pool. For an IPv4
Supabase session pooler, verify the dashboard host and use port 5432 and the
custom-role.project-ref username. Store the connection string in an Azure
Container Apps secret, never a repository file or CLI output.

The target LiteGraph container needs these settings (validate against the
actual image before rollout):

```
LITEGRAPH_DB_TYPE=Postgresql
LITEGRAPH_DB_SCHEMA=litegraph_two_poc
LITEGRAPH_DB_CONNECTION_STRING=secretref:litegraph-postgres
LITEGRAPH_DB_MAX_CONNECTIONS=4
```

`secretref:` above is Azure's environment-setting syntax, not a literal
connection string. Set the server's default-record seeding off. Keep tenant,
graph, admin token, and gateway token stable until the deliberate POC reset.

## Migration and reset gates

1. Check that no test calls/writes are active; refresh the source snapshot if
   new memories arrived after the protected snapshot.
2. Validate the target role, TLS connectivity, schema isolation, and supported
   database provider before replacing the source container.
3. Test write/read and replica replacement with synthetic data in an isolated
   graph. Verify the same stored ID/content after replacement.
4. Preserve the old memory snapshot; switch only the authorized 2 POC to an
   empty graph for the user-requested clean onboarding. Do not restore old
   personal facts into the clean graph or seed known people.
5. Export the exact POC's Supabase identity/onboarding state before resetting
   it. Never reset other workspaces or revive a consumed invitation.
6. Issue the fresh invite near test time so it does not expire during migration.
7. Follow `FRESH_ONBOARDING_TEST.md`, including checkpoint persistence and
   independent stored-record verification.

The legacy `deploy.sh` now refuses to update an existing app. It is not the
durable migration path. A health response alone does not prove durable storage.

Sources: LiteGraph upstream `docs/STORAGE.md` and Supabase database connection
documentation. The inspected upstream source did not offer a `v8.1.0` Git tag;
the deployed image's PostgreSQL behavior still requires a live compatibility
test, not an assumed match to upstream main.
