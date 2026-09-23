"""Provision only the isolated hosted target; never migrate/restart the live app.

Requires authenticated Supabase/Azure CLIs and psycopg[binary]. Secrets travel
through restricted temporary files, never command arguments or normal output.
Existing roles, schemas, or target secrets are refused, not overwritten.
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import secrets
import subprocess
import tempfile
import traceback
import time

import psycopg

PROJECT = "apozwrkkomowdaocwfmm"
ROLE = "litegraph_two_poc"
HOST = "aws-0-us-east-1.pooler.supabase.com"
RESOURCE = ("/subscriptions/afb3e822-70d2-46e2-82f2-a5aed33e3324"
            "/resourceGroups/rg-eleven-gptlive-poc/providers/Microsoft.App"
            "/containerApps/litegraph-memory-poc")
URL = "https://management.azure.com" + RESOURCE
VERSION = "2025-01-01"
SECRET = "litegraph-postgres"
REPO = Path(__file__).resolve().parents[3]
CA_FILE = Path(__file__).resolve().with_name("supabase-prod-ca.crt")


def command(*args):
    if args[0] == "az" and "--output" not in args:
        args = (*args, "--output", "json")
    result = subprocess.run(args, cwd=REPO, capture_output=True, text=True)
    if result.returncode:
        # CLI errors can echo SQL/request bodies containing secrets.
        raise RuntimeError(f"{args[0]} operation failed (output withheld to protect secrets)")
    return json.loads(result.stdout) if result.stdout.strip() else None


def private_file(directory, name, contents):
    path = Path(directory) / name
    with open(path, "x", opener=lambda p, flags: os.open(p, flags, 0o600)) as stream:
        stream.write(contents)
    return str(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", required=True)
    recovery = parser.add_mutually_exclusive_group()
    recovery.add_argument("--resume-disabled-target", action="store_true",
                        help="Retry ONLY an empty target whose runtime login was disabled after a failed provision")
    recovery.add_argument("--resume-stored-target", action="store_true",
                         help="Reconcile a delayed Azure secret update for the empty, disabled target")
    args = parser.parse_args()
    if hashlib.sha256(CA_FILE.read_bytes()).hexdigest() != "700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7":
        raise RuntimeError("Supabase CA differs from the reviewed official download")
    if (REPO / "supabase/.temp/project-ref").read_text().strip() != PROJECT:
        raise RuntimeError("Linked Supabase project does not match approved target")
    with tempfile.TemporaryDirectory(prefix="two-storage-provision-") as directory:
        def query(sql):
            path = private_file(directory, secrets.token_hex(8) + ".sql", sql)
            return command("supabase", "db", "query", "--linked", "--file", path)

        existing = command("az", "rest", "--method", "post", "--url",
                           URL + "/listSecrets?api-version=" + VERSION)
        items = existing["value"]
        stored_connection = next((item.get("value") for item in items if item["name"] == SECRET), None)
        if stored_connection and not args.resume_stored_target:
            raise RuntimeError("Target secret already exists; inspect rather than overwrite")
        password = secrets.token_hex(32)
        if args.resume_stored_target:
            if not stored_connection or not stored_connection.startswith(f"Host={HOST};Port=5432;Database=postgres;Username={ROLE}.{PROJECT};"):
                raise RuntimeError("Stored target connection does not match the approved restricted role")
            match = re.search(r";Password=([a-f0-9]{64});", stored_connection)
            if not match:
                raise RuntimeError("Stored target credential has an unexpected format")
            password = match.group(1)
        created = False
        secret_stored = False
        try:
            role_statement = f"""CREATE ROLE {ROLE} LOGIN PASSWORD '{password}' NOSUPERUSER NOCREATEDB
 NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 8;
CREATE SCHEMA {ROLE} AUTHORIZATION postgres;"""
            if args.resume_disabled_target or args.resume_stored_target:
                role_statement = f"""DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='{ROLE}' AND NOT rolcanlogin
  AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolbypassrls) THEN
  RAISE EXCEPTION 'Target is not the disabled restricted role';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname='{ROLE}' AND nspowner='postgres'::regrole)
  OR EXISTS (SELECT 1 FROM pg_class WHERE relnamespace=(SELECT oid FROM pg_namespace WHERE nspname='{ROLE}')) THEN
  RAISE EXCEPTION 'Target schema must exist, be postgres-owned, and be empty';
 END IF;
END $$;
ALTER ROLE {ROLE} LOGIN PASSWORD '{password}';"""
            query(f"""BEGIN;
{role_statement}
REVOKE ALL ON SCHEMA {ROLE} FROM PUBLIC, anon, authenticated, service_role;
GRANT CONNECT ON DATABASE postgres TO {ROLE};
GRANT USAGE, CREATE ON SCHEMA {ROLE} TO {ROLE};
ALTER ROLE {ROLE} SET search_path = {ROLE}, pg_catalog;
DO $$ BEGIN
 IF has_database_privilege('{ROLE}', 'postgres', 'CREATE') THEN
  RAISE EXCEPTION 'Unexpected database CREATE privilege';
 END IF;
 IF EXISTS (SELECT 1 FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname='{ROLE}')) THEN
  RAISE EXCEPTION 'Unexpected role membership';
 END IF;
