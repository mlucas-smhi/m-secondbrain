"""Deterministic, isolated synthetic fixtures; no live-agent configuration changes.

The apply adapter uses LiteGraph REST and an atomic create-only transaction.
Expected responses live outside the fixture and are never written to the graph.
"""
import hashlib
import json
from pathlib import Path
import uuid

SUITE = "ea-memory-cookoff.v1"
SCHEMA = "eleven-native-memory.v1"
FIXTURE = Path(__file__).resolve().parents[1] / "fixtures/memory-scenarios-v1.json"
NAMESPACE = uuid.uuid5(uuid.NAMESPACE_DNS, "ea-memory-cookoff.example.invalid")


def stable(key):
    return str(uuid.uuid5(NAMESPACE, SUITE + ":" + key))


def isolated_scope(compartment):
    if compartment not in ("primary", "foreign"):
        raise ValueError("unknown_compartment")
    scope = {k: stable(compartment + ":" + k) for k in ("tenant", "graph", "workspace")}
    scope["owner"] = "synthetic:" + compartment + ":casey"
    return scope


def build(fixture=None, compartment="primary"):
    fixture = fixture or json.loads(FIXTURE.read_text())
    if fixture.get("suite") != SUITE or fixture.get("synthetic") is not True:
        raise ValueError("synthetic_suite_required")
    scope = isolated_scope(compartment)
    metadata = {"memory_schema_version": SCHEMA, "fixture_suite": SUITE,
                "synthetic": True, "workspace_id": scope["workspace"],
                "owner_ref": scope["owner"], "compartment": compartment,
                "scenario_clock": fixture["clock"], "timezone": fixture["timezone"]}
    records = fixture["nodes" if compartment == "primary" else "foreign_nodes"]
    if len({r["key"] for r in records}) != len(records):
        raise ValueError("duplicate_entity_key")
    ids = {r["key"]: stable(compartment + ":node:" + r["key"]) for r in records}
    common = {"schema_version": SCHEMA, "fixture_suite": SUITE, "synthetic": True,
              "workspace_id": scope["workspace"], "owner_ref": scope["owner"],
              "source_type": "synthetic_fixture", "source_ref": SUITE,
              "compartment": "owner_private"}
    nodes = []
    for r in records:
        fields = r.get("fields", {})
        if set(fields) & (set(common) | {"kind", "family", "canonical_name", "facts", "entity_key"}):
            raise ValueError("reserved_field_override")
        data = {**common, **fields, "kind": "Entity", "family": r["family"],
                "entity_key": r["key"], "canonical_name": r["name"],
                "facts": [{"id": stable(compartment + ":fact:" + r["key"] + ":" + str(i)),
                           "content": fact, "source_ref": SUITE + ":" + r["key"]}
                          for i, fact in enumerate(r["facts"])]}
        nodes.append({"GUID": ids[r["key"]], "TenantGUID": scope["tenant"],
                      "GraphGUID": scope["graph"], "Name": r["name"],
                      "Labels": ["Entity", r["family"], "SyntheticFixture"], "Data": data})
    edges = []
    links = fixture["edges"] if compartment == "primary" else []
    if len({tuple(link) for link in links}) != len(links):
        raise ValueError("duplicate_relationship")
    for source, predicate, target in links:
        if source not in ids or target not in ids:
            raise ValueError("dangling_relationship")
        edges.append({"GUID": stable(compartment + ":edge:" + source + ":" + predicate + ":" + target),
                      "TenantGUID": scope["tenant"], "GraphGUID": scope["graph"],
                      "From": ids[source], "To": ids[target], "Name": predicate,
                      "Labels": ["Relationship", "SyntheticFixture"],
                      "Data": {**common, "kind": "Relationship", "predicate": predicate}})
    plan = {"scope": scope, "metadata": metadata, "nodes": nodes, "edges": edges}
    plan["digest"] = digest(plan)
    return plan


