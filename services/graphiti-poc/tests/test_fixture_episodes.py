import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fixture_episodes import FIXTURE, GROUP, build


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.fixture = json.loads(FIXTURE.read_text())

    def test_deterministic(self):
        self.assertEqual(build(self.fixture), build(self.fixture))
        result = build(self.fixture)
        self.assertEqual(len(result["episodes"]), len(self.fixture["nodes"]))
        self.assertEqual(len({e["name"] for e in result["episodes"]}), len(result["episodes"]))
        self.assertTrue(all("uuid" not in e for e in result["episodes"]))

    def test_primary_facts_and_links_preserved(self):
        result = build(self.fixture)
        for node, episode in zip(self.fixture["nodes"], result["episodes"]):
            content = json.loads(episode["episode_body"])
            self.assertEqual(content["facts"], node["facts"])
            self.assertEqual(content["fields"], node.get("fields", {}))
            self.assertEqual(episode["reference_time"], self.fixture["clock"])
            self.assertEqual(episode["group_id"], GROUP)
        self.assertEqual(sum(len(json.loads(e["episode_body"])["relationships"])
                             for e in result["episodes"]), len(self.fixture["edges"]))

    def test_no_answers_or_foreign_data(self):
        self.fixture["expected_answers"] = ["SECRET_ANSWER"]
        self.fixture["foreign_nodes"] = [{"name": "FOREIGN_SENTINEL"}]
        self.fixture["nodes"][0]["grading_hint"] = "SECRET_HINT"
        episodes = json.dumps(build(self.fixture)["episodes"])
        for forbidden in ("SECRET_ANSWER", "FOREIGN_SENTINEL", "SECRET_HINT"):
            self.assertNotIn(forbidden, episodes)

    def test_reject_real_data(self):
        self.fixture["synthetic"] = False
        with self.assertRaises(ValueError):
            build(self.fixture)

    def test_reject_cross_boundary_edge(self):
        self.fixture["edges"].append(["owner", "knows", "foreign-person"])
        with self.assertRaises(ValueError):
            build(self.fixture)

    def test_changed_content_changes_episode_identity(self):
        original = build(self.fixture)
        revised = copy.deepcopy(self.fixture)
        revised["nodes"][0]["facts"].append("A different synthetic fact")
        self.assertNotEqual(original["episodes"][0]["name"], build(revised)["episodes"][0]["name"])


if __name__ == "__main__":
    unittest.main()
