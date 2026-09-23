"""Opt-in, single-owner graph writer. No raw graph mutations are exposed to MCP.

Assertions and save receipts are immutable. A transaction creates the entire
bundle or nothing. Explicit existing IDs resolve identity; names never do.
The registry describes vocabulary, not authorization.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
import unicodedata
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .errors import GraphInputError

REGISTRY = json.loads(Path(__file__).with_name("entity_registry.v1.json").read_text())
SCHEMA = "entity-memory.v1"
KEY = re.compile(r"^[a-z][a-z0-9_]{0,63}$")


def canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def canonical_predicate(value: str) -> str:
    return next((name for name, definition in REGISTRY['predicates'].items()
                 if value in definition['aliases']), value)


def guid(value: Any) -> str:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        raise ValueError("invalid_graph_record_id") from None


def text(value: Any, name: str, maximum: int = 200) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise ValueError(f"invalid_{name}")
    return value.strip()


def fields(value: Any, allowed: set[str], required: set[str]) -> None:
    if not isinstance(value, dict) or set(value) - allowed or required - set(value):
        raise ValueError("invalid_graph_fields")


def instant(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError()
        return parsed.astimezone(timezone.utc)
    except (ValueError, AttributeError, TypeError):
        raise ValueError("invalid_timezone_aware_timestamp") from None


def data(node: dict) -> dict:
    return node.get("Data") or {}


def terms(value: str) -> set[str]:
    normalized = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode().casefold()
    return set(re.findall(r"[a-z0-9]+", normalized))


def sound(word: str) -> str:
    word = re.sub(r"(.)\1+", r"\1", word.replace("ph", "f").replace("ck", "k"))
    return word[:1] + re.sub(r"[aeiouyh]", "", word[1:])


def graph_store_schema() -> dict:
    string = {"type": "string", "minLength": 1, "maxLength": 200}
    return {
        "type": "object", "additionalProperties": False,
        "required": ["source_ref", "source_session_ref", "source_thread_ref", "idempotency_key", "entities", "facts"],
        "properties": {
            "source_ref": {**string, "description": "Stable source utterance/message reference. Reuse on retries."},
            "source_session_ref": string, "source_thread_ref": string,
            "idempotency_key": {**string, "description": "Stable key for this exact bundle; reuse unchanged on retry."},
            "entities": {"type": "array", "minItems": 1, "maxItems": 12, "items": {
                "type": "object", "additionalProperties": False, "required": ["key", "family", "name"],
                "properties": {
                    "key": {"type": "string", "pattern": KEY.pattern},
                    "family": {"type": "string", "enum": [k for k, v in REGISTRY["families"].items() if v["authority"] == "memory"]},
                    "name": {"type": "string", "minLength": 1, "maxLength": 160},
                    "observed_name": {"type": "string", "minLength": 1, "maxLength": 160, "description": "Optional spoken alias after resolving identity using context; never establish identity by phonetics alone."},
                    "existing_id": {"type": "string", "format": "uuid", "description": "Resolved entity ID from memory_search/get. Omit only after establishing this is a new entity; never merge by name alone."}
                }}},
            "facts": {"type": "array", "minItems": 1, "maxItems": 20, "items": {
                "type": "object", "additionalProperties": False,
                "oneOf": [{"required": ["value"], "not": {"required": ["object"]}},
                          {"required": ["object"], "not": {"required": ["value"]}}],
                "required": ["key", "subject", "predicate", "content", "evidence", "confidence"],
                "properties": {
                    "key": {"type": "string", "pattern": KEY.pattern},
                    "subject": {"type": "string", "pattern": KEY.pattern, "description": "Must equal an entities[].key in THIS bundle, e.g. person_a, never a UUID or person's name. Put a resolved UUID in that entity's existing_id instead."},
                    "predicate": {"type": "string", "pattern": KEY.pattern,
                        "description": "Use lowercase snake_case. Known link predicates: " + "; ".join(
                            k + " -> " + ("string value" if v.get("literal") else ", ".join(v["object_families"]))
                            for k, v in REGISTRY["predicates"].items()) + ". Other sourced predicates are retained pending classification."},
                    "object": {"type": "string", "pattern": KEY.pattern, "description": "Must equal an entities[].key in THIS bundle. For a relationship only. Supply object OR value. A relationship plus its anniversary date requires two separate facts, not both fields on one fact."},
                    "value": {"type": "string", "minLength": 1, "maxLength": 1000,
                        "description": "Literal fact, including anniversary/birthday/trip dates as stated. Supply value OR object; omit the other field, never null. Do not invent missing year/timezone."},
                    "content": {"type": "string", "minLength": 1, "maxLength": 2000},
                    "evidence": {"type": "string", "minLength": 1, "maxLength": 2000, "description": "Supporting source excerpt, not speculation. This field is agent-reported, not independent proof."},
                    "confidence": {"type": "number", "minimum": 0, "maximum": 1},
                    "valid_from": {"type": "string", "format": "date-time", "description": "Optional assertion-validity start with timezone. NOT the date of a birthday, anniversary, or trip; use a literal fact for that. Omit when unknown."},
                    "valid_until": {"type": "string", "format": "date-time", "description": "Optional assertion-validity end with timezone, after valid_from. Omit when unknown; never null."},
                    "supersedes_memory_id": {"type": "string", "format": "uuid"}
                }}}
        }
    }


class GraphMemory:
    def __init__(self, settings, request):
        self.settings = settings
        self.request = request
        self.base = f"/v1.0/tenants/{guid(settings.tenant_guid)}/graphs/{guid(settings.graph_guid)}"
        # Trusted deployment scope, never accepted as tool arguments. This is
        # intentionally NOT a multi-user authorization implementation.
        self.scope = {"workspace_id": text(settings.workspace_id, "workspace_id"),
                      "owner_ref": text(settings.owner_ref, "owner_ref"),
                      "compartment": "owner_private", "sensitivity_level": 3}

    def stable_id(self, kind: str, *parts: str) -> str:
        return str(uuid.uuid5(uuid.UUID(self.settings.graph_guid), canonical([SCHEMA, self.scope, kind, *parts])))

    async def check_scope(self) -> None:
        graph = await self.request(self.settings, "GET", self.base, params={"incldata": "true"})
        metadata = data(graph)
        if (metadata.get("memory_schema_version") != SCHEMA
            or metadata.get("workspace_id") != self.settings.workspace_id
            or metadata.get("owner_ref") != self.settings.owner_ref):
            raise ValueError("graph_scope_not_provisioned_for_entity_memory")

    async def read(self, record_id: str) -> dict | None:
        try:
            node = await self.request(self.settings, "GET", self.base + "/nodes/" + guid(record_id), params={"incldata": "true", "inclsub": "true"})
        except Exception as error:
            if getattr(error, "status", None) == 404:
                return None
            raise
        if not isinstance(node, dict) or not self.authorized(node):
            raise ValueError("graph_record_outside_authorized_scope")
        return node

    def authorized(self, node: dict) -> bool:
        d = data(node)
        return (d.get("schema_version") == SCHEMA and all(d.get(k) == v for k, v in self.scope.items())
                and node.get("TenantGUID", self.settings.tenant_guid) == self.settings.tenant_guid
                and node.get("GraphGUID", self.settings.graph_guid) == self.settings.graph_guid)

    def node(self, record_id: str, kind: str, name: str, attributes: dict) -> dict:
        return {"GUID": record_id, "TenantGUID": self.settings.tenant_guid, "GraphGUID": self.settings.graph_guid,
                "Name": name, "Labels": [kind],
                "Data": {"schema_version": SCHEMA, **self.scope, "kind": kind, **attributes}}

    def edge(self, subject: str, target: str, predicate: str, fact_id: str) -> dict:
        return {"GUID": self.stable_id("edge", subject, target, predicate, fact_id),
                "From": subject, "To": target, "Name": predicate, "Labels": [predicate],
                "Data": {"schema_version": SCHEMA, **self.scope, "fact_id": fact_id}}

    async def receipt(self, receipt_id: str, digest: str) -> dict | None:
        existing = await self.read(receipt_id)
        if existing is None:
            return None
        d = data(existing)
        if d.get("kind") != "SaveReceipt" or d.get("request_digest") != digest:
            raise ValueError("idempotency_key_reused_with_different_content")
        return {**d["result"], "stored": False, "duplicate": True}

    async def store(self, args: dict) -> dict:
        required = {"source_ref", "source_session_ref", "source_thread_ref", "idempotency_key", "entities", "facts"}
        fields(args, required, required)
        await self.check_scope()
        source = {k: text(args[k], k) for k in required - {"entities", "facts"}}
        try:
            digest = hashlib.sha256(canonical(args).encode()).hexdigest()
        except (ValueError, TypeError):
            raise ValueError("invalid_graph_payload") from None
        receipt_id = self.stable_id("receipt", source["source_ref"], source["idempotency_key"])
        saved = await self.receipt(receipt_id, digest)
        if saved:
            return saved
        if not isinstance(args["entities"], list) or not 1 <= len(args["entities"]) <= 12:
            raise ValueError("invalid_entity_count")
        if not isinstance(args["facts"], list) or not 1 <= len(args["facts"]) <= 20:
            raise ValueError("invalid_fact_count")
        entities, nodes, edges, facts = {}, [], [], []
        now = datetime.now(timezone.utc).isoformat()
        for entity in args["entities"]:
            fields(entity, {"key", "family", "name", "existing_id", "observed_name"}, {"key", "family", "name"})
            key = text(entity["key"], "entity_key", 64)
            if not KEY.fullmatch(key) or key in entities:
                raise ValueError("invalid_or_duplicate_entity_key")
            family = text(entity["family"], "family", 64)
            definition = REGISTRY["families"].get(family)
            # Operational projections need a trusted Turn Engine adapter,
            # never a model-supplied 'task completed' record.
            if not definition or definition["authority"] != "memory":
                raise ValueError("family_requires_authoritative_writer")
            name = text(entity["name"], "entity_name", 160)
            observed = text(entity.get("observed_name", name), "observed_name", 160)
            if "existing_id" in entity:
                record_id = guid(entity["existing_id"])
                existing = await self.read(record_id)
                d = data(existing or {})
                if d.get("kind") != "Entity" or d.get("family") != family:
                    raise ValueError("existing_entity_not_found_or_wrong_family")
                if name.casefold() != d["canonical_name"].casefold():
                    raise ValueError("existing_entity_name_conflict")
            else:
                # Source-scoped identity: same-name people remain distinct.
                # Return IDs for subsequent saves to reuse explicitly.
                record_id = self.stable_id("entity", receipt_id, key)
                node = self.node(record_id, "Entity", name, {"family": family, "canonical_name": name,
                    "registry_version": REGISTRY["version"], "status": "active", "created_at": now,
                    "source_ref": source["source_ref"]})
                node["Labels"].append(definition["label"])
                nodes.append(node)
            entities[key] = {"id": record_id, "family": family, "name": name, "observed_name": observed}

        keys, referenced, superseded = set(), set(), set()
        for fact_index, fact in enumerate(args["facts"]):
            fields(fact, {"key", "subject", "predicate", "object", "value", "content", "evidence", "confidence", "valid_from", "valid_until", "supersedes_memory_id"},
                   {"key", "subject", "predicate", "content", "evidence", "confidence"})
            key = text(fact["key"], "fact_key", 64)
            if not KEY.fullmatch(key) or key in keys:
                raise ValueError("invalid_or_duplicate_fact_key")
            keys.add(key)
            subject_key = text(fact["subject"], "subject_key", 64)
            if subject_key not in entities:
                raise GraphInputError("unknown_fact_subject", fact_index, "subject")
            if "object" in fact and "value" in fact:
                raise GraphInputError("fact_target_conflict", fact_index, "target")
            if "object" not in fact and "value" not in fact:
                raise GraphInputError("fact_target_missing", fact_index, "target")
            subject = entities[subject_key]["id"]
            referenced.add(subject_key)
            predicate = text(fact["predicate"], "predicate", 64)
            if not KEY.fullmatch(predicate):
                raise ValueError("invalid_predicate")
            predicate = canonical_predicate(predicate)
            definition = REGISTRY["predicates"].get(predicate)
            value, object_id = None, None
            if "object" in fact:
                object_key = text(fact["object"], "object_key", 64)
                if object_key not in entities:
                    raise GraphInputError("unknown_fact_object", fact_index, "object")
                obj = entities[object_key]
                if definition and (definition.get("literal") or obj["family"] not in definition["object_families"]):
                    raise ValueError("predicate_object_family_mismatch")
                object_id = obj["id"]
                referenced.add(object_key)
            else:
                value = text(fact["value"], "value", 1000)
                if definition and not definition.get("literal"):
                    raise ValueError("predicate_requires_entity_object")
            confidence = fact["confidence"]
            if isinstance(confidence, bool) or not isinstance(confidence, (int, float)) or not math.isfinite(confidence) or not 0 <= confidence <= 1:
                raise ValueError("invalid_confidence")
            valid_from = fact.get("valid_from", now)
            valid_until = fact.get("valid_until")
            start = instant(valid_from)
            if "valid_until" in fact and instant(valid_until) <= start:
                raise ValueError("invalid_validity_window")
            fact_id = self.stable_id("fact", receipt_id, key)
            previous = None
            if "supersedes_memory_id" in fact:
                previous = guid(fact["supersedes_memory_id"])
                prior = await self.read(previous)
                pd = data(prior or {})
                if (pd.get("kind") != "Fact" or pd.get("subject_ref") != subject
                    or canonical_predicate(pd.get("predicate")) != predicate or previous in superseded):
                    raise ValueError("invalid_supersession_target")
                if start < instant(pd["valid_from"]):
                    raise ValueError("supersession_precedes_original")
                superseded.add(previous)
                edges.append(self.edge(fact_id, previous, "supersedes", fact_id))
            attributes = {"memory_ref": fact_id, "memory_type": "assertion", "subject_ref": subject,
                "subject_name": entities[subject_key]["name"], "observed_subject_name": entities[subject_key]["observed_name"],
                "predicate": predicate, "object_ref": object_id, "value": value,
                "content": text(fact["content"], "content", 2000), "evidence": text(fact["evidence"], "evidence", 2000),
                "confidence": confidence, "source_actor_ref": self.settings.owner_ref,
                "source_attribution": "agent_reported", "status": "active", "captured_at": now,
                "valid_from": valid_from, "valid_until": valid_until, "supersedes_memory_id": previous,
                "classification_status": "approved" if definition else "pending", "registry_version": REGISTRY["version"],
                **{k: source[k] for k in ("source_ref", "source_session_ref", "source_thread_ref")}}
            nodes.append(self.node(fact_id, "Fact", f"fact:{predicate}:{fact_id}", attributes))
            facts.append(fact_id)
            edges.append(self.edge(subject, fact_id, "has_fact", fact_id))
            if object_id:
                edges.append(self.edge(fact_id, object_id, "object", fact_id))
                edges.append(self.edge(subject, object_id, predicate, fact_id))
            else:
                edges.append(self.edge(subject, fact_id, predicate, fact_id))
        if referenced != set(entities):
            raise ValueError("unreferenced_entity")
        result = {"status": "saved", "stored": True, "duplicate": False, "receipt_id": receipt_id,
                  "entities": entities, "memory_ids": facts, "edge_ids": [e["GUID"] for e in edges],
                  "classification_pending": [n["GUID"] for n in nodes if data(n).get("classification_status") == "pending"]}
        nodes.append(self.node(receipt_id, "SaveReceipt", f"receipt:{receipt_id}", {"request_digest": digest, "result": result, "captured_at": now}))
        operations = [{"OperationType": "Create", "ObjectType": kind, "Payload": item}
                      for kind, items in (("Node", nodes), ("Edge", edges)) for item in items]
        try:
            response = await self.request(self.settings, "POST", self.base + "/transaction", json_body={
                "Operations": operations, "MaxOperations": 120, "TimeoutSeconds": 10, "IsolationLevel": "Serializable"})
            if not isinstance(response, dict) or response.get("Success") is not True or response.get("State") != "Committed" or response.get("RolledBack"):
                raise RuntimeError("graph_transaction_not_committed")
        except Exception:
            # A timeout or concurrent retry can occur after commit. Only a
            # matching persisted receipt proves success; never fall back to
            # piecemeal node writes or blindly overwrite records.
            saved = await self.receipt(receipt_id, digest)
            if saved:
                return saved
            raise
        return result

    async def list_records(self, kind: str) -> list[dict]:
        result = []
        for page in range(10):
            response = await self.request(self.settings, "GET", self.base + "/" + kind,
                params={"max-keys": "1000", "skip": str(page * 1000), "order": "GuidAscending", "incldata": "true", "inclsub": "true"})
            if not isinstance(response, dict) or not isinstance(response.get("Objects"), list):
                raise RuntimeError("unsupported_graph_enumeration_response")
            if kind == "nodes" and any(data(n).get("schema_version") == "memory-v1" for n in response["Objects"] if isinstance(n, dict)):
                raise RuntimeError("legacy_memories_require_explicit_migration")
            result.extend(n for n in response["Objects"] if isinstance(n, dict) and self.authorized(n))
            if response.get("EndOfResults") is True:
                return result
            if not response["Objects"]:
                break
        # A truncated scan must not masquerade as 'no memory' or a complete
        # character sheet. Replace with indexed queries before larger scale.
        raise RuntimeError("graph_read_capacity_exceeded")

    @staticmethod
    def current_facts(nodes: list[dict], now: datetime) -> list[dict]:
        facts = [n for n in nodes if data(n).get("kind") == "Fact"]
        # A correction remains a historical invalidation even after its own
        # validity window expires. Future corrections do not take effect yet.
        superseded = {data(n).get("supersedes_memory_id") for n in facts if instant(data(n)["valid_from"]) <= now}
        return [n for n in facts if n["GUID"] not in superseded and data(n).get("status") == "active"
                and instant(data(n)["valid_from"]) <= now
                and (not data(n).get("valid_until") or now < instant(data(n)["valid_until"]))]

    async def context(self, entity_id: str) -> dict:
        await self.check_scope()
        entity_id = guid(entity_id)
        entity = await self.read(entity_id)
        if not entity or data(entity).get("kind") != "Entity":
            raise ValueError("entity_not_found")
        nodes = await self.list_records("nodes")
        edges = await self.list_records("edges")
        now = datetime.now(timezone.utc)
        facts = self.current_facts(nodes, now)
        # Read actual graph links, then enforce the assertion's time/scope.
        linked = {e["To"] for e in edges if e.get("From") == entity_id and e.get("Name") == "has_fact"}
        outgoing = [n for n in facts if data(n).get("subject_ref") == entity_id]
        if any(n["GUID"] not in linked for n in outgoing):
            raise RuntimeError("graph_integrity_missing_fact_link")
        incoming = [n for n in facts if data(n).get("object_ref") == entity_id and data(n).get("subject_ref") != entity_id]
        incoming_links = {e["From"] for e in edges if e.get("To") == entity_id and e.get("Name") == "object"}
        if any(n["GUID"] not in incoming_links for n in incoming):
            raise RuntimeError("graph_integrity_missing_object_link")
        facts = outgoing + incoming
        current_ids = {n["GUID"] for n in facts}
        related_ids = {ref for n in facts for ref in (data(n).get("object_ref"), data(n).get("subject_ref")) if ref and ref != entity_id}
        related = [n for n in nodes if n["GUID"] in related_ids and data(n).get("kind") == "Entity"]
        if {n["GUID"] for n in related} != related_ids:
            raise RuntimeError("graph_integrity_missing_related_entity")
        corrections = {}
        for fact in facts:
            previous = data(fact).get("supersedes_memory_id")
            if previous:
                corrections.setdefault(previous, []).append(fact["GUID"])
        return {"entity": entity, "facts": facts,
                "relationships": [e for e in edges if data(e).get("fact_id") in current_ids],
                "related_entities": related,
                "conflicting_corrections": [ids for ids in corrections.values() if len(ids) > 1],
                "as_of": now.isoformat(), "classification_pending": any(data(n).get("classification_status") == "pending" for n in facts),
                "read_consistency": "bounded_non_snapshot", "authority": "memory_context_not_operational_state"}

    async def search(self, args: dict) -> dict:
        await self.check_scope()
        fields(args, {"query", "max_results"}, {"query"})
        query = text(args["query"], "query", 500)
        limit = args.get("max_results", 5)
        if type(limit) is not int or not 1 <= limit <= 10:
            raise ValueError("invalid_max_results")
        nodes = await self.list_records("nodes")
        candidates = [n for n in nodes if data(n).get("kind") == "Entity"]
        candidates += self.current_facts(nodes, datetime.now(timezone.utc))
        query_terms = terms(query)
        matched_entities = {n["GUID"] for n in candidates if data(n).get("kind") == "Entity" and query_terms & terms(data(n)["canonical_name"])}
        matched_entities.update(data(n)["subject_ref"] for n in candidates if data(n).get("kind") == "Fact" and query_terms & terms(data(n).get("observed_subject_name", "")))
        sounds = {sound(word) for word in query_terms if len(word) >= 3}
        ranked = []
        for node in candidates:
            d = data(node)
            haystack = " ".join(str(d.get(k) or "") for k in ("canonical_name", "content", "predicate", "value", "subject_name", "observed_subject_name"))
            score = len(query_terms & terms(haystack))
            # A character sheet with many facts must not crowd its own Entity
            # out of a name lookup. Still a candidate, never identity proof.
            if d.get('kind')=='Entity' and query.strip().casefold()==d['canonical_name'].casefold():
                score += 100
            if node["GUID"] in matched_entities or d.get("subject_ref") in matched_entities:
                score += 10
            names = terms(d.get("canonical_name", "") + " " + d.get("subject_name", ""))
            phonetic = not score and any(len(word) >= 3 and sound(word) in sounds for word in names)
            if phonetic:
                score = 1
            if score:
                ranked.append((score, {**node, "match_kind": "phonetic_candidate" if phonetic else "keyword_or_resolved_alias"}))
        ranked.sort(key=lambda pair: (-pair[0], pair[1]["GUID"]))
        return {"query": query, "matches": [{"memory_id": n["GUID"], "kind": data(n)["kind"], "content": data(n), "match_kind": n["match_kind"]} for _, n in ranked[:limit]],
                "has_more_matches": len(ranked) > limit,
                "has_more_entity_matches": any(data(n).get('kind')=='Entity' for _,n in ranked[limit:]),
                "retrieval": "bounded_keyword_candidates", "requires_identity_resolution": True}
