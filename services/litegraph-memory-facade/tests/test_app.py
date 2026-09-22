import unittest
import uuid
from unittest.mock import AsyncMock, patch

from memory_facade.app import (
    LiteGraphHttpError,
    READY_SCOPES,
    Settings,
    build_memory_node,
    ensure_memory_scope,
    rank_nodes,
    store_memory,
    tool_catalog,
)


class FacadeTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        READY_SCOPES.clear()

    def test_exposes_scoped_realtime_safe_tools(self):
        tools = tool_catalog()
        self.assertEqual(
            [tool["name"] for tool in tools],
            ["memory_search", "memory_get", "memory_store"],
        )
        self.assertTrue(tools[0]["annotations"]["readOnlyHint"])
        self.assertTrue(tools[1]["annotations"]["readOnlyHint"])
        self.assertFalse(tools[2]["annotations"]["readOnlyHint"])
        self.assertFalse(tools[2]["annotations"]["destructiveHint"])
        self.assertTrue(all("/" not in tool["name"] for tool in tools))

    def test_ranks_matching_memory(self):
        nodes = [
            {"GUID": "one", "Name": "other", "Data": {"content": "prefers aisle"}},
            {
                "GUID": "two",
                "Name": "synthetic-owner-flight-preference",
                "Data": {"content": "prefers window seats on morning flights"},
            },
        ]
        matches = rank_nodes(nodes, "owner morning flight seat preference", 5)
        self.assertEqual(matches[0]["GUID"], "two")

    def test_builds_level_three_provenanced_memory_by_default(self):
        settings = Settings(
            "http://litegraph", "key", str(uuid.UUID(int=1)), str(uuid.UUID(int=2))
        )
        node = build_memory_node(
            settings,
            {
                "memory_type": "communication_preference",
                "subject": "owner",
                "content": "Prefers SMS for brief asynchronous updates.",
                "confidence": 1,
                "source_session_ref": "rtc_test",
                "source_thread_ref": "thread_test",
            },
        )
        self.assertEqual(node["Data"]["sensitivity"], "level_3")
        self.assertEqual(node["Data"]["source_session_ref"], "rtc_test")
        self.assertIn("Memory", node["Labels"])

    def test_rejects_noncanonical_sensitivity(self):
        settings = Settings(
            "http://litegraph", "key", str(uuid.UUID(int=1)), str(uuid.UUID(int=2))
        )
        with self.assertRaisesRegex(ValueError, "invalid_sensitivity"):
            build_memory_node(
                settings,
                {
                    "memory_type": "preference",
                    "subject": "owner",
                    "content": "Prefers window seats.",
                    "sensitivity": "public",
                    "confidence": 1,
                    "source_session_ref": "rtc_test",
                    "source_thread_ref": "thread_test",
                },
            )

    async def test_store_is_idempotent_when_memory_already_exists(self):
        settings = Settings(
            "http://litegraph", "key", str(uuid.UUID(int=1)), str(uuid.UUID(int=2))
        )
        arguments = {
            "memory_type": "preference",
            "subject": "owner",
            "content": "Prefers window seats.",
            "confidence": 1,
            "source_session_ref": "rtc_test",
            "source_thread_ref": "thread_test",
        }
        with patch(
            "memory_facade.app.ensure_memory_scope", new=AsyncMock()
        ), patch(
            "memory_facade.app.litegraph_request",
            new=AsyncMock(return_value=None),
        ) as request:
            result = await store_memory(settings, arguments)
        self.assertTrue(result["duplicate"])
        self.assertFalse(result["stored"])
        request.assert_awaited_once()

    async def test_bootstraps_missing_fixed_tenant_and_graph(self):
        settings = Settings(
            "http://litegraph", "key", str(uuid.UUID(int=1)), str(uuid.UUID(int=2))
        )
        missing = LiteGraphHttpError(404, "not found")
        request = AsyncMock(side_effect=[missing, None, missing, None])
        with patch("memory_facade.app.litegraph_request", new=request):
            await ensure_memory_scope(settings)

        self.assertEqual(request.await_count, 4)
        tenant_create = request.await_args_list[1]
        self.assertEqual(tenant_create.args[1:3], ("PUT", "/v1.0/tenants"))
        self.assertEqual(tenant_create.kwargs["json_body"]["GUID"], settings.tenant_guid)
        graph_create = request.await_args_list[3]
        self.assertEqual(graph_create.args[1], "PUT")
        self.assertEqual(graph_create.kwargs["json_body"]["GUID"], settings.graph_guid)

    async def test_existing_scope_is_checked_only_once_per_process(self):
        settings = Settings(
            "http://litegraph", "key", str(uuid.UUID(int=1)), str(uuid.UUID(int=2))
        )
        request = AsyncMock(return_value=None)
        with patch("memory_facade.app.litegraph_request", new=request):
            await ensure_memory_scope(settings)
            await ensure_memory_scope(settings)

        self.assertEqual(request.await_count, 2)


if __name__ == "__main__":
    unittest.main()
