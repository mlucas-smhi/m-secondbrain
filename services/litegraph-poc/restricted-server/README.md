# Schema-only PostgreSQL runtime

This image builds upstream LiteGraph 9.0 from pinned commit
`e1b32136603e158d6f5b0031413eac1ef1ed30f9` with a single startup change:
both synchronous and asynchronous repository initialization **check** that
the configured PostgreSQL schema exists rather than trying to create it.
Missing schemas fail startup. Administrators provision the schema separately.

The runtime role needs CONNECT to the database and USAGE/CREATE in its own
schema, plus ownership of the tables it creates. It does not need database
CREATE, CREATEDB, CREATEROLE, SUPERUSER, BYPASSRLS, or another application's
table privileges. Table initialization/upgrades are unchanged and still run
within the configured schema. No security-definer function is installed.

This is a pinned 9.0 source build, not a claim that its entire binary is identical
to a published v9.0.0 image. The PostgreSQL schema-creation behavior is unchanged
from 8.1 upstream; upgrading alone does not remove the need for this patch.
Test transactions, the PostgreSQL driver, backup/migration,
and container replacement before deployment; pin the deployed image digest.

Build context is this directory. The upstream archive has a pinned SHA-256;
`git apply --check` fails if the patch no longer matches. Build-service/runtime
base images remain the .NET 10 channel; deployment is pinned by resulting image
digest. Keep this patch under review when deliberately upgrading upstream.

## Supabase TLS

`supabase-prod-ca.crt` is a **public CA certificate**, not a private key or
credential. The download URL is published in Supabase's official dashboard
configuration at `apps/studio/hooks/custom-content/custom-content.json`:
https://supabase-downloads.s3-ap-southeast-1.amazonaws.com/prod/ssl/prod-ca-2021.crt

File SHA-256: `700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7`.
Certificate SHA-256 fingerprint:
`80:70:25:AD:50:D4:ED:21:9D:2C:9C:7D:29:9C:00:4F:82:4E:B0:0C:F7:F6:5A:FE:F6:07:D0:7B:72:E6:CA:FA`.
Expires 2031-04-26. Revalidate deliberately when Supabase rotates its CA.

The container stores it at `/app/certs/supabase-prod-ca.crt`; the PostgreSQL
connection uses `SSL Mode=VerifyFull;Root Certificate=/app/certs/supabase-prod-ca.crt`.
It does not disable hostname checks or install a machine-wide trust exception.

## Verification and target preparation

- `test_durability.py`: disposable local PostgreSQL and LiteGraph containers;
  tests schema-only access, missing-schema startup rejection, all facade tests,
  then graph recall after replacing the LiteGraph container. Requires Docker
  and the facade's Python dependencies. Cleans up only its own test resources.
- `provision_target.py --apply`: explicitly targeted to the approved Supabase
  project/Azure app. Creates the restricted login/schema, checks verified TLS
  and effective privileges, and adds an **unused** connection secret. It does
  not change the running image/environment, migrate memory, or reset onboarding.
  Requires `psycopg[binary]`, authenticated CLIs, and this repository's linked
  Supabase project. Refuses existing targets; `--resume-disabled-target` is only
  for an empty target whose login was disabled after an incomplete attempt.
  `--resume-stored-target` reconciles an already-stored Azure secret after a
  delayed read-back, and also requires an empty target and disabled login.
  Neither recovery option is a credential-rotation path for a deployed service.
- `verify_hosted.py`: uses that secret to run localhost-only LiteGraph against
  the unused hosted target. Saves a synthetic graph, replaces the local server,
  and verifies the original receipt/IDs/facts/edges. Leaves its single synthetic
  tenant/graph for repeatability; no personal memories are copied or changed.

These tests do not establish Azure revision replacement or live-call behavior.
Build/test the deployment architecture and pin its digest before the cutover.
