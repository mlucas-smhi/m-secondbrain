import copy
import json
import unittest
from bridge.memory_scenarios import build, apply, verify, digest, FIXTURE


class Store:
    def __init__(self, plan):
        self.plan = plan
        self.nodes, self.edges = {}, {}
        self.transactions = 0
        self.lose_reply = False
        self.fail = False

    def request(self, method, path, body=None):
        if method == "POST":
            self.transactions += 1
            if self.fail:
                raise RuntimeError("simulated_failure")
            for operation in body["Operations"]:
                assert operation["OperationType"] == "Create"
                target = self.nodes if operation["ObjectType"] == "Node" else self.edges
                record = copy.deepcopy(operation["Payload"])
                assert record["GUID"] not in target
                target[record["GUID"]] = record
            if self.lose_reply:
                raise TimeoutError("lost_reply")
            return {"Success": True, "State": "Committed"}
        clean = path.split("?")[0]
        for kind in ("nodes", "edges"):
            if clean.endswith("/" + kind):
                values = list(getattr(self, kind).values())
                return {"Objects": copy.deepcopy(values), "TotalRecords": len(values), "EndOfResults": True}
        return {"Data": copy.deepcopy(self.plan["metadata"])}


class ScenarioTests(unittest.TestCase):
    def test_deterministic_isolated_complete(self):
        a, b = build(), build(compartment="foreign")
        self.assertEqual(a, build())
        for field in ("tenant", "graph", "workspace", "owner"):
            self.assertNotEqual(a["scope"][field], b["scope"][field])
        self.assertEqual(len(a["nodes"]), 23)
        self.assertEqual(len(a["edges"]), 31)
        self.assertNotIn("Cobalt Lantern 739", json.dumps(a))
        self.assertIn("Cobalt Lantern 739", json.dumps(b))
        morgan = next(n for n in a["nodes"] if n["Name"] == "Morgan Vale")
        self.assertNotIn("vegan", json.dumps(morgan))
        self.assertNotIn("hiking", json.dumps(morgan))

    def test_commit_verify_and_non_overwriting_retry(self):
        plan = build()
        store = Store(plan)
        self.assertEqual(apply(plan, store.request)["status"], "seeded")
        self.assertEqual(verify(plan, store.request)["readback"], "all_records_match")
        store.nodes[plan["nodes"][0]["GUID"]]["Data"]["later_fact"] = "preserve"
        self.assertEqual(apply(plan, store.request)["status"], "already_seeded")
        self.assertEqual(store.transactions, 1)
        with self.assertRaisesRegex(RuntimeError, "readback_mismatch"):
            verify(plan, store.request)

    def test_lost_response_and_failed_transaction(self):
        plan = build()
        store = Store(plan)
        store.lose_reply = True
        self.assertEqual(apply(plan, store.request)["status"], "seeded")
        store = Store(plan)
        store.fail = True
        with self.assertRaisesRegex(RuntimeError, "simulated_failure"):
            apply(plan, store.request)
        self.assertEqual(store.nodes, {})

    def test_nonempty_or_wrong_scope_or_tampering_rejected(self):
        plan = build()
        store = Store(plan)
        store.nodes["unrelated"] = {"GUID": "unrelated"}
        with self.assertRaisesRegex(ValueError, "requires_empty"):
            apply(plan, store.request)
        bad = copy.deepcopy(plan)
        bad["scope"]["graph"] = "df5fedac-4567-4c09-86fe-fbba399161d1"
        bad["digest"] = digest(bad)
        with self.assertRaisesRegex(ValueError, "not_isolated"):
            apply(bad, Store(bad).request)
        bad = copy.deepcopy(plan)
        bad["nodes"][0]["Name"] = "tampered"
        with self.assertRaisesRegex(ValueError, "digest_mismatch"):
            apply(bad, Store(bad).request)

    def test_payload_cannot_smuggle_foreign_scope_or_relationship(self):
        bad = build()
        bad["nodes"][0]["GraphGUID"] = build(compartment="foreign")["scope"]["graph"]
        bad["digest"] = digest(bad)
        with self.assertRaisesRegex(ValueError, "record_scope_mismatch"):
            apply(bad, Store(bad).request)
        bad = build()
        bad["edges"][0]["To"] = build(compartment="foreign")["nodes"][0]["GUID"]
        bad["digest"] = digest(bad)
        with self.assertRaisesRegex(ValueError, "edge_outside_scope"):
            apply(bad, Store(bad).request)

    def test_missing_relationship_or_incomplete_readback_fails(self):
        plan = build()
        store = Store(plan)
        apply(plan, store.request)
        store.edges.pop(next(iter(store.edges)))
        with self.assertRaisesRegex(RuntimeError, "record_set_mismatch"):
            verify(plan, store.request)

    def test_fixture_relationship_validation(self):
        fixture = json.loads(FIXTURE.read_text())
        fixture["edges"].append(["missing", "knows", "owner"])
        with self.assertRaisesRegex(ValueError, "dangling"):
            build(fixture)


if __name__ == "__main__":
    unittest.main()
