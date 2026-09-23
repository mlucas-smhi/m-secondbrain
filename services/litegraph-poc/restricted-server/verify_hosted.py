"""Validate the UNUSED hosted target with localhost-only synthetic LiteGraph.

Creates one deterministic synthetic tenant/graph in the isolated target schema.
Preserves it for a repeatable restart check; never accesses the legacy graph.
No live Container App settings are changed.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

from provision_target import command, private_file, URL, VERSION, SECRET, HOST, ROLE, PROJECT

SERVICES = Path(__file__).resolve().parents[2]
FACADE = SERVICES / "litegraph-memory-facade"
IMAGE = "litegraph-two:9.0-existing-schema"


def main():
    stored = command("az", "rest", "--method", "post", "--url", URL + "/listSecrets?api-version=" + VERSION)
    connection = next(item["value"] for item in stored["value"] if item["name"] == SECRET)
    assert connection.startswith(f"Host={HOST};Port=5432;Database=postgres;Username={ROLE}.{PROJECT};")
    assert "SSL Mode=VerifyFull" in connection
    containers = []

    def docker(*args):
        result = subprocess.run(["docker", *args], text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError("Docker command failed; diagnostic output withheld")
        return result.stdout.strip()

    with tempfile.TemporaryDirectory(prefix="two-hosted-validation-") as directory:
        env_file = private_file(directory, "database.env", "\n".join([
            "LITEGRAPH_DB_TYPE=Postgresql", f"LITEGRAPH_DB_SCHEMA={ROLE}",
            "LITEGRAPH_DB_MAX_CONNECTIONS=4", "LITEGRAPH_DB_CONNECTION_STRING=" + connection,
        ]) + "\n")
        try:
            def server():
                cid = docker("run", "-d", "--ulimit", "core=0", "-p", "127.0.0.1::8701",
                    "--mount", f"type=bind,source={FACADE / 'tests/litegraph.synthetic.json'},target=/app/litegraph.json,readonly",
                    "--env-file", env_file, IMAGE)
                containers.append(cid)
                binding = json.loads(docker("inspect", "--format", "{{json .NetworkSettings.Ports}}", cid))
                endpoint = "http://127.0.0.1:" + binding["8701/tcp"][0]["HostPort"]
                for _ in range(60):
                    try:
                        with urllib.request.urlopen(endpoint, timeout=2) as response:
                            if response.status == 200:
                                return cid, endpoint
                    except (urllib.error.URLError, TimeoutError, ConnectionError):
                        pass
                    time.sleep(1)
                raise RuntimeError("Hosted-target LiteGraph startup failed")

            def probe(mode, endpoint):
                env = {**os.environ, "PYTHONPATH": str(FACADE) + os.pathsep + str(FACADE / "tests")}
                result = subprocess.run([sys.executable, str(FACADE / "tests/durability_probe.py"), mode, endpoint],
                                        env=env, text=True, capture_output=True)
                if result.returncode:
                    raise RuntimeError("Hosted synthetic graph probe failed; output withheld")
                print(result.stdout, flush=True)

            first, endpoint = server()
            probe("seed", endpoint)
            docker("rm", "-f", "-v", first)
            containers.remove(first)
            _, endpoint = server()
            probe("verify", endpoint)
            print("PASS: pinned LiteGraph 9, restricted hosted role, verified TLS, and replacement recall", flush=True)
        finally:
            for cid in reversed(containers):
                docker("rm", "-f", "-v", cid)
            print("Removed local validation containers; hosted synthetic graph preserved", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit(f"Hosted validation stopped: {type(error).__name__}. Live service unchanged.")
