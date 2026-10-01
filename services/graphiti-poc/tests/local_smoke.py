"""Opt-in Docker smoke: native MCP + auth + DB persistence, no real API key.

Uses an internal Docker network (no model API egress), in-container HTTP requests,
and uniquely named disposable containers/volume. Removes only its own resources.
This does NOT prove LLM extraction or real cloud deployment.
"""
import json
import os
import secrets
import subprocess
import time
import uuid


def main():
    prefix = "graphiti-smoke-" + uuid.uuid4().hex[:12]
    db, mcp, gateway, volume = (prefix + suffix for suffix in ("-db", "-mcp", "-gateway", "-data"))
    containers = []
    db_password, edge_token = secrets.token_hex(32), secrets.token_hex(32)
    env = {**os.environ, "REDISCLI_AUTH": db_password, "MCP_EDGE_TOKEN": edge_token,
           "FALKORDB_PASSWORD": db_password}

    def docker(*args, check=True):
        result = subprocess.run(["docker", *args], capture_output=True, text=True, env=env)
        if check and result.returncode:
            # Do not dump command arguments (may contain disposable credentials).
            raise RuntimeError(result.stderr[-2000:])
        return result.stdout.strip()

    def wait_for(check, seconds=120):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                if check():
                    return
            except (OSError, RuntimeError, ValueError):
                pass
            time.sleep(1)
        raise RuntimeError("Readiness deadline exceeded")

    db_image = os.environ["FALKORDB_IMAGE"]
    if not db_image.startswith("falkordb/falkordb-server@sha256:"):
        raise ValueError("Use an immutable official DB image digest")
    network_created = volume_created = False
    try:
        docker("network", "create", "--internal", prefix)
        network_created = True
        docker("volume", "create", volume)
        volume_created = True
        containers.append(db)
        docker("run", "-d", "--name", db, "--network", prefix,
               "--entrypoint", "redis-server", "-v", volume + ":/var/lib/falkordb/data",
               db_image, "--loadmodule", "/var/lib/falkordb/bin/falkordb.so",
               "--dir", "/var/lib/falkordb/data", "--appendonly", "yes",
               "--maxmemory-policy", "noeviction", "--requirepass", db_password)

        def redis(*args):
            return docker("exec", "-e", "REDISCLI_AUTH", db, "redis-cli", "--raw", *args)

        wait_for(lambda: redis("ping") == "PONG")
        assert "NOAUTH" in docker("exec", db, "redis-cli", "ping")
        redis("GRAPH.QUERY", "smoke", "CREATE (:Probe {value:'persistent-canary'})")
        redis("SAVE")
        docker("restart", db)
        wait_for(lambda: redis("ping") == "PONG")
        assert "persistent-canary" in redis("GRAPH.QUERY", "smoke", "MATCH (n:Probe) RETURN n.value")
        print("PASS: DB authentication and graph readback after DB restart", flush=True)

        containers.append(mcp)
        docker("run", "-d", "--name", mcp, "--network", prefix,
               "-e", "FALKORDB_URI=redis://" + db + ":6379",
               "-e", "FALKORDB_PASSWORD", "-e", "OPENAI_API_KEY=not-a-real-key",
               "-e", "MODEL_NAME=smoke-no-api-calls", "-e", "GRAPHITI_GROUP_ID=smoke",
               "graphiti-cookoff-local:3c427640")
        containers.append(gateway)
        docker("run", "-d", "--name", gateway, "--network", "container:" + mcp,
               "-e", "MCP_EDGE_TOKEN", "graphiti-cookoff-gateway-local:20261001")
        # Docker internal networks deliberately have no published host port.
        # Execute the probe in the same namespace as the app/gateway.
        transport = '''
import json, sys, urllib.request, urllib.error
spec = json.loads(sys.argv[1])
request = urllib.request.Request('http://127.0.0.1:8080' + spec['path'],
    json.dumps(spec['payload']).encode() if 'payload' in spec else None,
    spec.get('headers', {}))
try:
    response = urllib.request.urlopen(request, timeout=10)
except urllib.error.HTTPError as error:
    response = error
with response:
    print(json.dumps({'status': response.status, 'headers': dict(response.headers),
                      'body': response.read().decode()}))
'''
        def http(spec):
            return json.loads(docker("exec", mcp, "python", "-c", transport, json.dumps(spec)))

        wait_for(lambda: http({"path": "/health"})["status"] == 200)

        session = None
        def request(method, params=None, identifier=1, auth=True):
            nonlocal session
            payload = {"jsonrpc": "2.0", "method": method}
            if identifier is not None:
                payload["id"] = identifier
            if params is not None:
                payload["params"] = params
            headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
            if auth:
                headers["Authorization"] = "Bearer " + edge_token
            if session:
                headers["Mcp-Session-Id"] = session
            response = http({"path": "/mcp", "payload": payload, "headers": headers})
            if not auth:
                return response
            assert response["status"] in (200, 202), response
            response_headers = {key.lower(): value for key, value in response["headers"].items()}
            session = response_headers.get("mcp-session-id", session)
            body = response["body"]
            if not body:
                return {}
            if body.startswith("event:") or body.startswith("data:"):
                events = [json.loads(line[5:].strip()) for line in body.splitlines() if line.startswith("data:")]
                return next(event for event in events if event.get("id") == identifier)
            return json.loads(body)

        assert request("initialize", auth=False)["status"] == 401
        init = request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                       "clientInfo": {"name": "isolated-smoke", "version": "1"}})
        assert "result" in init, init
        request("notifications/initialized", identifier=None)
        tools = request("tools/list", {}, identifier=2)
        names = {tool["name"] for tool in tools["result"]["tools"]}
        assert {"add_memory", "search_nodes", "search_memory_facts", "get_status"} <= names
        status = request("tools/call", {"name": "get_status", "arguments": {}}, identifier=3)
        assert not status.get("error"), status
        assert not status["result"].get("isError"), status
        contents = [json.loads(block["text"]) for block in status["result"].get("content", []) if block.get("type") == "text"]
        assert any(item.get("status") == "ok" for item in contents), status
        print("PASS: unauthenticated MCP denied; native initialize/tools/list/get_status", flush=True)
        print("No extraction tested and no model API calls authorized (network has no external route).", flush=True)
    except Exception:
        for name in containers:
            logs = docker("logs", "--tail", "25", name, check=False)
            print(logs.replace(db_password, "[redacted]").replace(edge_token, "[redacted]"))
        raise
    finally:
        for name in reversed(containers):
            docker("rm", "-f", name, check=False)
        if volume_created:
            docker("volume", "rm", volume, check=False)
        if network_created:
            docker("network", "rm", prefix, check=False)
        print("Removed only this smoke test's containers, network and synthetic scratch volume.", flush=True)


if __name__ == "__main__":
    main()
