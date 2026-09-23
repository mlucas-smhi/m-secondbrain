"""Opt-in tests against a real LOCAL disposable LiteGraph; never production."""
import asyncio
import os
import unittest
import uuid
from urllib.parse import urlsplit

from memory_facade.app import Settings, litegraph_request
from memory_facade.graph_memory import GraphMemory, data
from test_graph_memory import bundle


@unittest.skipUnless(os.getenv("LITEGRAPH_TEST_ENDPOINT"), "requires disposable local LiteGraph")
class RealGraphTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        endpoint = os.environ["LITEGRAPH_TEST_ENDPOINT"]
        if urlsplit(endpoint).hostname not in ("127.0.0.1", "localhost"):
            raise RuntimeError("integration_tests_require_localhost")
        self.settings = Settings(endpoint, "synthetic-local-test-only", str(uuid.uuid4()), str(uuid.uuid4()),
                                 timeout_seconds=20, graph_memory_enabled=True,
                                 workspace_id="synthetic-workspace", owner_ref="user:synthetic-owner")
        await litegraph_request(self.settings, "PUT", "/v1.0/tenants", json_body={"GUID": self.settings.tenant_guid, "Name": "synthetic-entity-test", "Active": True})
        await litegraph_request(self.settings, "PUT", f"/v1.0/tenants/{self.settings.tenant_guid}/graphs",
                                json_body={"GUID": self.settings.graph_guid, "Name": "synthetic-graph",
                                    "Data": {"memory_schema_version": "entity-memory.v1", "workspace_id": self.settings.workspace_id, "owner_ref": self.settings.owner_ref}})
        self.graph = GraphMemory(self.settings, litegraph_request)

    async def test_store_retry_and_recall_from_fresh_facade(self):
        saved = await self.graph.store(bundle())
        self.assertEqual(saved["status"], "saved")
        self.assertTrue((await self.graph.store(bundle()))["duplicate"])
        fresh_facade = GraphMemory(self.settings, litegraph_request)
        context = await fresh_facade.context(saved["entities"]["andrew"]["id"])
        self.assertEqual(len(context["facts"]), 3)
        self.assertEqual(len(context["relationships"]), 8)
        self.assertEqual({data(n)["canonical_name"] for n in context["related_entities"]}, {"Utah", "Skiing"})

    async def test_concurrent_identical_requests_have_one_receipt(self):
        results = await asyncio.gather(self.graph.store(bundle()), self.graph.store(bundle()), return_exceptions=True)
        # Serialization conflicts may require a client retry, never duplicate writes.
        saved = await self.graph.store(bundle())
        self.assertEqual(saved["status"], "saved")
        nodes = await self.graph.list_records("nodes")
        self.assertEqual(len(nodes), 7)
        self.assertTrue(any(isinstance(r, dict) for r in results))

    async def test_atomic_rollback_on_duplicate_node(self):
        first = await self.graph.store(bundle())
        probe_id = str(uuid.uuid4())
        operations = [
            {"OperationType": "Create", "ObjectType": "Node", "Payload": self.graph.node(probe_id, "Entity", "Must Roll Back", {"family": "person"})},
            {"OperationType": "Create", "ObjectType": "Node", "Payload": self.graph.node(first["receipt_id"], "Entity", "Duplicate", {})},
        ]
        try:
            response = await litegraph_request(self.settings, "POST", self.graph.base + "/transaction",
                json_body={"Operations": operations, "IsolationLevel": "Serializable"})
            self.assertFalse(response.get("Success"))
        except Exception as error:
            self.assertEqual(getattr(error, "status", None), 409)
        self.assertIsNone(await self.graph.read(probe_id))


if __name__ == "__main__":
    unittest.main()
