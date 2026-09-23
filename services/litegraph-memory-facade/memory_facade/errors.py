"""Model-readable, non-sensitive tool failures (not JSON-RPC failures)."""

# Only these application-owned codes may leave the process. Never echo an
# arbitrary exception: a driver/parser error can contain credentials or facts.
GUIDANCE = {
    "capture_contains_credentials": "Remove credentials before capturing. Never store passwords, tokens or private keys.",
    "invalid_capture_context": "Context must be a string up to 4000 characters containing only explicit conversational context.",
    "unknown_fact_subject": "subject must equal an entities[].key in this same bundle, not a person's name or an existing UUID. Include the resolved Entity with its existing_id, give it a local key, and reference that key. Never guess the subject.",
    "fact_target_missing": "Supply exactly one target: value for a literal fact (such as an anniversary date), or object for an entity relationship. Do not invent missing information.",
    "fact_target_conflict": "Both object and value were supplied. A fact must contain exactly one. For an anniversary date use value and omit object entirely. If you also need a relationship, use a separate sourced fact with object. Null still counts as a supplied field.",
    "invalid_graph_fields": "Use exactly the advertised fields and include every required field. Omit unused optional fields; do not send null placeholders.",
    "invalid_graph_payload": "Supply a JSON object using the advertised schema and finite numbers.",
    "invalid_graph_record_id": "Use an existing UUID returned by memory_search/get or a successful save; never invent IDs.",
    "invalid_or_duplicate_entity_key": "Give each entity a unique lowercase snake_case key (maximum 64 characters).",
    "invalid_or_duplicate_fact_key": "Give each fact a unique lowercase snake_case key (maximum 64 characters).",
    "invalid_fact_endpoints": "Each fact must reference a subject key in entities and contain exactly one of object or value. Omit the unused field entirely.",
    "unknown_fact_object": "object must reference a local key in this bundle's entities, not a name, UUID, or literal.",
    "invalid_predicate": "Use a lowercase snake_case predicate (maximum 64 characters).",
    "predicate_requires_entity_object": "This predicate requires an entity link. Include the target entity and refer to its local key in object; omit value.",
    "predicate_object_family_mismatch": "Use the documented predicate's object family, or value for a literal predicate. Do not change the stated fact or bypass authority rules.",
    "invalid_timezone_aware_timestamp": "valid_from/valid_until are assertion-validity timestamps and require a timezone. Store a birthday, anniversary, or trip date in a fact's string value instead. Omit validity fields unless an actual validity interval is known; never invent a year or timezone.",
    "invalid_validity_window": "valid_until must be later than valid_from. Event dates belong in string values, not assertion-validity fields.",
    "existing_entity_not_found_or_wrong_family": "Search and read the Entity record, then reuse its returned ID, family, and canonical name. A Fact ID is not an Entity ID.",
    "existing_entity_name_conflict": "Reuse the resolved Entity's canonical name; put a confirmed spoken alias in observed_name. Do not merge different people.",
    "unreferenced_entity": "Every included entity must be the subject or object of a fact. Remove unused entities or add only relationships supported by the caller.",
    "invalid_supersession_target": "Read the prior Fact. A correction must have the same subject and predicate and supersede that Fact ID only once.",
    "supersession_precedes_original": "A correction cannot precede the original assertion's validity. Read the prior fact and use supported timing only.",
    "invalid_entity_count": "Send between 1 and 12 entities in a bundle.",
    "invalid_fact_count": "Send between 1 and 20 facts in a bundle.",
    "invalid_confidence": "confidence must be a finite number between 0 and 1, not a boolean.",
    "invalid_max_results": "max_results must be an integer between 1 and 10.",
    "entity_not_found": "Search again for an authorized Entity or Fact ID; do not invent one.",
    "idempotency_key_reused_with_different_content": "This key already identifies a different committed bundle. Check the earlier receipt and recall first. Use a new key only for genuinely new or corrected content, never to retry an uncertain save.",
    "family_requires_authoritative_writer": "Use an advertised memory family for descriptive facts only. Tasks, decisions, transactions, and interactions require the authorized Turn Engine writer; do not relabel them to bypass this restriction.",
    "graph_scope_not_provisioned_for_entity_memory": "The configured memory scope requires operator repair. Do not retry or change identity, workspace, or graph.",
    "graph_record_outside_authorized_scope": "This record is outside the authorized memory scope. Do not retry it or change identity/workspace. Use only authorized search results.",
}
for field in ("source_ref", "source_session_ref", "source_thread_ref", "idempotency_key",
              "entity_key", "family", "entity_name", "observed_name", "fact_key",
              "subject_key", "predicate", "object_key", "value", "content", "evidence"):
    GUIDANCE.setdefault("invalid_" + field, "Supply a nonempty string for " + field + " within the advertised length limit; use only caller-supported facts and trusted source references.")

BLOCKED = {"capture_contains_credentials", "family_requires_authoritative_writer", "graph_scope_not_provisioned_for_entity_memory",
           "graph_record_outside_authorized_scope"}


class GraphInputError(ValueError):
    """Safe field location only; never retain rejected input values."""
    def __init__(self, code: str, fact_index: int, field: str):
        super().__init__(code)
        if code not in GUIDANCE or field not in {"subject", "object", "target"} or not 0 <= fact_index < 20:
            raise ValueError("invalid_graph_fields")
        self.field_path = f"facts[{fact_index}].{field}"


def validation_failure(error: ValueError) -> dict:
    code = str(error)
    if code not in GUIDANCE:
        code = "invalid_arguments"
    result = {"status": "rejected", "error_code": code,
            "category": "scope_or_authority" if code in BLOCKED else "validation",
            "retry_action": "stop" if code in BLOCKED else "correct_arguments",
            "message": GUIDANCE.get(code, "Check the advertised tool schema and correct the arguments; do not invent missing facts."),
            "save_confirmed": False}
    if isinstance(error, GraphInputError):
        result["field_path"] = error.field_path
    return result


def backend_failure() -> dict:
    return {"status": "unavailable", "error_code": "memory_backend_unavailable",
            "category": "backend", "retry_action": "retry_identical_once",
            "save_confirmed": False,
            "message": "The backend result could not be confirmed. For a save, retry once with the identical bundle, source_ref, and idempotency_key so a committed receipt can be recovered. Do not change the key, claim success, or promise a background save. If still unsuccessful, tell the caller which details remain unconfirmed."}
