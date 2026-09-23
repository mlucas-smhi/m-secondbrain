"""Synthetic localhost-only probe: seed, replace LiteGraph container, verify.

The separate PostgreSQL container/database must survive the replacement.
No production credentials or personal data are accepted by this probe.
"""
import argparse
import asyncio
import uuid
from urllib.parse import urlsplit

from memory_facade.app import Settings, LiteGraphHttpError, litegraph_request
from memory_facade.graph_memory import GraphMemory, data
from test_graph_memory import bundle


async def probe(endpoint, mode):
    if urlsplit(endpoint).hostname not in ("127.0.0.1", "localhost"):
        raise RuntimeError("probe_requires_localhost")
    settings = Settings(endpoint, "synthetic-local-test-only",
        str(uuid.uuid5(uuid.NAMESPACE_URL, "local-graph-durability-tenant")),
        str(uuid.uuid5(uuid.NAMESPACE_URL, "local-graph-durability-graph")), timeout_seconds=20,
        graph_memory_enabled=True, workspace_id="synthetic-workspace", owner_ref="user:synthetic-owner")
    graph = GraphMemory(settings, litegraph_request)
    if mode == "seed":
        for path, collection, payload in [
            (f"/v1.0/tenants/{settings.tenant_guid}", "/v1.0/tenants", {"GUID": settings.tenant_guid, "Name": "durability-probe", "Active": True}),
            (graph.base, f"/v1.0/tenants/{settings.tenant_guid}/graphs", {"GUID": settings.graph_guid, "Name": "durability-probe",
                "Data": {"memory_schema_version": "entity-memory.v1", "workspace_id": settings.workspace_id, "owner_ref": settings.owner_ref}}),
        ]:
            try:
                await litegraph_request(settings, "HEAD", path)
            except LiteGraphHttpError as error:
                if error.status != 404 and not (path == graph.base and error.status == 400):
                    raise
                await litegraph_request(settings, "PUT", collection, json_body=payload)
        result = await graph.store(bundle())
        print("Synthetic bundle committed; replace only the LiteGraph container, then verify.")
    else:
        receipt_id = graph.stable_id("receipt", "utterance-1", "capture-1")
        receipt = await graph.read(receipt_id)
        if not receipt:
            raise RuntimeError("durability_probe_receipt_missing")
        result = data(receipt)["result"]
    context = await graph.context(result["entities"]["andrew"]["id"])
    assert len(context["facts"]) == 3
    assert len(context["relationships"]) == 8
    assert any(data(n)["value"] == "vegetarian" for n in context["facts"])
    print(f"{mode}: same receipt, entity IDs, three facts, and eight edges verified")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["seed", "verify"])
    parser.add_argument("endpoint")
    args = parser.parse_args()
    asyncio.run(probe(args.endpoint, args.mode))
