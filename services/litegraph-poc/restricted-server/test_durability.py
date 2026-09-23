"""Disposable Docker test, synthetic data only; requires facade requirements.

Run with a local Docker daemon and the patched image built first. All resources
have unique names; cleanup removes only container/network IDs created here.
No production connection strings, settings, or credentials are accepted.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parents[2]
FACADE = ROOT / "litegraph-memory-facade"
IMAGE = "litegraph-two:9.0-existing-schema"
POSTGRES = "public.ecr.aws/supabase/postgres:17.6.1.166"


def run(*args, input=None, check=True, env=None):
    result = subprocess.run(args, input=input, text=True, capture_output=True, env=env)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr or result.stdout}")
    return result


def main():
    containers = []
    network = None
    prefix = "two-v9-test-" + uuid.uuid4().hex[:10]
    try:
        # PostgreSQL has no published port; only the API is bound to localhost.
        # Docker Desktop does not publish ports on an --internal-only network.
        network = run("docker", "network", "create", prefix).stdout.strip()

        def start(*args):
            cid = run("docker", "run", "-d", "--ulimit", "core=0", "--network", network, *args).stdout.strip()
            containers.append(cid)
            return cid

        pg = start("--name", prefix + "-pg", "--network-alias", "database",
                   "-e", "POSTGRES_PASSWORD=synthetic-local-only", "-e", "PGDATA=/tmp/test-pg",
                   POSTGRES, "postgres", "-D", "/tmp/test-pg", "-c", "listen_addresses=*")

        def sql(statement, username="postgres", check=True):
            return run("docker", "exec", "-i", pg, "psql", "-X", "-v", "ON_ERROR_STOP=1",
                       "-U", username, "-d", "postgres", "-At", input=statement, check=check)

        for _ in range(90):
            # Entrypoint's temporary initialization server accepts Unix-socket
            # SQL before the actual network listener starts. Wait for TCP.
            if run("docker", "exec", pg, "pg_isready", "-h", "127.0.0.1", "-U", "postgres", check=False).returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError("PostgreSQL did not become ready")

        sql("""
CREATE ROLE graph_runtime LOGIN PASSWORD 'synthetic-local-only'
 NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
REVOKE CREATE ON DATABASE postgres FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA graph_test AUTHORIZATION postgres;
GRANT CONNECT ON DATABASE postgres TO graph_runtime;
GRANT USAGE, CREATE ON SCHEMA graph_test TO graph_runtime;
CREATE SCHEMA unrelated;
CREATE TABLE unrelated.private_records (value text);
INSERT INTO unrelated.private_records VALUES ('synthetic-private');
""")
        privileges = sql("""SELECT has_database_privilege(current_user, current_database(), 'CREATE'),
has_schema_privilege(current_user, 'graph_test', 'USAGE,CREATE'),
has_schema_privilege(current_user, 'public', 'CREATE'),
rolsuper, rolcreatedb, rolcreaterole, rolbypassrls
FROM pg_roles WHERE rolname=current_user;""", "graph_runtime").stdout.strip()
        assert privileges == "f|t|f|f|f|f|f", privileges
        for forbidden in ("CREATE SCHEMA not_allowed;", "SELECT * FROM unrelated.private_records;",
                          "CREATE TABLE public.not_allowed (id int);"):
            assert sql(forbidden, "graph_runtime", check=False).returncode != 0
        print("Restricted role: no database CREATE, no public writes, no unrelated-table access", flush=True)

        def server(schema):
            return start("-p", "127.0.0.1::8701", "--mount",
                         f"type=bind,source={FACADE / 'tests/litegraph.synthetic.json'},target=/app/litegraph.json,readonly",
                         "-e", "LITEGRAPH_DB_TYPE=Postgresql", "-e", f"LITEGRAPH_DB_SCHEMA={schema}",
                         "-e", "LITEGRAPH_DB_MAX_CONNECTIONS=4", "-e",
                         "LITEGRAPH_DB_CONNECTION_STRING=Host=database;Port=5432;Database=postgres;Username=graph_runtime;Password=synthetic-local-only;SSL Mode=Disable",
                         IMAGE)

        missing = server("missing_schema")
        for _ in range(45):
            log_result = run("docker", "logs", missing)
            logs = log_result.stdout + log_result.stderr
            if "must be provisioned by an administrator" in logs:
                break
            time.sleep(1)
        assert "must be provisioned by an administrator" in logs, logs[-1500:]
        binding = json.loads(run("docker", "inspect", "--format", "{{json .NetworkSettings.Ports}}", missing).stdout)
        if binding.get("8701/tcp"):
            try:
                urllib.request.urlopen("http://127.0.0.1:" + binding["8701/tcp"][0]["HostPort"], timeout=2)
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                pass
            else:
                raise AssertionError("Missing-schema instance must not serve requests")
        assert sql("SELECT count(*) FROM pg_namespace WHERE nspname='missing_schema';").stdout.strip() == "0"
        run("docker", "rm", "-f", "-v", missing)
        containers.remove(missing)
        print("Missing schema: explicit failure without creating it", flush=True)

        def ready(cid):
            binding = json.loads(run("docker", "inspect", "--format", "{{json .NetworkSettings.Ports}}", cid).stdout)
            endpoint = "http://127.0.0.1:" + binding["8701/tcp"][0]["HostPort"]
            for _ in range(60):
                try:
                    with urllib.request.urlopen(endpoint, timeout=2) as response:
                        if response.status == 200:
                            return endpoint
                except (urllib.error.URLError, TimeoutError, ConnectionError):
                    pass
                time.sleep(1)
            raise RuntimeError("LiteGraph did not become ready: " + run("docker", "logs", cid).stdout[-2000:])

        env = {**os.environ, "PYTHONPATH": str(FACADE) + os.pathsep + str(FACADE / "tests")}
        first = server("graph_test")
        endpoint = ready(first)
        tests = run(sys.executable, "-m", "unittest", "discover", "-s", str(FACADE / "tests"),
                    env={**env, "LITEGRAPH_TEST_ENDPOINT": endpoint})
        print(tests.stdout + tests.stderr, flush=True)
        print(run(sys.executable, str(FACADE / "tests/durability_probe.py"), "seed", endpoint, env=env).stdout, flush=True)
        run("docker", "rm", "-f", "-v", first)
        containers.remove(first)
        replacement = server("graph_test")
        print(run(sys.executable, str(FACADE / "tests/durability_probe.py"), "verify", ready(replacement), env=env).stdout, flush=True)
        assert sql("SELECT has_database_privilege('graph_runtime', 'postgres', 'CREATE');").stdout.strip() == "f"
        print("PASS: restricted-role v9 startup, transactions, replacement, and durable recall", flush=True)
    finally:
        for cid in reversed(containers):
            run("docker", "rm", "-f", "-v", cid, check=False)
        if network:
            run("docker", "network", "rm", network, check=False)
        print("Removed this run's disposable synthetic containers/network", flush=True)


if __name__ == "__main__":
    main()
