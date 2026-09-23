import copy
import os
import unittest
import uuid
from datetime import datetime, timezone
from unittest.mock import patch

from memory_facade.app import Settings, LiteGraphHttpError, store_memory, get_memory, tool_catalog
from memory_facade.graph_memory import GraphMemory, REGISTRY, data


def bundle():
    return {
        "source_ref": "utterance-1", "source_session_ref": "call-1", "source_thread_ref": "thread-1",
        "idempotency_key": "capture-1",
        "entities": [{"key": "andrew", "family": "person", "name": "Andrew Example"},
                     {"key": "utah", "family": "place", "name": "Utah"},
                     {"key": "skiing", "family": "activity", "name": "Skiing"}],
        "facts": [
            {"key": "home", "subject": "andrew", "predicate": "lives_in", "object": "utah",
             "content": "Andrew lives in Utah.", "evidence": "Andrew lives in Utah and enjoys skiing. He's vegetarian.", "confidence": 1},
            {"key": "hobby", "subject": "andrew", "predicate": "interested_in", "object": "skiing",
             "content": "Andrew enjoys skiing.", "evidence": "Andrew lives in Utah and enjoys skiing. He's vegetarian.", "confidence": 1},
            {"key": "diet", "subject": "andrew", "predicate": "dietary_preference", "value": "vegetarian",
             "content": "Andrew is vegetarian.", "evidence": "He's vegetarian.", "confidence": 1},
        ],
    }


class FakeGraph:
    """Contract double, NOT proof of real LiteGraph transaction compatibility."""
    def __init__(self):
        self.nodes, self.edges, self.calls = {}, {}, []
        self.failure = None

    async def __call__(self, settings, method, path, **kwargs):
        self.calls.append((method, path, kwargs))
        if method == "GET" and path.endswith("/graphs/" + settings.graph_guid):
            return {"Data": {"memory_schema_version": "entity-memory.v1", "workspace_id": settings.workspace_id, "owner_ref": settings.owner_ref}}
        if method == "GET" and "/nodes/" in path:
            value = self.nodes.get(path.rsplit("/", 1)[1])
            if value is None:
                raise LiteGraphHttpError(404)
            return copy.deepcopy(value)
        if method == "GET":
            objects = self.nodes if path.endswith("/nodes") else self.edges
            skip = int(kwargs["params"].get("skip", 0))
            ordered = sorted(objects.values(), key=lambda x: x["GUID"])
            return {"Objects": copy.deepcopy(ordered[skip:skip + 1000]), "EndOfResults": len(ordered) <= skip + 1000}
        if method == "POST" and path.endswith("/transaction"):
            if self.failure == "rollback":
                return {"Success": False, "State": "RolledBack", "RolledBack": True}
            nodes, edges = copy.deepcopy(self.nodes), copy.deepcopy(self.edges)
            for operation in kwargs["json_body"]["Operations"]:
                self.assert_create(operation)
                target = nodes if operation["ObjectType"] == "Node" else edges
                item = operation["Payload"]
                if item["GUID"] in target:
                    raise LiteGraphHttpError(409)
                if target is edges and (item["From"] not in nodes or item["To"] not in nodes):
                    raise LiteGraphHttpError(409)
                target[item["GUID"]] = copy.deepcopy(item)
            self.nodes, self.edges = nodes, edges
            if self.failure == "timeout_after_commit":
                raise TimeoutError()
            return {"Success": True, "State": "Committed", "RolledBack": False}
        raise AssertionError((method, path))

    @staticmethod
    def assert_create(operation):
        assert operation["OperationType"] == "Create", "Existing entities must never be blindly upserted"


class GraphMemoryTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.settings = Settings("http://litegraph", "secret", str(uuid.UUID(int=1)), str(uuid.UUID(int=2)),
                                 graph_memory_enabled=True, workspace_id="workspace-a", owner_ref="user:owner-a")
        self.backend = FakeGraph()
        self.graph = GraphMemory(self.settings, self.backend)

    async def test_real_entity_fact_and_relationship_shapes(self):
        result = await self.graph.store(bundle())
        self.assertEqual(result["status"], "saved")
        self.assertEqual(len(result["entities"]), 3)
        self.assertEqual(len(result["memory_ids"]), 3)
        self.assertEqual(len(result["edge_ids"]), 8)
        self.assertEqual(len(self.backend.nodes), 7)  # 3 entities + 3 facts + receipt
        self.assertEqual(len([c for c in self.backend.calls if c[0] == "POST"]), 1)
        for node in self.backend.nodes.values():
            self.assertEqual(data(node)["workspace_id"], "workspace-a")
            self.assertEqual(data(node)["sensitivity_level"], 3)
        context = await self.graph.context(result["entities"]["andrew"]["id"])
        self.assertEqual(len(context["facts"]), 3)
        self.assertEqual({data(n)["canonical_name"] for n in context["related_entities"]}, {"Utah", "Skiing"})
        self.assertTrue(any(e["Name"] == "lives_in" for e in context["relationships"]))

    async def test_same_payload_retry_returns_receipt_without_writing(self):
        first = await self.graph.store(bundle())
        second = await self.graph.store(bundle())
        self.assertEqual(first["memory_ids"], second["memory_ids"])
        self.assertTrue(second["duplicate"])
        self.assertFalse(second["stored"])
        self.assertEqual(len([c for c in self.backend.calls if c[0] == "POST"]), 1)

    async def test_changed_payload_cannot_reuse_idempotency_key(self):
        await self.graph.store(bundle())
        changed = bundle()
        changed["facts"][2]["value"] = "vegan"
        with self.assertRaisesRegex(ValueError, "idempotency_key_reused"):
            await self.graph.store(changed)

    async def test_timeout_after_commit_reconciles_using_receipt(self):
        self.backend.failure = "timeout_after_commit"
        result = await self.graph.store(bundle())
        self.assertEqual(result["status"], "saved")
        self.assertTrue(result["duplicate"])
        self.assertEqual(len(self.backend.nodes), 7)

    async def test_rollback_never_returns_saved_or_partial_nodes(self):
        self.backend.failure = "rollback"
        with self.assertRaisesRegex(RuntimeError, "not_committed"):
            await self.graph.store(bundle())
        self.assertEqual(self.backend.nodes, {})
        self.assertEqual(self.backend.edges, {})

    async def test_same_name_not_automatically_merged(self):
        first = await self.graph.store(bundle())
        other = bundle()
        other["source_ref"] = "different-person-source"
        second = await self.graph.store(other)
        self.assertNotEqual(first["entities"]["andrew"]["id"], second["entities"]["andrew"]["id"])

    async def test_exact_entity_is_not_crowded_out_by_its_character_sheet(self):
        args=bundle()
        args['entities']=args['entities'][:1]
        args['facts']=[{**args['facts'][2], 'key':f'fact{i}',
            'content':f'Andrew Example has synthetic preference {i}.'} for i in range(20)]
        saved=await self.graph.store(args)
        result=await self.graph.search({'query':'Andrew Example','max_results':10})
        self.assertEqual(result['matches'][0]['memory_id'],saved['entities']['andrew']['id'])
        self.assertTrue(result['has_more_matches'])
        self.assertFalse(result['has_more_entity_matches'])

    async def additional(self, first, **changes):
        args = bundle()
        args.update(source_ref="utterance-2", idempotency_key="capture-2")
        args["entities"] = [{**args["entities"][0], "existing_id": first["entities"]["andrew"]["id"]}]
        args["facts"] = [{**args["facts"][2], **changes}]
        return await self.graph.store(args)

    async def test_cross_call_addition_reuses_entity(self):
        first = await self.graph.store(bundle())
        second = await self.additional(first, predicate="prefers", value="quiet restaurants", content="Andrew prefers quiet restaurants.", evidence="He likes quiet restaurants.")
        self.assertEqual(first["entities"]["andrew"]["id"], second["entities"]["andrew"]["id"])
        context = await self.graph.context(first["entities"]["andrew"]["id"])
        self.assertEqual(len(context["facts"]), 4)

    async def test_correction_preserves_history_but_excludes_old_current_fact(self):
        first = await self.graph.store(bundle())
        await self.additional(first, value="vegan", content="Andrew is now vegan.", evidence="He switched to vegan.", supersedes_memory_id=first["memory_ids"][2])
        context = await self.graph.context(first["entities"]["andrew"]["id"])
        self.assertEqual(len(context["facts"]), 3)
        diets = [data(n)["value"] for n in context["facts"] if data(n)["predicate"] == "dietary_preference"]
        self.assertEqual(diets, ["vegan"])
        self.assertIn(first["memory_ids"][2], self.backend.nodes)

    async def test_future_correction_does_not_supersede_early(self):
        first = await self.graph.store(bundle())
        await self.additional(first, value="vegan", valid_from="2099-01-01T00:00:00Z", supersedes_memory_id=first["memory_ids"][2])
        context = await self.graph.context(first["entities"]["andrew"]["id"])
        self.assertTrue(any(n["GUID"] == first["memory_ids"][2] for n in context["facts"]))
        self.assertFalse(any(data(n)["value"] == "vegan" for n in context["facts"]))

    async def test_expired_correction_does_not_resurrect_old_fact(self):
        args = bundle()
        for f in args["facts"]:
            f["valid_from"] = "2020-01-01T00:00:00Z"
        first = await self.graph.store(args)
        await self.additional(first, value="vegan", valid_from="2021-01-01T00:00:00Z", valid_until="2022-01-01T00:00:00Z", supersedes_memory_id=first["memory_ids"][2])
        context = await self.graph.context(first["entities"]["andrew"]["id"])
        self.assertFalse(any(data(n)["predicate"] == "dietary_preference" for n in context["facts"]))

    async def test_unknown_predicate_preserves_fact_as_pending(self):
        args = bundle()
        args["facts"][2]["predicate"] = "custom_diet_description"
        result = await self.graph.store(args)
        self.assertEqual(result["classification_pending"], [result["memory_ids"][2]])
        self.assertNotIn("custom_diet_description", REGISTRY["predicates"])
        self.assertTrue((await self.graph.context(result["entities"]["andrew"]["id"]))["classification_pending"])

    async def test_registry_alias_normalized_without_losing_evidence(self):
        args = bundle()
        args["facts"][0]["predicate"] = "resides_in"
        result = await self.graph.store(args)
        self.assertEqual(data(self.backend.nodes[result["memory_ids"][0]])["predicate"], "lives_in")
        self.assertEqual(data(self.backend.nodes[result["memory_ids"][0]])["evidence"], args["facts"][0]["evidence"])

    async def test_explicit_correction_can_target_legacy_preference_alias(self):
        args=bundle(); args['entities']=args['entities'][:1]
        args['facts']=[{**args['facts'][2], 'predicate':'communication_preference',
            'value':'phone first for urgent messages','content':'Andrew prefers phone first for urgent messages.'}]
        saved=await self.graph.store(args)
        prior_id=saved['memory_ids'][0]
        # Reproduce an immutable fact written before the approved alias existed.
        self.backend.nodes[prior_id]['Data']['predicate']='urgent_message_preference'
        self.backend.nodes[prior_id]['Data']['classification_status']='pending'
        prior=copy.deepcopy(self.backend.nodes[prior_id])
        change=copy.deepcopy(args)
        change['source_ref']='later-call'; change['idempotency_key']='urgent-correction'
        change['entities'][0]['existing_id']=saved['entities']['andrew']['id']
        change['facts'][0].update(value='text first for urgent messages',
            content='Andrew now prefers text first for urgent messages.',
            evidence='For urgent messages use text first instead of phone.',supersedes_memory_id=prior_id)
        result=await self.graph.store(change)
        self.assertEqual(self.backend.nodes[prior_id],prior)
        self.assertEqual(result['classification_pending'],[])
        recalled=await self.graph.context(saved['entities']['andrew']['id'])
        self.assertEqual([n['GUID'] for n in recalled['facts']],result['memory_ids'])

    async def test_wrong_scope_reference_rejected_without_write(self):
        first = await self.graph.store(bundle())
        entity = self.backend.nodes[first["entities"]["andrew"]["id"]]
        entity["Data"]["workspace_id"] = "other-workspace"
        before = len(self.backend.nodes)
        with self.assertRaisesRegex(ValueError, "outside_authorized_scope"):
            await self.additional(first)
        self.assertEqual(len(self.backend.nodes), before)

    async def test_model_cannot_supply_owner_or_operational_entities(self):
        args = bundle()
        args["owner_ref"] = "user:other"
        with self.assertRaisesRegex(ValueError, "invalid_graph_fields"):
            await self.graph.store(args)
        for family in ("task", "decision", "transaction", "interaction", "fact"):
            args = bundle()
            args["entities"][0]["family"] = family
            with self.assertRaisesRegex(ValueError, "authoritative_writer"):
                await self.graph.store(args)
        self.assertEqual(self.backend.nodes, {})

    async def test_invalid_fact_rejects_entire_bundle(self):
        cases = [
            {"object": "nonexistent", "value": "both"},
            {"confidence": float("nan")}, {"confidence": True},
            {"evidence": ""}, {"valid_from": "2026-01-01"},
            {"valid_from": "2026-01-01T00:00:00Z", "valid_until": "2025-01-01T00:00:00Z"},
        ]
        for invalid in cases:
            args = bundle()
            args["facts"][2].update(invalid)
            with self.assertRaises(ValueError):
                await self.graph.store(args)
        self.assertEqual(self.backend.nodes, {})
        self.assertFalse(any(c[0] == "POST" for c in self.backend.calls))

    async def test_no_blind_graph_bootstrap_or_legacy_write_fallback(self):
        with patch("memory_facade.app.litegraph_request", self.backend), patch("memory_facade.app.ensure_memory_scope") as bootstrap:
            saved = await store_memory(self.settings, bundle())
            result = await get_memory(self.settings, {"memory_id": saved["entities"]["andrew"]["id"]})
            self.assertEqual(len(result["facts"]), 3)
            with self.assertRaises(ValueError):
                await store_memory(self.settings, {"subject": "Andrew", "content": "a legacy note"})
            bootstrap.assert_not_called()

    async def test_search_excludes_receipts_and_superseded_facts(self):
        first = await self.graph.store(bundle())
        await self.additional(first, value="vegan", content="Andrew is vegan.", supersedes_memory_id=first["memory_ids"][2])
        result = await self.graph.search({"query": "Andrew", "max_results": 10})
        self.assertTrue(all(n["kind"] in ("Entity", "Fact") for n in result["matches"]))
        self.assertNotIn(first["memory_ids"][2], [n["memory_id"] for n in result["matches"]])

    async def test_context_requires_graph_link_not_only_json_subject(self):
        result = await self.graph.store(bundle())
        self.backend.edges = {k: e for k, e in self.backend.edges.items() if e["Name"] != "has_fact"}
        with self.assertRaisesRegex(RuntimeError, "missing_fact_link"):
            await self.graph.context(result["entities"]["andrew"]["id"])

    async def test_interest_context_traverses_incoming_relationship(self):
        result = await self.graph.store(bundle())
        context = await self.graph.context(result["entities"]["skiing"]["id"])
        self.assertEqual(len(context["facts"]), 1)
        self.assertEqual(data(context["related_entities"][0])["canonical_name"], "Andrew Example")

    async def test_resolved_alias_expands_other_facts_without_mutating_entity(self):
        args = bundle()
        args["entities"][0]["observed_name"] = "Andy"
        first = await self.graph.store(args)
        result = await self.graph.search({"query": "Andy", "max_results": 10})
        self.assertTrue(set(first["memory_ids"]).issubset({n["memory_id"] for n in result["matches"]}))

    async def test_missing_related_entity_is_not_silently_omitted(self):
        first = await self.graph.store(bundle())
        del self.backend.nodes[first["entities"]["utah"]["id"]]
        with self.assertRaisesRegex(RuntimeError, "missing_related_entity"):
            await self.graph.context(first["entities"]["andrew"]["id"])

    async def test_truncated_reads_fail_instead_of_claiming_no_memories(self):
        async def unending(*args, **kwargs):
            return {"Objects": [{}], "EndOfResults": False}
        graph = GraphMemory(self.settings, unending)
        with self.assertRaisesRegex(RuntimeError, "capacity_exceeded"):
            await graph.list_records("nodes")

    async def test_graph_scope_must_be_explicitly_provisioned(self):
        async def legacy_scope(*args, **kwargs):
            return {"Data": {}}
        graph = GraphMemory(self.settings, legacy_scope)
        with self.assertRaisesRegex(ValueError, "scope_not_provisioned"):
            await graph.store(bundle())

    async def test_legacy_records_cannot_be_silently_hidden(self):
        self.backend.nodes["legacy"] = {"GUID": "legacy", "Data": {"schema_version": "memory-v1", "content": "a preserved memory"}}
        with self.assertRaisesRegex(RuntimeError, "explicit_migration"):
            await self.graph.search({"query": "memory"})

    def test_registry_has_all_families_and_operational_authority(self):
        self.assertEqual(len(REGISTRY["families"]), 19)
        self.assertEqual({k for k, v in REGISTRY["families"].items() if v["authority"] == "turn_engine"}, {"task", "decision", "transaction", "interaction"})

    def test_graph_mode_requires_trusted_scope_configuration(self):
        env = {"LITEGRAPH_ENDPOINT": "http://litegraph", "LITEGRAPH_API_KEY": "key", "MCP_TENANT_GUID": self.settings.tenant_guid,
               "MCP_GRAPH_GUID": self.settings.graph_guid, "GRAPH_MEMORY_ENABLED": "true"}
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(RuntimeError, "MEMORY_WORKSPACE_ID"):
                Settings.from_env()

    def test_tool_schema_switch_is_explicit_and_bounded(self):
        legacy = tool_catalog()[2]["inputSchema"]
        graph = tool_catalog(True)[2]["inputSchema"]
        self.assertIn("subject", legacy["properties"])
        self.assertNotIn("subject", graph["properties"])
        self.assertEqual(graph["properties"]["facts"]["maxItems"], 20)
        self.assertNotIn("workspace_id", graph["properties"])
        fact = graph["properties"]["facts"]["items"]
        self.assertEqual(fact["oneOf"], [
            {"required": ["value"], "not": {"required": ["object"]}},
            {"required": ["object"], "not": {"required": ["value"]}},
        ])
        for endpoint in ("subject", "object"):
            self.assertIn("entities[].key", fact["properties"][endpoint]["description"])
            self.assertEqual(fact["properties"][endpoint]["pattern"], "^[a-z][a-z0-9_]{0,63}$")


if __name__ == "__main__":
    unittest.main()