def digest(plan):
    return hashlib.sha256(json.dumps({k: plan[k] for k in ("scope", "metadata", "nodes", "edges")},
                                    sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def receipt(plan):
    s = plan["scope"]
    return {"GUID": str(uuid.uuid5(uuid.UUID(s["graph"]), SUITE + ":receipt")),
            "TenantGUID": s["tenant"], "GraphGUID": s["graph"],
            "Name": "Synthetic scenario import receipt", "Labels": ["ImportReceipt"],
            "Data": {"kind": "ImportReceipt", "synthetic": True, "fixture_suite": SUITE,
                     "digest": plan["digest"], "status": "committed",
                     "nodes": len(plan["nodes"]), "edges": len(plan["edges"])}}


def apply(plan, request):
    """Requires a separately provisioned graph with matching isolation metadata.

    A committed receipt makes a retry a no-op, including after a lost response.
    Never update/delete existing data. Runtime activation is a separate decision.
    """
    if digest(plan) != plan["digest"]:
        raise ValueError("fixture_digest_mismatch")
    compartment = plan["metadata"].get("compartment")
    expected_scope = isolated_scope(compartment)
    if plan["scope"] != expected_scope or plan["metadata"].get("synthetic") is not True:
        raise ValueError("fixture_scope_not_isolated")
    s = plan["scope"]
    node_ids = {node["GUID"] for node in plan["nodes"]}
    for kind in ("nodes", "edges"):
        for record in plan[kind]:
            data = record.get("Data", {})
            if (record.get("TenantGUID") != s["tenant"] or record.get("GraphGUID") != s["graph"]
                    or data.get("synthetic") is not True or data.get("fixture_suite") != SUITE
                    or data.get("workspace_id") != s["workspace"] or data.get("owner_ref") != s["owner"]):
                raise ValueError("fixture_record_scope_mismatch")
            if kind == "edges" and (record.get("From") not in node_ids or record.get("To") not in node_ids):
                raise ValueError("fixture_edge_outside_scope")
    base = f"/v1.0/tenants/{s['tenant']}/graphs/{s['graph']}"
    if request("GET", base + "?incldata=true").get("Data") != plan["metadata"]:
        raise ValueError("fixture_graph_metadata_mismatch")
    marker = receipt(plan)

    def committed():
        # Enumerating only this small isolated graph avoids assuming 400=missing.
        result = request("GET", base + "/nodes?max-keys=1000&incldata=true")
        if result.get("EndOfResults") is not True:
            raise ValueError("fixture_enumeration_incomplete")
        for node in result["Objects"]:
            if node["GUID"] == marker["GUID"]:
                if node.get("Data") != marker["Data"]:
                    raise ValueError("fixture_receipt_conflict")
                return True
        return False

    if committed():
        return {"status": "already_seeded"}
    for kind in ("nodes", "edges"):
        result = request("GET", base + "/" + kind + "?max-keys=1")
        if result.get("TotalRecords") != 0 or result.get("Objects") != []:
            raise ValueError("fixture_requires_empty_graph")
    operations = [{"OperationType": "Create", "ObjectType": kind, "Payload": item}
                  for kind, items in (("Node", plan["nodes"] + [marker]), ("Edge", plan["edges"]))
                  for item in items]
    if len(operations) > 120:
        raise ValueError("fixture_too_large")
    try:
        result = request("POST", base + "/transaction", {"Operations": operations,
                         "MaxOperations": 120, "TimeoutSeconds": 30, "IsolationLevel": "Serializable"})
        if result.get("Success") is not True or result.get("State") != "Committed" or result.get("RolledBack"):
            raise RuntimeError("fixture_transaction_failed")
    except Exception:
        if not committed():
            raise
    if not committed():
        raise RuntimeError("fixture_receipt_missing")
    return {"status": "seeded"}


def verify(plan, request):
    s = plan["scope"]
    base = f"/v1.0/tenants/{s['tenant']}/graphs/{s['graph']}"
    counts = {}
    for kind in ("nodes", "edges"):
        result = request("GET", base + "/" + kind + "?max-keys=1000&incldata=true&inclsub=true")
        expected = plan[kind] + ([receipt(plan)] if kind == "nodes" else [])
        found = {r["GUID"]: r for r in result["Objects"]}
        if result.get("EndOfResults") is not True or set(found) != {r["GUID"] for r in expected}:
            raise RuntimeError("fixture_record_set_mismatch")
        for record in expected:
            for key in ("GUID", "TenantGUID", "GraphGUID", "Name", "Data", "From", "To"):
                if key in record and found[record["GUID"]].get(key) != record[key]:
                    raise RuntimeError("fixture_readback_mismatch:" + key)
        counts[kind] = len(found)
    return {"readback": "all_records_match", **counts}


if __name__ == "__main__":
    print(json.dumps({k: build(compartment=k) for k in ("primary", "foreign")}, indent=2))