END $$;
COMMIT;""")
            created = True
            with psycopg.connect(host=HOST, port=5432, dbname="postgres", user=ROLE + "." + PROJECT,
                                 password=password, sslmode="verify-full", sslrootcert=str(CA_FILE),
                                 connect_timeout=15) as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT current_user, has_database_privilege(current_user, current_database(), 'CREATE')")
                    assert cur.fetchone() == (ROLE, False)
                    cur.execute("""SELECT n.nspname FROM pg_namespace n WHERE n.nspname <> %s
                        AND n.nspname NOT LIKE 'pg_%%' AND n.nspname <> 'information_schema'
                        AND has_schema_privilege(current_user, n.oid, 'CREATE')""", (ROLE,))
                    assert not cur.fetchall(), "Unexpected schema write access"
                    cur.execute("""SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                        WHERE c.relkind IN ('r','p','v','m','f') AND n.nspname <> %s
                        AND n.nspname NOT LIKE 'pg_%%' AND n.nspname <> 'information_schema'
                        AND has_schema_privilege(current_user, n.oid, 'USAGE')
                        AND has_table_privilege(current_user,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')""", (ROLE,))
                    assert not cur.fetchall(), "Unexpected application-table access"
                    cur.execute("""SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                        WHERE p.prosecdef AND n.nspname NOT LIKE 'pg_%%' AND n.nspname <> 'information_schema'
                        AND has_schema_privilege(current_user,n.oid,'USAGE')
                        AND has_function_privilege(current_user,p.oid,'EXECUTE')""")
                    assert not cur.fetchall(), "Unexpected privileged function access"
                    cur.execute(f"CREATE TABLE {ROLE}.durability_permission_probe (value text)")
                    cur.execute(f"INSERT INTO {ROLE}.durability_permission_probe VALUES ('synthetic')")
                    cur.execute(f"SELECT value FROM {ROLE}.durability_permission_probe")
                    assert cur.fetchone() == ("synthetic",)
                    conn.rollback()  # No probe table remains.
                    cur.execute(f"ALTER DEFAULT PRIVILEGES IN SCHEMA {ROLE} REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC")
                conn.commit()
            print("Hosted TLS identity, restricted-role privileges, and transactional write/read verified", flush=True)

            connection = (f"Host={HOST};Port=5432;Database=postgres;Username={ROLE}.{PROJECT};"
                          f"Password={password};SSL Mode=VerifyFull;Root Certificate=/app/certs/supabase-prod-ca.crt;Maximum Pool Size=4;Timeout=15")
            if args.resume_stored_target:
                assert stored_connection == connection, "Stored target connection differs from verified settings"
                secret_stored = True
                print("Existing Azure secret reconciled and restricted login re-enabled; no live cutover", flush=True)
                return
            # Refresh immediately before patching to preserve all existing secrets.
            items = command("az", "rest", "--method", "post", "--url",
                            URL + "/listSecrets?api-version=" + VERSION)["value"]
            if any(item["name"] == SECRET for item in items):
                raise RuntimeError("Target secret appeared during provisioning; refusing overwrite")
            # listSecrets may include read-only identity metadata; keep only supported fields.
            keep = [{k: v for k, v in item.items() if k in ("name", "value", "keyVaultUrl", "identity")}
                    for item in items]
            keep.append({"name": SECRET, "value": connection})
            body = private_file(directory, "azure-secret.json", json.dumps({"properties": {"configuration": {"secrets": keep}}}))
            command("az", "rest", "--method", "patch", "--url", URL + "?api-version=" + VERSION,
                    "--body", "@" + body, "--output", "none")
            deadline = time.monotonic() + 120
            while True:
                readback = command("az", "rest", "--method", "post", "--url", URL + "/listSecrets?api-version=" + VERSION)["value"]
                observed = next((item.get("value") for item in readback if item["name"] == SECRET), None)
                if observed == connection:
                    break
                if observed is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Azure secret read-back did not match; inspect before retrying")
                time.sleep(2)
            secret_stored = True
            print("Restricted connection stored as Azure secret; no runtime environment or image changed", flush=True)
        except BaseException:
            if created and not secret_stored:
                # Leave the empty schema for inspection, never drop shared objects.
                query(f"ALTER ROLE {ROLE} NOLOGIN;")
                print("Provisioning incomplete: new runtime login disabled; schema preserved", flush=True)
            raise


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # psycopg/HTTP failures may include connection details; do not print them.
        frame = traceback.extract_tb(error.__traceback__)[-1]
        for cause in ("certificate verify failed", "password authentication failed", "Tenant or user not found",
                      "timeout expired", "Connection refused", "could not translate host name", "permission denied"):
            if cause.lower() in str(error).lower():
                print("Connection diagnostic category: " + cause)
        raise SystemExit(f"Target provisioning stopped: {type(error).__name__} at {Path(frame.filename).name}:{frame.lineno}. No live cutover attempted.")
