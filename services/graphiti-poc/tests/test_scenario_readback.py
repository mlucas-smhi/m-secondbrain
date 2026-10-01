import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_scenario_readback import evaluate


class ReadbackTests(unittest.TestCase):
    def test_empty_graph_cannot_pass(self):
        self.assertFalse(any(evaluate({"nodes": [], "edges": []}).values()))

    def test_task_ids_do_not_prove_distinct_identity(self):
        graph = {"edges": [], "nodes": [
            {"name": "Move Friday return flight later — cross-channel task", "uuid": "same",
             "labels": ["TaskReference"], "attributes": {"external_id": "sim:te:flight-001",
                                                         "thread_id": "sim:thread:flight-001"}},
            {"name": "Friday Houston return flight option", "uuid": "same",
             "labels": ["TransactionReference"], "attributes": {}},
        ]}
        checks = evaluate(graph)
        self.assertTrue(checks["task_and_thread_ids"])
        self.assertFalse(checks["task_distinct_from_transaction"])
        separate = copy.deepcopy(graph)
        separate["nodes"][1]["uuid"] = "other"
        self.assertTrue(evaluate(separate)["task_distinct_from_transaction"])

    def test_one_buffer_is_not_enough(self):
        graph = {"edges": [], "nodes": [{"name": "Friday Houston return flight option",
                 "attributes": {"logistics": ["60 minutes drive"]}}]}
        self.assertFalse(evaluate(graph)["return_buffers"])
        graph["nodes"][0]["attributes"]["logistics"].append("30 minutes exit")
        self.assertTrue(evaluate(graph)["return_buffers"])


if __name__ == "__main__":
    unittest.main()
