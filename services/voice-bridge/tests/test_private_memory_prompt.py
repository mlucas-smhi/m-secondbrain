import json
import pathlib
import re
import unittest


class PrivateMemoryPromptTests(unittest.TestCase):
    def setUp(self):
        self.prompt = (pathlib.Path(__file__).parents[1] / "eleven-private-memory.md").read_text()

    def test_search_example_is_scoped_and_bounded(self):
        example = json.loads(re.search(r"```json\n(.*?)\n```", self.prompt, re.S).group(1))
        self.assertEqual(example["TenantGUID"], "{{PRIVATE_TENANT}}")
        self.assertEqual(example["GraphGUID"], "{{PRIVATE_GRAPH}}")
        self.assertEqual(example["Name"], "Andrew")
        self.assertEqual(example["MaxResults"], 5)
        self.assertEqual(example["Skip"], 0)
        self.assertFalse(example["IncludeData"])
        self.assertFalse(example["IncludeSubordinates"])

    def test_lookup_does_not_require_startup_inventory(self):
        self.assertIn("Do not enumerate the directory at startup", self.prompt)
        self.assertIn("Only for explicit inventory questions", self.prompt)
        self.assertIn("never select the first result blindly", self.prompt)
        self.assertIn("Reuse resolved IDs", self.prompt)
        self.assertNotIn("At the first substantive turn, use `node/all`", self.prompt)

    def test_save_guide_keeps_behavior_without_packaging_recipe(self):
        saving = self.prompt.split("## Quiet, proactive saving", 1)[1].split("## Put memory to work", 1)[0]
        self.assertIn("Use memory tools", saving)
        self.assertIn("confirms the information was successfully stored", saving)
        self.assertIn("Preserve existing memories", saving)
        self.assertIn("If saving fails, say so briefly", saving)
        self.assertIn("Never invent facts or store", saving)
        for removed in ("serialized", "supersedes_fact_id", "Data.facts"):
            self.assertNotIn(removed, saving)

    def test_save_workflow_requires_details_and_readback(self):
        workflow = self.prompt.split("### When saving information", 1)[1].split("### What a complete memory contains", 1)[0]
        for tool in ("node/search", "node/get", "node/create", "node/update"):
            self.assertIn(tool, workflow)
        self.assertIn("Creating the name alone does NOT save", workflow)
        self.assertIn("verify the actual details persisted", workflow)
        self.assertIn("including existing details and labels", workflow)
        self.assertIn("finish\npopulating that same record", workflow)

    def test_examples_do_not_seed_facts_or_invent_operational_ids(self):
        self.assertIn("illustrative only, never seed these as memories", self.prompt)
        for kind in ("Person:", "Meeting:", "Event:", "Project:", "Trip:", "Decision:", "Task/commitment:"):
            self.assertIn(kind, self.prompt)
        self.assertIn("Never invent a Turn Engine ID or substitute a graph node ID", self.prompt)
        self.assertIn("same operational task keeps its Turn Engine ID", self.prompt)
        self.assertIn("Leave unknown details unspecified", self.prompt)


if __name__ == "__main__":
    unittest.main()
