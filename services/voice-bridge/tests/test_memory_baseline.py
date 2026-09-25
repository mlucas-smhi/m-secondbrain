import json
from pathlib import Path
import unittest

from bridge.memory_baseline import build, REVISION
from bridge.memory_seed import git


class ReviewedBaselineTests(unittest.TestCase):
    repo = Path(__file__).resolve().parents[3]
    scope = ("11111111-1111-4111-8111-111111111111",
             "22222222-2222-4222-8222-222222222222",
             "33333333-3333-4333-8333-333333333333", "user:test")

    @classmethod
    def setUpClass(cls):
        cls.plan = build(cls.repo, *cls.scope)
        cls.nodes = {n["Name"]: n for n in cls.plan["nodes"]}

    def test_deterministic_and_scope_specific(self):
        self.assertEqual(self.plan, build(self.repo, *self.scope))
        other = list(self.scope)
        other[1] = "44444444-4444-4444-8444-444444444444"
        second = build(self.repo, *other)
        self.assertFalse({n["GUID"] for n in self.plan["nodes"]} & {n["GUID"] for n in second["nodes"]})
        self.assertEqual(self.plan["source_revision"], REVISION)

    def test_every_excerpt_matches_committed_source(self):
        facts = [f for n in self.plan["nodes"] for f in n["Data"]["facts"]]
        records = facts + [e["Data"] for e in self.plan["edges"]]
        self.assertEqual(len({f["id"] for f in facts}), len(facts))
        for record in records:
            source = git(self.repo, "show", REVISION + ":" + record["source_path"]).decode()
            self.assertIn(record["excerpt"], source)
            self.assertIsNone(record["valid_from"])

    def test_examples_and_hypothetical_records_are_not_entities(self):
        for name in ("Sarah", "Decision A", "Decision B", "Avery Chen", "Morgan Vale", "test"):
            self.assertNotIn(name, self.nodes)
        self.assertIn("Ross Guidry", self.nodes)  # Real workorg evidence, not the example tree.
        self.assertNotIn("vegetarian", json.dumps(self.nodes["Pharr Andrews"]))
        self.assertEqual(len(self.plan["included_sources"]), 20)

    def test_entity_relationships_and_names(self):
        self.assertIn("Charlie", self.nodes["Charlotte Lucas"]["Data"]["aliases"])
        self.assertIn("Jeniffer Lucas", self.nodes["Jennifer Lucas"]["Data"]["aliases"])
        edges = {(e["Data"]["subject_name"], e["Name"], e["Data"]["object_name"]) for e in self.plan["edges"]}
        self.assertIn(("Curtis Miller", "reports_to", "Jesus Llorca"), edges)
        self.assertIn(("Michael Lucas", "reports_to", "Curtis Miller"), edges)
        self.assertIn(("Pharr Andrews", "owns_pet", "Biggie"), edges)
        # The individual children's notes don't establish parentage: do not guess.
        self.assertNotIn(("Michael Lucas", "parent_of", "River Lucas"), edges)

    def test_travel_hierarchy_and_historical_instructions(self):
        facts = self.nodes["Latin America & Caribbean Scouting Tour 2026"]["Data"]["facts"]
        durations = [f for f in facts if "### Duration" in f["excerpt"]]
        self.assertTrue(any("Medellín" in f["content"] and "2 Nights" in f["content"] for f in durations))
        self.assertTrue(any("Anguilla" in f["content"] and "Day Trip" in f["content"] for f in durations))
        self.assertTrue(all(f["temporal_context"].startswith("planned_") for f in facts))
        old = self.nodes["Git as Canonical Brain — historical decision"]["Data"]["facts"]
        self.assertTrue(all(f["temporal_context"].startswith("historical_") for f in old))
        self.assertFalse(any("# Outcomes" in f["excerpt"] for f in facts))


if __name__ == "__main__":
    unittest.main()
