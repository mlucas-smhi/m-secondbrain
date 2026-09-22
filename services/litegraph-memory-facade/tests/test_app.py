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

    def test_spoken_variant_surfaces_legacy_context_without_merging(self):
        nodes = [{"GUID": "a", "Data": {"subject": "owner", "content": "Partner: Pharr Andrews."}}]
        result = rank_nodes(nodes, "Far", 10)
        self.assertEqual(result[0]["match_kind"], "phonetic_candidate")
        self.assertNotIn("entity", result[0]["Data"])
        self.assertNotIn("match_kind", nodes[0])

    def test_alias_finds_other_facts_on_same_entity(self):
        nodes = [
            {"GUID": "a", "Data": {"entity": {"id": "person1", "name": "Pharr Andrews", "aliases": ["Far"]}, "content": "Vegetarian"}},
            {"GUID": "b", "Data": {"entity": {"id": "person1", "name": "Pharr Andrews", "aliases": []}, "content": "Birthday in November"}},
            {"GUID": "c", "Data": {"entity": {"id": "person2", "name": "Jane Smith", "aliases": []}, "content": "Likes tea"}},
        ]
        self.assertEqual({n["GUID"] for n in rank_nodes(nodes, "Far", 10)}, {"a", "b"})
        self.assertEqual({n["GUID"] for n in rank_nodes(nodes, "Pharr", 10)}, {"a", "b"})

    def test_ambiguous_names_remain_separate_candidates(self):
        nodes = [{"GUID": str(i), "Data": {"content": name}} for i, name in enumerate(["Pharr Andrews", "Farr Jones"])]
        result = rank_nodes(nodes, "Far", 10)
        self.assertEqual(len(result), 2)
        self.assertTrue(all(n["match_kind"] == "phonetic_candidate" for n in result))

    async def linked_write(self, anchor, **overrides):
        settings = Settings("http://litegraph", "key", str(uuid.UUID(int=1)), str(uuid.UUID(int=2)))
        args = dict(memory_type="preference", subject="Far", content="Pharr Andrews is vegetarian.", confidence=1,
                    source_session_ref="rtc", source_thread_ref="thread", entity_memory_id=str(uuid.UUID(int=3)), entity_name="Pharr Andrews")
        args.update(overrides)
        with patch("memory_facade.app.ensure_memory_scope", new=AsyncMock()), patch(
            "memory_facade.app.get_memory", new=AsyncMock(return_value={"content": anchor})
        ), patch("memory_facade.app._resource_exists", new=AsyncMock(return_value=False)), patch(
            "memory_facade.app.litegraph_request", new=AsyncMock(return_value={})
        ) as request:
            result = await store_memory(settings, args)
        return result, request.await_args.kwargs["json_body"]

    async def test_link_preserves_canonical_identity_and_observed_alias(self):
        result, node = await self.linked_write({"subject": "owner", "content": "Partner: Pharr Andrews."})
        self.assertTrue(result["stored"])
        self.assertEqual(node["Data"]["subject"], "Pharr Andrews")
        self.assertEqual(node["Data"]["observed_subject"], "Far")
        self.assertIn("Far", node["Data"]["entity"]["aliases"])
        _, next_node = await self.linked_write(node["Data"], content="Pharr Andrews likes travel.")
        self.assertEqual(node["Data"]["entity"]["id"], next_node["Data"]["entity"]["id"])

    async def test_linked_retry_idempotent_and_same_name_anchors_distinct(self):
        anchor = {"content": "Pharr Andrews"}
        _, first = await self.linked_write(anchor)
        _, retry = await self.linked_write(anchor)
        _, other = await self.linked_write(anchor, entity_memory_id=str(uuid.UUID(int=4)))
        self.assertEqual(first["GUID"], retry["GUID"])
        self.assertNotEqual(first["Data"]["entity"]["id"], other["Data"]["entity"]["id"])

    async def test_rejects_unsupported_or_conflicting_entity_name(self):
        with self.assertRaisesRegex(ValueError, "entity_name_not_supported"):
            await self.linked_write({"content": "Jane Smith"})
        with self.assertRaisesRegex(ValueError, "entity_name_conflicts"):
            await self.linked_write({"entity": {"id": "person", "name": "Jane Smith"}})
        with self.assertRaisesRegex(ValueError, "entity_reference_not_active"):
            await self.linked_write({"content": "Pharr Andrews", "status": "inactive"})
        with self.assertRaisesRegex(ValueError, "required_together"):
            await self.linked_write({}, entity_name="")
        with self.assertRaisesRegex(ValueError, "invalid_entity_memory_id"):
            await self.linked_write({}, entity_memory_id="../another-graph")

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
        tenant_missing = LiteGraphHttpError(404, "not found")
        graph_missing = LiteGraphHttpError(400)
        request = AsyncMock(side_effect=[tenant_missing, None, graph_missing, None])
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
