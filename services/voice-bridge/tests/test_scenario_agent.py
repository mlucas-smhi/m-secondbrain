from pathlib import Path
import unittest
from bridge.scenario_agent import chat_prompt


class ScenarioAgentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.native = (Path(__file__).resolve().parents[1] / "eleven-private-memory.md").read_text()

    def test_test_scope_and_no_real_identity_or_phone_variables(self):
        prompt = chat_prompt(self.native)
        self.assertIn("Casey Rowan", prompt)
        self.assertIn("e6d076f3-454a-5f3c-8d32-6c56a0953076", prompt)
        self.assertIn("October 5, 2026", prompt)
        for forbidden in ("{{", "Michael Lucas", "Andrew Everett", "Pharr Andrews", "get_live_call_context", "Cobalt Lantern 739"):
            self.assertNotIn(forbidden, prompt)

    def test_save_workflow_is_preserved_without_answers(self):
        prompt = chat_prompt(self.native)
        for required in ("Creating the name alone does NOT", "actual details persisted", "node/search", "node/update", "edge/create", "No calendar, travel"):
            self.assertIn(required, prompt)
        for answer in ("Robin is vegetarian", "$2,400", "rescheduled twice", "Morgan is vegan"):
            self.assertNotIn(answer, prompt)

    def test_plan_check_requires_context_not_fixture_answers(self):
        prompt = chat_prompt(self.native)
        for required in ("BEFORE calling it a good choice", "profile alone is not",
                         "includeSubordinates is not relationship traversal",
                         "calendar coverage", "timezones", "superseded",
                         "cannot certify live free/busy", "Do not sweep every"):
            self.assertIn(required, prompt)
        for answer in ("Northstar", "Houston", "SFO", "14:00", "moved twice"):
            self.assertNotIn(answer, prompt)

    def test_shared_production_prompt_is_not_modified(self):
        self.assertNotIn("## Check the context before endorsing a plan", self.native)

    def test_decision_and_combined_plan_coverage(self):
        prompt = chat_prompt(self.native)
        for required in ("deadline\nwith timezone", "structured fields", "linked option",
                         "every requested component AND their interactions",
                         "related outbound/return legs", "combined costs against the budget",
                         "Avoid double-counting", "shared\ndates alone do not prove",
                         "first discovered conflict", "not incomplete in investigation"):
            self.assertIn(required, prompt)

    def test_uncertainty_and_scope_are_explicit(self):
        prompt = chat_prompt(self.native)
        for required in ("NOT mean the slot or work calendar is clear",
                         "fresh, complete evidence", "Do not silently substitute",
                         "label it clearly as belonging to this workspace",
                         "Do not open with", "an arbitrary LIMIT",
                         "computed total/budget gap"):
            self.assertIn(required, prompt)
        self.assertLess(prompt.index("## Check the context"), prompt.index("## Orientation and recall"))
