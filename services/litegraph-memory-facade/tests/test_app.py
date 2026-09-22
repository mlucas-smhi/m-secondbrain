import unittest
import uuid
from unittest.mock import AsyncMock, patch

from memory_facade.app import (
    Settings,
    build_memory_node,
    rank_nodes,
    store_memory,
    tool_catalog,
)


class FacadeTests(unittest.IsolatedAsyncioTestCase):
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
            "memory_facade.app.litegraph_request",
            new=AsyncMock(return_value={"GUID": "existing"}),
        ) as request:
            result = await store_memory(settings, arguments)
        self.assertTrue(result["duplicate"])
        self.assertFalse(result["stored"])
        request.assert_awaited_once()


if __name__ == "__main__":
    unittest.main()
