import ast
import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compile_ontology import CATALOG, apply_config, edge_map, model_source, validate


class OntologyTests(unittest.TestCase):
    def setUp(self):
        self.catalog = json.loads(CATALOG.read_text())

    def test_valid_and_covers_existing_families(self):
        validate(self.catalog)
        registry = CATALOG.parents[1] / "litegraph-memory-facade/memory_facade/entity_registry.v1.json"
        existing = json.loads(registry.read_text())
        self.assertEqual(set(existing["families"]), set(self.catalog["family_mapping"]))
        self.assertEqual(self.catalog["source_registry"], existing["version"])
        self.assertEqual(set(self.catalog["predicate_mapping"]), set(existing["predicates"]))
        self.assertEqual(self.catalog["family_mapping"]["fact"], [])

    def test_multiple_person_roles_preserved_in_one_pair(self):
        pairs = edge_map(self.catalog)
        selected = [p for p in pairs if p["source"] == p["target"] == "Person"]
        self.assertEqual(len(selected), 1)
        self.assertTrue({"PartnerOf", "ParentOf", "ReportsTo", "FriendOf", "SiblingOf"}
                        <= set(selected[0]["edge_types"]))
        self.assertNotIn("Partner", self.catalog["entity_types"])
        self.assertNotIn("Parent", self.catalog["entity_types"])

    def test_preference_facets_coexist(self):
        selected = next(p for p in edge_map(self.catalog)
                        if p["source"] == "Person" and p["target"] == "Preference")
        self.assertEqual(set(selected["edge_types"]),
                         {"HasDietaryPreference", "HasCommunicationPreference", "Prefers"})

    def test_operational_particulars_have_native_fields(self):
        required = {
            "Event": {"constraints", "hold_expires_at", "price_amount", "price_currency", "price_basis"},
            "Trip": {"cost_estimates"},
            "TransactionReference": {"departure_at", "arrival_at", "logistics"},
            "TaskReference": {"external_id", "thread_id", "task_details", "communication_state", "channels"},
            "Content": {"last_synced_at", "coverage", "limitations", "stated_updates"},
        }
        for name, fields in required.items():
            self.assertTrue(fields <= self.catalog["entity_types"][name]["fields"].keys(), name)
        self.assertIn("different entity", self.catalog["entity_types"]["TaskReference"]["description"])

    def test_direction_and_reference_only(self):
        self.assertEqual(self.catalog["edge_types"]["WorksFor"]["pairs"], [["Person", "Organization"]])
        for family in ("task", "decision", "transaction", "interaction"):
            for name in self.catalog["family_mapping"][family]:
                fields = self.catalog["entity_types"][name]["fields"]
                self.assertIn("external_id", fields)
                self.assertNotIn("authorized", fields)
        for name in ("ParentOf", "ReportsTo"):
            self.assertIn("Source person", self.catalog["edge_types"][name]["description"])

    def test_config_preserves_transport_provider_and_scope(self):
        base = {"server": {"transport": "http"}, "llm": {"model": "${MODEL_NAME}"},
                "graphiti": {"group_id": "isolated", "entity_types": []}}
        original = copy.deepcopy(base)
        result = apply_config(base, self.catalog)
        self.assertEqual(base, original)
        self.assertEqual(result["server"], base["server"])
        self.assertEqual(result["llm"], base["llm"])
        self.assertEqual(result["graphiti"]["group_id"], "isolated")

    def test_generated_python_and_optional_attributes(self):
        for key, registry in (("entity_types", "ENTITY_TYPES"), ("edge_types", "EDGE_TYPES")):
            source = model_source(self.catalog[key], registry)
            tree = ast.parse(source)
            self.assertEqual(len([n for n in tree.body if isinstance(n, ast.ClassDef)]), len(self.catalog[key]))
            for node in ast.walk(tree):
                if isinstance(node, ast.AnnAssign):
                    self.assertEqual(ast.unparse(node.value.func), "Field")
                    default = next(k.value for k in node.value.keywords if k.arg == "default")
                    self.assertIsNone(default.value)

    def test_reject_undefined_relationship_endpoint(self):
        self.catalog["edge_types"]["ParentOf"]["pairs"].append(["Person", "ChildRole"])
        with self.assertRaises(ValueError): validate(self.catalog)

    def test_reject_protected_fields(self):
        self.catalog["entity_types"]["Person"]["fields"]["uuid"] = ["str", "Do not shadow native IDs"]
        with self.assertRaises(ValueError): validate(self.catalog)

    def test_reject_unmapped_entity(self):
        self.catalog["entity_types"]["Mystery"] = {"description": "Undefined family", "fields": {}}
        with self.assertRaises(ValueError): validate(self.catalog)

    def test_acceptance_cases_are_synthetic_and_separate_from_ingestion(self):
        cases = json.loads(CATALOG.with_name("ontology-acceptance.json").read_text())
        self.assertTrue(cases["synthetic"])
        self.assertEqual(len({c["id"] for c in cases["cases"]}), len(cases["cases"]))
        for case in cases["cases"]:
            self.assertTrue(case["episodes"])
            self.assertTrue(case["checks"])
            self.assertTrue(case["must_not"])


if __name__ == "__main__":
    unittest.main()
