"""Atomic first-baseline import. request(method, path, body=None) returns JSON.

Only create operations; never overwrite conversational additions. A committed
receipt makes reruns no-ops. Provisioning and runtime activation are separate.
"""
import hashlib
import json
import uuid

from .memory_baseline import SCHEMA, MAPPING_VERSION


def apply_plan(plan, request):
    scope = plan["scope"]
    tenant, graph = scope["tenant"], scope["graph"]
    base = f"/v1.0/tenants/{tenant}/graphs/{graph}"
    canonical = json.dumps({"nodes": plan["nodes"], "edges": plan["edges"]}, sort_keys=True, ensure_ascii=False)
    if hashlib.sha256(canonical.encode()).hexdigest() != plan["digest"]:
        raise ValueError("import_digest_mismatch")
    metadata = request("GET", base + "?incldata=true")["Data"]
    if any(metadata.get(k) != v for k, v in {
        "memory_schema_version": SCHEMA, "workspace_id": scope["workspace"],
        "owner_ref": scope["owner"], "import_version": MAPPING_VERSION,
    }.items()):
        raise ValueError("import_scope_mismatch")
    receipt_id = str(uuid.uuid5(uuid.UUID(graph), MAPPING_VERSION + ":receipt"))
    receipt_data = {"kind": "ImportReceipt", "schema_version": SCHEMA,
                    "workspace_id": scope["workspace"], "owner_ref": scope["owner"],
                    "digest": plan["digest"], "source_revision": plan["source_revision"],
                    "counts": plan["counts"], "import_version": MAPPING_VERSION,
                    "status": "committed", "runtime_activation": "separate_step"}

    def read_receipt():
        try:
            found = request("GET", base + "/nodes/" + receipt_id + "?incldata=true")
        except Exception as error:
            if getattr(error, "code", None) == 404:
                error.close()
                return False
            # LiteGraph v9 reports some missing objects as 400. Do not treat an
            # arbitrary bad request or auth failure as an empty graph.
            if getattr(error, "code", None) == 400:
                payload = json.load(error)
                error.close()
                if payload.get("Description") == "No node with GUID '" + receipt_id + "' exists.":
                    return False
            raise
        if found.get("Data") != receipt_data:
            raise ValueError("import_receipt_conflict")
        return True

    if read_receipt():
        return {"status": "already_imported", "receipt_id": receipt_id, "counts": plan["counts"]}
    for kind in ("nodes", "edges"):
        existing = request("GET", base + "/" + kind + "?max-keys=1")
        if existing.get("TotalRecords") != 0 or existing.get("Objects") != []:
            raise ValueError("initial_import_requires_empty_graph")
    receipt = {"GUID": receipt_id, "TenantGUID": tenant, "GraphGUID": graph,
               "Name": "GitHub baseline import receipt", "Labels": ["ImportReceipt"], "Data": receipt_data}
    operations = [{"OperationType": "Create", "ObjectType": kind, "Payload": record}
                  for kind, records in (("Node", plan["nodes"] + [receipt]), ("Edge", plan["edges"]))
                  for record in records]
    if len(operations) > 120:
        raise ValueError("baseline_exceeds_reviewed_transaction_limit")
    try:
        result = request("POST", base + "/transaction", {
            "Operations": operations, "MaxOperations": 120,
            "TimeoutSeconds": 30, "IsolationLevel": "Serializable"})
        if not (result.get("Success") is True and result.get("State") == "Committed" and not result.get("RolledBack")):
            raise RuntimeError("import_transaction_not_committed")
    except Exception:
        if not read_receipt():
            raise
    if not read_receipt():
        raise RuntimeError("import_receipt_missing_after_commit")
    return {"status": "imported", "receipt_id": receipt_id, "counts": plan["counts"]}


def verify_plan(plan, request):
    """Compare every imported node/edge body, not merely counts or verbal claims."""
    s = plan["scope"]
    base = f"/v1.0/tenants/{s['tenant']}/graphs/{s['graph']}"
    counts = {}
    for kind in ("nodes", "edges"):
        result = request("GET", base + "/" + kind + "?max-keys=1000&incldata=true&inclsub=true")
        if result.get("EndOfResults") is not True:
            raise RuntimeError("verification_enumeration_incomplete")
        found = {r["GUID"]: r for r in result["Objects"]}
        for expected in plan[kind]:
            actual = found.get(expected["GUID"], {})
            # Labels may be represented as subobjects by the REST server; data,
            # identities and relationship endpoints must match exactly.
            for key in ("GUID", "TenantGUID", "GraphGUID", "Name", "Data", "From", "To"):
                if key in expected and actual.get(key) != expected[key]:
                    raise RuntimeError("import_readback_mismatch:" + kind + ":" + key)
        counts[kind] = len(found)
    if counts != {"nodes": len(plan["nodes"]) + 1, "edges": len(plan["edges"])}:
        raise RuntimeError("unexpected_graph_records")
    return {"readback": "all_records_match", **counts}
