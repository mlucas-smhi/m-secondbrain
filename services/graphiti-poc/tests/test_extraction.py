import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from extraction import ROOT, extraction_instructions, memory_arguments


class ExtractionTests(unittest.TestCase):
    def test_native_arguments_preserve_source_and_scope(self):
        body = "A fictional source paragraph."
        args = memory_arguments(name="test", episode_body=body, group_id="synthetic",
                                reference_time="2026-10-01T09:00:00-05:00",
                                source_description="Synthetic test")
        self.assertEqual(args["episode_body"], body)
        self.assertEqual(args["group_id"], "synthetic")
        self.assertEqual(args["source"], "text")
        self.assertEqual(args["custom_extraction_instructions"], extraction_instructions())
        self.assertNotIn("uuid", args)
        self.assertEqual(set(args), {"name", "episode_body", "group_id", "source",
                                    "source_description", "reference_time",
                                    "custom_extraction_instructions"})

    def test_shared_rules_retained_and_no_case_answers_in_policy(self):
        instructions = extraction_instructions()
        catalog = json.loads((ROOT / "ontology.json").read_text())
        self.assertTrue(instructions.startswith(catalog["extraction_rules"]))
        for answer in ("Rowan", "Casey", "Juniper", "Meridian", "May 12", "CFO",
                       "vegetarian", "hiking", "TH-SYN-42"):
            self.assertNotIn(answer.lower(), instructions.lower())
        self.assertIn("fact text", instructions)
        self.assertIn("missing year", instructions)


if __name__ == "__main__":
    unittest.main()
