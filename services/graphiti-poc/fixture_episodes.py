"""Offline native add_memory inputs. Never reads evaluator notes or live memory."""
import hashlib
import json
from pathlib import Path

from extraction import extraction_instructions

SUITE = "ea-memory-cookoff.v1"
GROUP = "ea_memory_cookoff_v1"
FAMILY_TYPES = {
    "person": "Person", "project": "Project", "meeting": "Event", "event": "Event",
    "booking": "TransactionReference", "trip": "Trip", "task": "TaskReference",
    "decision": "DecisionReference", "record": "Content", "interaction": "InteractionReference",
}
FIXTURE = Path(__file__).resolve().parents[1] / "voice-bridge/fixtures/memory-scenarios-v1.json"


def build(fixture, *, group_id=GROUP):
    if fixture.get("synthetic") is not True or fixture.get("suite") != SUITE:
        raise ValueError("Only the synthetic cook-off fixture is accepted")
    nodes = fixture["nodes"]
    names = {node["key"]: node["name"] for node in nodes}
    types = {node["key"]: FAMILY_TYPES[node["family"]] for node in nodes}
    if len(names) != len(nodes):
        raise ValueError("Duplicate entity key")
    links = {key: [] for key in names}
    for source, predicate, target in fixture["edges"]:
        if source not in names or target not in names:
            raise ValueError("Relationship points outside primary fixture")
        links[source].append({"source": names[source], "relationship": predicate,
                              "target": names[target], "source_type": types[source],
                              "target_type": types[target]})
    episodes = []
    guidance = extraction_instructions()
    for node in nodes:
        # Explicit allowlist: no foreign_nodes, expected answers, scoring notes,
        # live graph identifiers, or post-test Morgan edits enter this baseline.
        content = json.dumps({"name": node["name"], "family": node["family"],
                              "entity_type": types[node["key"]],
                              "facts": node["facts"], "fields": node.get("fields", {}),
                              "relationships": links[node["key"]]},
                             sort_keys=True, ensure_ascii=False)
        digest = hashlib.sha256(content.encode()).hexdigest()
        episodes.append({
            # In this upstream version uuid refers to an EXISTING episode.
            # New writes omit it; a content-addressed name aids reconciliation.
            "name": f"{SUITE}:{node['key']}:{digest[:16]}",
            "episode_body": content,
            "source": "json",
            "source_description": f"Synthetic baseline snapshot; timezone {fixture['timezone']}",
            "reference_time": fixture["clock"],
            "group_id": group_id,
            "custom_extraction_instructions": guidance,
        })
    return {"suite": SUITE, "synthetic": True, "group_id": group_id,
            "guidance_sha256": hashlib.sha256(guidance.encode()).hexdigest(),
            "fixture_sha256": hashlib.sha256(json.dumps(fixture, sort_keys=True).encode()).hexdigest(),
            "episodes": episodes}


if __name__ == "__main__":
    print(json.dumps(build(json.loads(FIXTURE.read_text())), indent=2, ensure_ascii=False))
